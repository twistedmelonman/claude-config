#!/usr/bin/env bash
# ~/.claude/hooks/merge-lock.sh
# Merge authorization lock - requires human to authorize before agent can merge
#
# Locks are keyed on repo AND PR number:
#   ~/.claude/merge-locks/<owner>/<repo>/pr-<N>.lock
# so an authorization for one repo's PR 3 can never satisfy another repo's
# PR 3. The repo comes from `--repo owner/name` when given, otherwise from
# `gh repo view` on the current directory.
#
# `--repo` must follow the subcommand. The PreToolUse hook that blocks the
# agent from running `merge-lock.sh authorize` matches the subcommand in
# argument position 1; a global flag before it would slip past that regex.
#
# authorize takes a comma-separated list whose entries are either bare PR
# numbers, resolved against --repo or the cwd, or repo-qualified tokens:
#
#   merge-lock.sh authorize 92,93 "wave 3" --repo owner/repo
#   merge-lock.sh authorize owner/a#92,owner/b#7 "wave 3"
#
# The qualified form exists so one human command can authorize a fleet-wide
# change; a 26-repo wave otherwise needs 26 invocations. It grants the same
# 30-minute lock per PR and changes no part of the trust model: the hook
# above still blocks the agent from running authorize at all, and every lock
# stays keyed to its own repo. Note that all locks in one batch share a
# timestamp, so 50 of them expire together 30 minutes after the command.
#
# Mobile authorization (issue #509). When the human is away from the laptop,
# `authorize` is unreachable: the Claude Code session runs on the laptop, and
# the phone cannot drive its shell. `redeem` closes that gap without weakening
# the trust model:
#
#   merge-lock.sh enroll <pubkey-file> <principal>   # human-only, one time
#   merge-lock.sh redeem <token>                     # agent may run this
#
# The phone holds an ed25519 private key and signs a payload naming exactly
# one repo, one PR, and an expiry. The laptop holds only the public key. The
# agent is a courier: it can pass a token along, but it cannot manufacture
# one, because it has no private key. That is why `redeem` is deliberately
# NOT blocked by the PreToolUse hook while `authorize` and `enroll` are — the
# signature is the security boundary, not the hook.
#
# The allowed-signers file lives inside LOCK_DIR on purpose, with no env
# override. Any trick that redirects it (e.g. a fake HOME) redirects the lock
# output to the same fake tree, so the forged lock lands somewhere the real
# merge check never reads.
set -euo pipefail
unset CDPATH

LOCK_DIR="${HOME}/.claude/merge-locks"
LOCK_TTL_SECONDS=1800 # 30 minutes

# Signed mobile-authorization tokens (issue #509).
SIGNERS_FILE="${LOCK_DIR}/allowed_signers"
SIG_NAMESPACE="merge-lock"
# Upper bound on how far ahead a token may claim to expire. A signed token is
# a bearer credential until it expires; capping the window limits the damage
# from one that leaks, without forcing the human to re-sign mid-errand.
TOKEN_MAX_LIFETIME_SECONDS=86400 # 24 hours

mkdir -p "${LOCK_DIR}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- Repo resolution ---------------------------------------------------------

