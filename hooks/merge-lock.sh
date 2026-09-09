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
set -euo pipefail
unset CDPATH

LOCK_DIR="${HOME}/.claude/merge-locks"
LOCK_TTL_SECONDS=1800 # 30 minutes

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
  *)
    echo "Usage: $0 {authorize|check|status|list} [args...] [--repo OWNER/NAME]"
    echo ""
    echo "Commands:"
    echo "  authorize <pr[,pr...]> <reason>  - Create merge authorization(s) (30 min TTL)"
    echo "  check <pr>               - Check if PR is authorized (exit 0/1)"
    echo "  status <pr>              - Show detailed authorization status"
    echo "  list                     - List all active authorizations"
    echo ""
    echo "Locks are keyed on repo + PR number. The repo comes from --repo OWNER/NAME"
    echo "(after the subcommand) or from 'gh repo view' in the current directory."
    ;;
esac