# Owner and name are each one path segment: no slashes, no "." or "..".
validate_repo_slug() {
  local slug="$1"
  local owner="${slug%%/*}"
  local name="${slug#*/}"
  [[ "${slug}" == */* ]] || return 1
  [[ "${name}" != */* ]] || return 1
  [[ "${owner}" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  [[ "${name}" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  [[ "${owner}" != "." && "${owner}" != ".." ]] || return 1
  [[ "${name}" != "." && "${name}" != ".." ]] || return 1
  return 0
}

# Populate REPO from --repo or from the cwd. Fails loudly otherwise: a lock
# check that silently fell back to some default would recreate the
# cross-repo collision this keying exists to prevent.
resolve_repo() {
  local override="$1"
  if [[ -n "${override}" ]]; then
    REPO="${override}"
  else
    REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || REPO=""
    if [[ -z "${REPO}" ]]; then
      echo "Error: could not determine the GitHub repo from the current directory." >&2
      echo "Run from inside the repo checkout, or pass --repo OWNER/NAME after the subcommand." >&2
      exit 1
    fi
  fi
  if ! validate_repo_slug "${REPO}"; then
    echo "Error: invalid repo '${REPO}' (expected OWNER/NAME)" >&2
    exit 1
  fi
}

# Optional 2nd argument overrides the repo, for callers handling several in
# one run; defaults to the resolved REPO.
lock_path() {
  echo "${LOCK_DIR}/${2:-${REPO}}/pr-$1.lock"
}

# Split "$@" (everything after the subcommand) into REPO_OVERRIDE and the
# remaining positional args in POSITIONAL. Accepts --repo VALUE and
# --repo=VALUE anywhere among the trailing arguments.
parse_args() {
  REPO_OVERRIDE=""
  POSITIONAL=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        if [[ -z "${2:-}" ]]; then
          echo "Error: --repo requires a value" >&2
          exit 1
        fi
        REPO_OVERRIDE="$2"
        shift 2
        ;;
      --repo=*)
        REPO_OVERRIDE="${1#*=}"
        shift
        ;;
      *)
        POSITIONAL+=("$1")
        shift
        ;;
    esac
  done
}

# --- Lock operations ---------------------------------------------------------

# The optional 4th argument names the repo to write the lock under; it
# defaults to the resolved REPO. Batch authorization passes it per entry so a
# cross-repo batch never has to mutate the global mid-loop — a set -e exit
# partway through would otherwise leave REPO holding some entry's value.
create_merge_lock() {
  local pr_number="$1"
  local reason="$2"
  local ts="$3"
  local repo="${4:-${REPO}}"
  local lock_file
  lock_file=$(lock_path "${pr_number}" "${repo}")

  local user
  user=$(whoami)

  mkdir -p "$(dirname "${lock_file}")"
  {
    echo "PR_NUMBER=${pr_number}"
    echo "REPO=${repo}"
    echo "AUTHORIZED_BY=${user}"
    echo "TIMESTAMP=${ts}"
    echo "REASON=${reason}"
  } >"${lock_file}"

  echo -e "${GREEN}[merge-lock]${NC} Authorization created for ${repo}#${pr_number}"
  echo -e "${GREEN}[merge-lock]${NC} Valid for 30 minutes"
  echo -e "${GREEN}[merge-lock]${NC} Lock file: ${lock_file}"
}

# Every repo-keyed lock file, one path per line, sorted. Exactly three levels
# deep: <owner>/<repo>/pr-N.lock.
find_locks() {
  find "${LOCK_DIR}" -mindepth 3 -maxdepth 3 -type f -name 'pr-*.lock' 2>/dev/null | sort || true
}

# Human-readable label for a lock file, from its own REPO/PR_NUMBER fields.
lock_label() {
  local lock_file="$1"
  local repo pr
  repo=$(grep "^REPO=" "${lock_file}" | cut -d= -f2- || true)
  pr=$(grep "^PR_NUMBER=" "${lock_file}" | cut -d= -f2 || true)
  echo "${repo:-?}#${pr:-?}"
}

purge_expired_locks() {
  local now
  now=$(date +%s)
  local lock_file

  # Flat pr-N.lock files predate repo keying. They carry no repo and can
  # never be matched, so they are removed regardless of age.
  for lock_file in "${LOCK_DIR}"/pr-*.lock; do
    [[ ! -f "${lock_file}" ]] && continue
    local legacy_pr
    legacy_pr=$(grep "^PR_NUMBER=" "${lock_file}" | cut -d= -f2 || true)
    rm -f "${lock_file}"
    echo -e "${YELLOW}[merge-lock]${NC} Purged legacy repo-less lock for PR #${legacy_pr:-?} (re-authorize with the repo-keyed form)"
  done

  local lock_files
  lock_files=$(find_locks)
  while IFS= read -r lock_file; do
    [[ -z "${lock_file}" ]] && continue

    local timestamp
    timestamp=$(grep "^TIMESTAMP=" "${lock_file}" | cut -d= -f2 || true)
    [[ -z "${timestamp}" ]] && continue

    local age=$((now - timestamp))
    if [[ ${age} -gt ${LOCK_TTL_SECONDS} ]]; then
      local label
      label=$(lock_label "${lock_file}")
      rm -f "${lock_file}"
      echo -e "${YELLOW}[merge-lock]${NC} Purged expired lock for ${label}"
    fi
  done <<<"${lock_files}"
}

check_merge_lock() {
  local pr_number="$1"
  local lock_file
  lock_file=$(lock_path "${pr_number}")

  [[ ! -f "${lock_file}" ]] && return 1

  local timestamp
  timestamp=$(grep "^TIMESTAMP=" "${lock_file}" | cut -d= -f2)
  local now
  now=$(date +%s)
  local age=$((now - timestamp))

  if [[ ${age} -gt ${LOCK_TTL_SECONDS} ]]; then
    rm -f "${lock_file}"
    return 1
  fi
  return 0
}

show_status() {
  local pr_number="$1"
  local lock_file
  lock_file=$(lock_path "${pr_number}")

  if [[ -f "${lock_file}" ]]; then
    local timestamp
    timestamp=$(grep "^TIMESTAMP=" "${lock_file}" | cut -d= -f2)
    local now
    now=$(date +%s)
    local age=$((now - timestamp))
    local remaining=$((LOCK_TTL_SECONDS - age))

    if [[ ${remaining} -gt 0 ]]; then
      local auth_by
      auth_by=$(grep "^AUTHORIZED_BY=" "${lock_file}" | cut -d= -f2 || true)
      local auth_reason
      auth_reason=$(grep "^REASON=" "${lock_file}" | cut -d= -f2- || true)
      echo -e "${GREEN}[merge-lock]${NC} ${REPO}#${pr_number} is authorized"
      echo "  Authorized by: ${auth_by}"
      echo "  Reason: ${auth_reason}"
      echo "  Expires in: $((remaining / 60)) minutes"
    else
      echo -e "${YELLOW}[merge-lock]${NC} ${REPO}#${pr_number} authorization expired"
      rm -f "${lock_file}"
    fi
  else
    echo -e "${RED}[merge-lock]${NC} ${REPO}#${pr_number} is NOT authorized"
    echo ""
    echo "To authorize merge (valid 30 minutes):"
    echo "  ~/.claude/hooks/merge-lock.sh authorize ${pr_number} \"reason\" --repo ${REPO}"
  fi
}

list_locks() {
  echo "=== Active Merge Authorizations ==="
  local found=false
  local lock_file lock_files
  lock_files=$(find_locks)
  while IFS= read -r lock_file; do
    [[ -z "${lock_file}" ]] && continue
    found=true
    local label auth reason
    label=$(lock_label "${lock_file}")
    auth=$(grep "^AUTHORIZED_BY=" "${lock_file}" | cut -d= -f2 || true)
    reason=$(grep "^REASON=" "${lock_file}" | cut -d= -f2- || true)
    echo "  ${label} - by ${auth} - ${reason}"
  done <<<"${lock_files}"
  if [[ "${found}" == false ]]; then
    echo "  (none)"
  fi
}

authorize_batch() {
  local pr_arg="$1"
  local reason="$2"

  # Each list entry is either a bare PR number, which resolves against the
  # repo from --repo or the cwd, or a repo-qualified OWNER/NAME#N token. The
  # qualified form lets one human command authorize a fleet-wide change
  # across many repos; without it, a 26-repo wave needs 26 invocations.
  #
  # Parsing and validation complete before any lock is written: a typo in
  # entry 40 of 50 must authorize nothing, rather than leaving the first 39
  # granted and the operator unsure how far it got.
  local _pr_raw
  IFS=',' read -r -a _pr_raw <<<"${pr_arg}"
  local _pr_list=()
  local _repo_list=()
  local _entry
  for _entry in "${_pr_raw[@]}"; do
    # Trim leading/trailing whitespace.
    _entry="${_entry#"${_entry%%[![:space:]]*}"}"
    _entry="${_entry%"${_entry##*[![:space:]]}"}"
    if [[ -z "${_entry}" ]]; then
      echo "Error: empty PR number in list" >&2
      exit 1
    fi

    local _entry_repo _entry_pr
    if [[ "${_entry}" == *"#"* ]]; then
      _entry_repo="${_entry%%#*}"
      _entry_pr="${_entry#*#}"
      # A second '#' would leave a non-numeric remainder; the PR check below
      # rejects it, so no separate arm is needed here.
      if [[ -z "${_entry_repo}" ]]; then
        echo "Error: missing repo before '#' in: ${_entry}" >&2
        exit 1
      fi
      # Reuse the slug validator that guards cwd/--repo resolution: the slug
      # becomes two path segments of the lock path, so a traversing or
      # slash-bearing slug must never reach lock_path.
      if ! validate_repo_slug "${_entry_repo}"; then
        echo "Error: invalid repo '${_entry_repo}' in '${_entry}' (expected OWNER/NAME)" >&2
        exit 1
      fi
    else
      _entry_repo="${REPO}"
      _entry_pr="${_entry}"
    fi

    if [[ ! "${_entry_pr}" =~ ^[0-9]+$ ]] || [[ "${_entry_pr}" -le 0 ]]; then
      echo "Error: invalid PR number: ${_entry}" >&2
      exit 1
    fi
    _pr_list+=("${_entry_pr}")
    _repo_list+=("${_entry_repo}")
  done

  # Shared timestamp so all TTLs align.
  local _ts
  _ts=$(date +%s)
  local _i
  for _i in "${!_pr_list[@]}"; do
    create_merge_lock "${_pr_list[${_i}]}" "${reason}" "${_ts}" "${_repo_list[${_i}]}"
  done
}

# --- Mobile authorization (issue #509) ---------------------------------------

# Register a phone's public key under a principal name. Human-only, like
# authorize: enrolling a key the agent generated would hand it the power to
# mint its own authorizations, which is the one thing this whole file exists
# to prevent.
enroll_signer() {
  local pubkey_file="$1"
  local principal="$2"

  if [[ ! -f "${pubkey_file}" ]]; then
    echo "Error: no such public key file: ${pubkey_file}" >&2
    exit 1
  fi
  # The principal becomes a field in allowed_signers, which is whitespace
  # separated; a value containing spaces would silently shift every later
  # column and change which key the entry actually trusts.
  if [[ ! "${principal}" =~ ^[A-Za-z0-9_.@-]+$ ]]; then
    echo "Error: invalid principal '${principal}' (letters, digits, . _ - @ only)" >&2
    exit 1
  fi

  local key_line
  key_line=$(tr -d '\r' <"${pubkey_file}" | grep -E '^(ssh|sk-ssh|ecdsa|sk-ecdsa)' | head -1 || true)
  if [[ -z "${key_line}" ]]; then
    echo "Error: ${pubkey_file} does not look like an SSH public key" >&2
    echo "Expected a line beginning with ssh-ed25519, ssh-rsa, or similar." >&2
    exit 1
  fi

  # Key type and base64 body only: a trailing comment is free-text and would
  # be compared as part of the duplicate check below.
  local key_type key_body
  key_type=$(awk '{print $1}' <<<"${key_line}")
  key_body=$(awk '{print $2}' <<<"${key_line}")
  if [[ -z "${key_body}" ]]; then
    echo "Error: malformed public key in ${pubkey_file}" >&2
    exit 1
  fi

  touch "${SIGNERS_FILE}"
  chmod 600 "${SIGNERS_FILE}"
  if grep -qF " ${key_type} ${key_body}" "${SIGNERS_FILE}"; then
    echo -e "${YELLOW}[merge-lock]${NC} That key is already enrolled; nothing to do."
    return 0
  fi

  printf '%s %s %s\n' "${principal}" "${key_type}" "${key_body}" >>"${SIGNERS_FILE}"
  echo -e "${GREEN}[merge-lock]${NC} Enrolled '${principal}' for mobile authorization"
  echo -e "${GREEN}[merge-lock]${NC} Signers file: ${SIGNERS_FILE}"
}

list_signers() {
  echo "=== Enrolled Mobile Signers ==="
  if [[ ! -s "${SIGNERS_FILE}" ]]; then
    echo "  (none)"
    return 0
  fi
  local principal key_type key_body fingerprint tmp_pub
  tmp_pub=$(mktemp)
  # Trapped rather than removed at the end: under set -e a malformed line
  # could exit the loop early and strand the file.
  trap 'rm -f "${tmp_pub}"' RETURN
  while read -r principal key_type key_body _; do
    [[ -z "${principal}" ]] && continue
    printf '%s %s\n' "${key_type}" "${key_body}" >"${tmp_pub}"
    fingerprint=$(ssh-keygen -lf "${tmp_pub}" 2>/dev/null | awk '{print $2}' || true)
    echo "  ${principal} - ${key_type} - ${fingerprint:-unknown fingerprint}"
  done <"${SIGNERS_FILE}"
}

# Consume a signed token and, if it verifies, create the lock it names.
#
# Token layout, base64 of:
#   <payload line>\n<ssh signature armor>
# where the payload is exactly:
#   v1 OWNER/REPO#N exp=<unix seconds>
#
# Everything that matters is inside the signed payload: repo, PR, and expiry.
# Nothing about the token is trusted before `ssh-keygen -Y verify` succeeds.
redeem_token() {
  local token="$1"

  if [[ ! -s "${SIGNERS_FILE}" ]]; then
    echo "Error: no mobile signers are enrolled." >&2
    echo "On the laptop, run: merge-lock.sh enroll <pubkey-file> <principal>" >&2
    exit 1
  fi

  local decoded
  # Tokens are pasted through chat clients that love to insert newlines.
  token=$(tr -d '[:space:]' <<<"${token}")
  if ! decoded=$(printf '%s' "${token}" | base64 -d 2>/dev/null); then
    echo "Error: token is not valid base64." >&2
    exit 1
  fi

  local payload
  payload=$(head -1 <<<"${decoded}")
  local sig_armor
  sig_armor=$(tail -n +2 <<<"${decoded}")
  if [[ -z "${payload}" || -z "${sig_armor}" ]]; then
    echo "Error: malformed token (expected a payload line and a signature)." >&2
    exit 1
  fi

  local sig_file
  sig_file=$(mktemp)
  # ssh-keygen reads the signature from a file, never stdin, so the armor has
  # to land on disk. Trapped so none of the exits below strand it.
  trap 'rm -f "${sig_file}"' RETURN
  printf '%s\n' "${sig_armor}" >"${sig_file}"

  # Two ssh-keygen calls, not one, because they answer different questions and
  # `verify` cannot do the first on its own:
  #
  #   find-principals - "does any enrolled key match this signature?" and,
  #                     if so, under what name. Without it the caller would
  #                     have to be told which identity to expect, which the
  #                     token cannot be trusted to state about itself.
  #   verify          - "is this signature genuinely that principal's, over
  #                     this exact payload, in this namespace?"
  #
  # find-principals alone is not sufficient: it establishes that a signature
  # traces to an enrolled key, and verify is what binds it to the payload.
  local principal
  if ! principal=$(printf '%s' "${payload}" |
    ssh-keygen -Y find-principals -s "${sig_file}" -f "${SIGNERS_FILE}" -n "${SIG_NAMESPACE}" 2>/dev/null); then
    echo "Error: token signature does not match any enrolled key." >&2
    echo "Either the token was tampered with, or that phone's key is not enrolled." >&2
    exit 1
  fi
  # One key may be enrolled under several principals; any of them verifying is
  # enough, so take the first.
  principal=$(head -1 <<<"${principal}")

  if ! printf '%s' "${payload}" |
    ssh-keygen -Y verify -f "${SIGNERS_FILE}" -I "${principal}" \
      -n "${SIG_NAMESPACE}" -s "${sig_file}" >/dev/null 2>&1; then
    echo "Error: token signature failed verification." >&2
    exit 1
  fi

  # Only now is the payload trustworthy enough to parse.
  local version target expiry_field
  read -r version target expiry_field _ <<<"${payload}"
  if [[ "${version}" != "v1" ]]; then
    echo "Error: unsupported token version '${version}' (this build understands v1)." >&2
    exit 1
  fi
  if [[ "${target}" != *"#"* ]]; then
    echo "Error: malformed token target '${target}' (expected OWNER/REPO#N)." >&2
    exit 1
  fi

  local token_repo token_pr
  token_repo="${target%%#*}"
  token_pr="${target#*#}"
  if ! validate_repo_slug "${token_repo}"; then
    echo "Error: token names an invalid repo '${token_repo}'." >&2
    exit 1
  fi
  if [[ ! "${token_pr}" =~ ^[0-9]+$ ]] || [[ "${token_pr}" -le 0 ]]; then
    echo "Error: token names an invalid PR number '${token_pr}'." >&2
    exit 1
  fi

  if [[ "${expiry_field}" != exp=* ]]; then
    echo "Error: token is missing its expiry field." >&2
    exit 1
  fi
  local expiry="${expiry_field#exp=}"
  if [[ ! "${expiry}" =~ ^[0-9]+$ ]]; then
    echo "Error: token has a malformed expiry '${expiry}'." >&2
    exit 1
  fi

  local now
  now=$(date +%s)
  if [[ "${expiry}" -le "${now}" ]]; then
    echo "Error: token expired $(((now - expiry) / 60)) minute(s) ago." >&2
    echo "Sign a fresh one on the phone." >&2
    exit 1
  fi
  # A signature is valid forever, so a token claiming a far-future expiry
  # would be a permanent merge credential. Reject rather than silently clamp:
  # the human should see that the signing step asked for too long a window.
  if [[ $((expiry - now)) -gt "${TOKEN_MAX_LIFETIME_SECONDS}" ]]; then
    echo "Error: token lifetime exceeds the ${TOKEN_MAX_LIFETIME_SECONDS}s maximum." >&2
    exit 1
  fi

  # Replay guard. The token stays valid until its own expiry, which may be
  # far longer than a lock's TTL; without this, one token could silently
  # re-authorize the same PR again after its lock had expired.
  local replay_dir="${LOCK_DIR}/.redeemed"
  mkdir -p "${replay_dir}"
  local token_id
  token_id=$(printf '%s' "${payload}" | shasum -a 256 | awk '{print $1}')
  local replay_marker="${replay_dir}/${token_id}"
  if [[ -f "${replay_marker}" ]]; then
    echo "Error: this token has already been redeemed." >&2
    echo "Each signed token authorizes one merge. Sign a fresh one on the phone." >&2
    exit 1
  fi

  local ts
  ts=$(date +%s)
  create_merge_lock "${token_pr}" "mobile authorization by ${principal}" "${ts}" "${token_repo}"

  # Record the redemption only after the lock exists, so a failure to write
  # the lock does not burn the token.
  printf 'PAYLOAD=%s\nREDEEMED_AT=%s\nPRINCIPAL=%s\n' "${payload}" "${ts}" "${principal}" >"${replay_marker}"

  # Markers are only needed while the token could still be replayed, so drop
  # any whose payload expiry has passed.
  local marker marker_exp
  for marker in "${replay_dir}"/*; do
    [[ -f "${marker}" ]] || continue
    marker_exp=$(grep "^PAYLOAD=" "${marker}" | sed -n 's/.*exp=\([0-9]*\).*/\1/p' || true)
    if [[ -n "${marker_exp}" ]] && [[ "${marker_exp}" -le "${now}" ]]; then
      rm -f "${marker}"
    fi
  done

  echo -e "${GREEN}[merge-lock]${NC} Redeemed mobile token signed by '${principal}'"
}

# --- Dispatch ----------------------------------------------------------------

SUBCOMMAND="${1:-help}"
if [[ $# -gt 0 ]]; then
  shift
fi
parse_args "$@"

case "${SUBCOMMAND}" in
  authorize | auth)
    if [[ -z "${POSITIONAL[0]:-}" ]]; then
      echo "Usage: $0 authorize <pr[,pr...]> <reason> [--repo OWNER/NAME]" >&2
      echo "       each pr is N (uses --repo/cwd) or OWNER/NAME#N" >&2
      exit 1
    fi
    if [[ -z "${POSITIONAL[1]:-}" ]]; then
      echo "Error: reason is required" >&2
      echo "Usage: $0 authorize <pr[,pr...]> <reason> [--repo OWNER/NAME]" >&2
      echo "       each pr is N (uses --repo/cwd) or OWNER/NAME#N" >&2
      exit 1
    fi

    resolve_repo "${REPO_OVERRIDE}"
    authorize_batch "${POSITIONAL[0]}" "${POSITIONAL[1]}"
    ;;
  check)
    if [[ -z "${POSITIONAL[0]:-}" ]]; then
      echo "Usage: $0 check <pr_number> [--repo OWNER/NAME]"
      exit 1
    fi
    resolve_repo "${REPO_OVERRIDE}"
    purge_expired_locks
    if check_merge_lock "${POSITIONAL[0]}"; then
      echo "Authorized"
      exit 0
    else
      echo "Not authorized"
      exit 1
    fi
    ;;
  status)
    if [[ -z "${POSITIONAL[0]:-}" ]]; then
      echo "Usage: $0 status <pr_number> [--repo OWNER/NAME]"
      exit 1
    fi
    resolve_repo "${REPO_OVERRIDE}"
    purge_expired_locks
    show_status "${POSITIONAL[0]}"
    ;;
  list)
    purge_expired_locks
    list_locks
    ;;
  enroll)
    if [[ -z "${POSITIONAL[0]:-}" || -z "${POSITIONAL[1]:-}" ]]; then
      echo "Usage: $0 enroll <pubkey-file> <principal>" >&2
      exit 1
    fi
    enroll_signer "${POSITIONAL[0]}" "${POSITIONAL[1]}"
    ;;
  signers)
    list_signers
    ;;
  redeem)
    if [[ -z "${POSITIONAL[0]:-}" ]]; then
      echo "Usage: $0 redeem <token>" >&2
      exit 1
    fi
    purge_expired_locks
    redeem_token "${POSITIONAL[0]}"
    ;;
  *)
    echo "Usage: $0 {authorize|check|status|list|enroll|signers|redeem} [args...] [--repo OWNER/NAME]"
    echo ""
    echo "Commands:"
    echo "  authorize <pr[,pr...]> <reason>  - Create merge authorization(s) (30 min TTL)"
    echo "  check <pr>               - Check if PR is authorized (exit 0/1)"
    echo "  status <pr>              - Show detailed authorization status"
    echo "  list                     - List all active authorizations"
    echo ""
    echo "Mobile authorization (when you are away from the laptop):"
    echo "  enroll <pubkey> <name>   - Trust a phone's public key (human-only, one time)"
    echo "  signers                  - List enrolled mobile signers"
    echo "  redeem <token>           - Consume a phone-signed token and create the lock"
    echo ""
    echo "Locks are keyed on repo + PR number. The repo comes from --repo OWNER/NAME"
    echo "(after the subcommand) or from 'gh repo view' in the current directory."
    ;;
esac
