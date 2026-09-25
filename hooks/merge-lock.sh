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
# timestamp, so 50 of them expire together when the window elapses.
#
# Lock lifetime defaults to 30 minutes and is set per batch with --ttl, in
# minutes, up to 8 hours (issue #501):
#
#   merge-lock.sh authorize 92,93,94 "wave 3" --ttl 180
#
# The flag exists because a sequential wave is authorized once but merged one
# at a time: with a fixed 30-minute window, the seventh PR expires because the
# first six were slow, and the human is interrupted to re-authorize work they
# already approved. Each lock records its own TTL, so changing the default
# later cannot retroactively shorten a lock already granted, and locks written
# before TTL_SECONDS existed still read as 30 minutes.
#
set -euo pipefail
unset CDPATH

LOCK_DIR="${HOME}/.claude/merge-locks"
LOCK_TTL_SECONDS=1800 # 30 minutes, the default when --ttl is not given

# Upper bound on --ttl (issue #501). A sequential wave of PRs can easily run
# past 30 minutes, and the seventh should not expire because the first six
# were slow. A ceiling still applies: an authorization is a standing
# permission to merge without asking again, and one left open for days stops
# meaning what the human meant when they granted it.
MAX_TTL_SECONDS=28800 # 8 hours


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
    # Recorded so error messages can name the input the human supplied. When
    # the repo came from the cwd, that input is a directory they never
    # consciously passed, which is exactly what makes #471 hard to spot.
    REPO_SOURCE="--repo"
  else
    REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || REPO=""
    if [[ -z "${REPO}" ]]; then
      echo "Error: could not determine the GitHub repo from the current directory." >&2
      echo "Run from inside the repo checkout, or pass --repo OWNER/NAME after the subcommand." >&2
      exit 1
    fi
    REPO_SOURCE="cwd"
  fi
  if ! validate_repo_slug "${REPO}"; then
    echo "Error: invalid repo '${REPO}' (expected OWNER/NAME)" >&2
    exit 1
  fi
}

# Explain where a repo slug came from, for error messages. The cwd case names
# the directory: it is the input the human did not realize they were giving.
repo_origin_note() {
  local repo="$1"
  if [[ "${repo}" == "${REPO:-}" && "${REPO_SOURCE:-}" == "cwd" ]]; then
    echo "The repo was resolved from the current directory (${PWD})."
  else
    echo "The repo came from the authorize command line."
  fi
}

# Confirm PR <n> exists in <repo>.
#
#   0 - the PR exists
#   1 - the API answered, and there is no such PR
#   2 - the API could not be reached, or said nothing usable
#
# The 2 case matters. This puts a network call on a path that previously made
# none, so an outage or an expired token must not lock the human out of
# authorizing a merge. Callers treat 2 as "warn and proceed", preserving the
# old behavior, and hard-fail only on 1.
#
# Two calls rather than one, because `gh pr view` fails identically for "no
# such PR" and "no such repo / cannot reach GitHub". Probing the repo first
# separates them without parsing error text, which varies by gh version.
pr_exists() {
  local pr="$1"
  local repo="$2"

  if ! gh repo view "${repo}" --json nameWithOwner >/dev/null 2>&1; then
    # Either the repo is gone or the API is unreachable; both are
    # indistinguishable here and both are "cannot say", not "does not exist".
    return 2
  fi
  if gh pr view "${pr}" --repo "${repo}" --json number >/dev/null 2>&1; then
    return 0
  fi
  # The repo resolved a moment ago, so the API is reachable and this is a
  # genuine "no such PR" rather than an outage.
  return 1
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
  TTL_OVERRIDE=""
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
      --ttl)
        if [[ -z "${2:-}" ]]; then
          echo "Error: --ttl requires a value in minutes" >&2
          exit 1
        fi
        TTL_OVERRIDE="$2"
        shift 2
        ;;
      --ttl=*)
        TTL_OVERRIDE="${1#*=}"
        shift
        ;;
      *)
        POSITIONAL+=("$1")
        shift
        ;;
    esac
  done
}

# Convert a --ttl value in minutes to seconds, or exit with a usage error.
resolve_ttl() {
  local minutes="$1"
  if [[ -z "${minutes}" ]]; then
    echo "${LOCK_TTL_SECONDS}"
    return 0
  fi
  if [[ ! "${minutes}" =~ ^[0-9]+$ ]] || [[ "${minutes}" -le 0 ]]; then
    echo "Error: --ttl must be a positive whole number of minutes (got '${minutes}')" >&2
    exit 1
  fi
  local seconds=$((minutes * 60))
  # Refuse rather than clamp: silently shortening a window the human asked
  # for would expire a batch mid-run, which is the failure this flag exists
  # to prevent.
  if [[ "${seconds}" -gt "${MAX_TTL_SECONDS}" ]]; then
    echo "Error: --ttl ${minutes} exceeds the maximum of $((MAX_TTL_SECONDS / 60)) minutes" >&2
    exit 1
  fi
  echo "${seconds}"
}

# A lock's own TTL, falling back to the default for locks written before
# TTL_SECONDS was recorded. Without the fallback, every pre-existing lock
# would read as TTL 0 and be purged on the next run.
lock_ttl() {
  local lock_file="$1"
  local ttl
  ttl=$(grep "^TTL_SECONDS=" "${lock_file}" | cut -d= -f2 || true)
  if [[ "${ttl}" =~ ^[0-9]+$ ]] && [[ "${ttl}" -gt 0 ]]; then
    echo "${ttl}"
  else
    echo "${LOCK_TTL_SECONDS}"
  fi
}

# --- Authorization ledger ----------------------------------------------------

# Append-only record of every lock granted (dev-env#109). A lock file is
# deleted when it expires, so without this there is nothing left to show that a
# merge was ever authorized, and a merge done in the GitHub UI looks exactly
# like one that went through the gate. scripts/merge-audit.sh joins merged PRs
# against this file to make those merges visible.
#
# It lives inside LOCK_DIR so the same Write/Edit and Bash write blocks that
# protect the locks also protect it. find_locks only matches
# <owner>/<repo>/pr-N.lock and the legacy purge only matches pr-*.lock at the
# top level, so neither touches this file.
#
# The header records when recording began. The audit reports a merge older
# than that as unclassified rather than unauthorized, because the ledger
# cannot speak to a time before it existed.
LEDGER_FILE="${LOCK_DIR}/ledger.tsv"

append_ledger() {
  local ts="$1" repo="$2" pr="$3" ttl="$4" user="$5" reason="$6"
  if [[ ! -f "${LEDGER_FILE}" ]]; then
    # noclobber makes creation atomic: if two authorize runs race here, the
    # loser's `>` fails instead of truncating the winner's header and rows.
    (
      set -o noclobber
      printf '# merge-lock ledger v1, started %s\n# timestamp\trepo\tpr\tttl_seconds\tauthorized_by\treason\n' \
        "${ts}" >"${LEDGER_FILE}"
    ) 2>/dev/null || true
  fi
  # Tabs and newlines in the free-text reason would corrupt the row layout.
  reason="${reason//$'\t'/ }"
  reason="${reason//$'\n'/ }"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${ts}" "${repo}" "${pr}" "${ttl}" "${user}" "${reason}" >>"${LEDGER_FILE}"
}

# --- Lock operations ---------------------------------------------------------

# The optional 4th argument names the repo to write the lock under; it
# defaults to the resolved REPO. Batch authorization passes it per entry so a
# cross-repo batch never has to mutate the global mid-loop — a set -e exit
# partway through would otherwise leave REPO holding some entry's value.
# The optional 5th argument is the lifetime in seconds; it defaults to the
# 30-minute standard. It is written into the lock rather than read from the
# global at check time, so changing the default later cannot retroactively
# shorten or extend a lock the human already granted.
create_merge_lock() {
  local pr_number="$1"
  local reason="$2"
  local ts="$3"
  local repo="${4:-${REPO}}"
  local ttl="${5:-${LOCK_TTL_SECONDS}}"
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
    echo "TTL_SECONDS=${ttl}"
    echo "REASON=${reason}"
  } >"${lock_file}"

  append_ledger "${ts}" "${repo}" "${pr_number}" "${ttl}" "${user}" "${reason}"

  echo -e "${GREEN}[merge-lock]${NC} Authorization created for ${repo}#${pr_number}"
  echo -e "${GREEN}[merge-lock]${NC} Valid for $((ttl / 60)) minutes"
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
    local ttl
    ttl=$(lock_ttl "${lock_file}")
    if [[ ${age} -gt ${ttl} ]]; then
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
  local ttl
  ttl=$(lock_ttl "${lock_file}")

  if [[ ${age} -gt ${ttl} ]]; then
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
    local ttl
    ttl=$(lock_ttl "${lock_file}")
    local remaining=$((ttl - age))

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
  local lock_file lock_files now
  now=$(date +%s)
  lock_files=$(find_locks)
  while IFS= read -r lock_file; do
    [[ -z "${lock_file}" ]] && continue
    found=true
    local label auth reason timestamp ttl remaining
    label=$(lock_label "${lock_file}")
    auth=$(grep "^AUTHORIZED_BY=" "${lock_file}" | cut -d= -f2 || true)
    reason=$(grep "^REASON=" "${lock_file}" | cut -d= -f2- || true)
    # Remaining time is the thing you actually need when working a batch:
    # it answers "will the last PR still be authorized when I reach it?"
    timestamp=$(grep "^TIMESTAMP=" "${lock_file}" | cut -d= -f2 || true)
    ttl=$(lock_ttl "${lock_file}")
    if [[ "${timestamp}" =~ ^[0-9]+$ ]]; then
      # Expiry is `age > ttl`, matching purge_expired_locks and
      # check_merge_lock, so a lock aged exactly to its TTL is still valid.
      # Report sub-minute time left as "<1m" rather than truncating to "0m",
      # which reads as expired for a lock check would still accept
      # (claude-config#515). A lock that is genuinely past its window can
      # reach here only when listed without a purge, so label it rather than
      # printing a negative.
      remaining=$((ttl - (now - timestamp)))
      if [[ ${remaining} -lt 0 ]]; then
        echo "  ${label} - by ${auth} - ${reason} (expired)"
      elif [[ ${remaining} -lt 60 ]]; then
        echo "  ${label} - by ${auth} - ${reason} (<1m left)"
      else
        echo "  ${label} - by ${auth} - ${reason} ($((remaining / 60))m left)"
      fi
    else
      echo "  ${label} - by ${auth} - ${reason}"
    fi
  done <<<"${lock_files}"
  if [[ "${found}" == false ]]; then
    echo "  (none)"
  fi
}

authorize_batch() {
  local pr_arg="$1"
  local reason="$2"
  local ttl="${3:-${LOCK_TTL_SECONDS}}"

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

  # Confirm every pair exists before writing any lock (issue #471).
  #
  # Syntactic validation above cannot catch the real failure: a well-formed
  # repo and a well-formed PR number that simply do not belong together. That
  # happens when the cwd is a different checkout than the PR, and every step
  # succeeds while the composite answer is wrong. The lock is then correctly
  # keyed, correctly formatted, and authorizes nothing — surfacing much later
  # as a merge refusal whose stated cause is true but unhelpful.
  #
  # Runs as its own pass, before any write, so a bad entry at position 40 of
  # 50 authorizes nothing rather than leaving 39 granted.
  local _unreachable=false
  local _i
  for _i in "${!_pr_list[@]}"; do
    local _check_pr="${_pr_list[${_i}]}" _check_repo="${_repo_list[${_i}]}"
    local _rc=0
    pr_exists "${_check_pr}" "${_check_repo}" || _rc=$?
    case "${_rc}" in
      0) ;;
      1)
        local _origin
        _origin=$(repo_origin_note "${_check_repo}")
        echo "Error: ${_check_repo} has no PR #${_check_pr}." >&2
        echo "${_origin}" >&2
        echo "If the PR is in another repo, pass --repo OWNER/NAME after the subcommand," >&2
        echo "or name it inline as OWNER/NAME#${_check_pr}." >&2
        exit 1
        ;;
      *)
        # Degrade to the pre-#471 behavior rather than blocking a merge on a
        # network problem. Warn once, not once per entry in a 50-PR batch.
        if [[ "${_unreachable}" == false ]]; then
          echo -e "${YELLOW}[merge-lock]${NC} Could not reach GitHub to confirm the PR exists; authorizing anyway." >&2
          _unreachable=true
        fi
        ;;
    esac
  done

  # Shared timestamp so all TTLs align.
  local _ts
  _ts=$(date +%s)
  for _i in "${!_pr_list[@]}"; do
    create_merge_lock "${_pr_list[${_i}]}" "${reason}" "${_ts}" "${_repo_list[${_i}]}" "${ttl}"
  done
}


# --- Bulk selection ----------------------------------------------------------

# Owners whose PRs the operator can actually merge. Scoping the search this way
# is what excludes PRs opened against upstream repos owned by someone else:
# they would list as "mine" by author but grant a lock nobody can use.
TUI_OWNERS=(smartwatermelon nightowlstudiollc twistedmelonman)
TUI_SEARCH_LIMIT=200

# Print one candidate per line as "OWNER/NAME#N<TAB>title".
#
# Mergeability is not a field on `gh search prs`, so each hit needs a second
# per-PR lookup. Drafts are excluded by the search itself; merged and closed
# PRs by --state open.
tui_collect() {
  local owner_args=()
  local _owner
  for _owner in "${TUI_OWNERS[@]}"; do
    owner_args+=(--owner "${_owner}")
  done

  local search_json
  if ! search_json=$(gh search prs --state=open --draft=false \
    "${owner_args[@]}" --limit "${TUI_SEARCH_LIMIT}" \
    --json number,title,repository </dev/null 2>/dev/null); then
    echo "Error: could not search GitHub for open PRs." >&2
    exit 1
  fi

  local lines
  lines=$(printf '%s' "${search_json}" |
    jq -r '.[] | "\(.repository.nameWithOwner)#\(.number)\t\(.title)"')
  [[ -n "${lines}" ]] || return 0

  local line token title repo pr state mergeable status
  while IFS=$'\t' read -r token title; do
    [[ -n "${token}" ]] || continue
    repo="${token%%#*}"
    pr="${token#*#}"
    # </dev/null matters: without it this inherits the caller's stdin and
    # swallows the selection the fallback picker is about to read.
    if ! state=$(gh pr view "${pr}" --repo "${repo}" \
      --json mergeable,mergeStateStatus </dev/null 2>/dev/null); then
      # A PR that cannot be inspected cannot be judged mergeable. Skipping it
      # is the safe direction: the operator can still authorize it by number.
      continue
    fi
    mergeable=$(printf '%s' "${state}" | jq -r '.mergeable // "UNKNOWN"')
    status=$(printf '%s' "${state}" | jq -r '.mergeStateStatus // "UNKNOWN"')

    case "${mergeable}" in
      MERGEABLE)
        if [[ "${status}" == "BLOCKED" ]]; then
          continue
        fi
        printf '%s\t%s\n' "${token}" "${title}"
        ;;
      UNKNOWN)
        # GitHub computes mergeability lazily, so a PR pushed seconds ago
        # reports UNKNOWN rather than a real answer. Marking it beats hiding
        # it: the operator decides, and a stale lock costs nothing.
        printf '%s\t? %s\n' "${token}" "${title}"
        ;;
      *)
        # CONFLICTING and anything else GitHub adds later.
        continue
        ;;
    esac
  done <<<"${lines}"
}

# Take the candidate list as an argument and write the chosen OWNER/NAME#N
# tokens on stdout, one per line.
#
# The candidates arrive as an argument rather than on stdin because the
# fallback picker needs stdin for the operator's answer. Reading both from one
# stream makes the list drain the selection along with itself, and the prompt
# then sees EOF and reads as "cancel".
tui_select() {
  local candidate_block="$1"

  if command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "${candidate_block}" |
      fzf --multi --with-nth=1.. --prompt='authorize> ' |
      while IFS=$'\t' read -r token _rest; do
        [[ -n "${token}" ]] && printf '%s\n' "${token}"
      done
    return 0
  fi

  # Numbered fallback, so the subcommand still works where fzf is absent.
  local candidates=()
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] && candidates+=("${line}")
  done <<<"${candidate_block}"
  local _i
  for _i in "${!candidates[@]}"; do
    printf '%3d) %s\n' "$((_i + 1))" "${candidates[${_i}]//$'\t'/  }" >&2
  done
  printf 'Select numbers (space separated), or blank to cancel: ' >&2
  local picks
  read -r picks || picks=""
  local pick
  for pick in ${picks}; do
    [[ "${pick}" =~ ^[0-9]+$ ]] || continue
    ((pick >= 1 && pick <= ${#candidates[@]})) || continue
    printf '%s\n' "${candidates[$((pick - 1))]%%$'\t'*}"
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
      echo "Usage: $0 authorize <pr[,pr...]> <reason> [--repo OWNER/NAME] [--ttl MINUTES]" >&2
      echo "       each pr is N (uses --repo/cwd) or OWNER/NAME#N" >&2
      exit 1
    fi
    if [[ -z "${POSITIONAL[1]:-}" ]]; then
      echo "Error: reason is required" >&2
      echo "Usage: $0 authorize <pr[,pr...]> <reason> [--repo OWNER/NAME] [--ttl MINUTES]" >&2
      echo "       each pr is N (uses --repo/cwd) or OWNER/NAME#N" >&2
      exit 1
    fi

    resolve_repo "${REPO_OVERRIDE}"
    TTL_SECONDS_RESOLVED=$(resolve_ttl "${TTL_OVERRIDE}")
    authorize_batch "${POSITIONAL[0]}" "${POSITIONAL[1]}" "${TTL_SECONDS_RESOLVED}"
    ;;
  tui)
    # Every candidate token is repo-qualified, so no repo needs resolving —
    # the cwd may not be a repo at all. The reason is an optional positional
    # rather than a prompt: fzf consumes stdin, so a read here would need
    # /dev/tty and would make the subcommand impossible to drive in a test.
    _tui_reason="${POSITIONAL[0]:-bulk authorize}"
    _tui_candidates=$(tui_collect)
    if [[ -z "${_tui_candidates}" ]]; then
      echo "No open, mergeable PRs found."
      exit 0
    fi
    _tui_picked=$(tui_select "${_tui_candidates}")
    if [[ -z "${_tui_picked}" ]]; then
      echo "Nothing selected; no locks granted."
      exit 0
    fi
    # Guard the join: a bare number reaching authorize_batch would resolve
    # against an unset REPO. Every token from tui_collect is qualified, so an
    # unqualified one means the pipeline is broken, not that the user typed it.
    while IFS= read -r _tui_tok; do
      [[ -z "${_tui_tok}" ]] && continue
      if [[ "${_tui_tok}" != *"#"* ]]; then
        echo "Error: unqualified selection '${_tui_tok}'" >&2
        exit 1
      fi
    done <<<"${_tui_picked}"
    _tui_joined=$(printf '%s\n' "${_tui_picked}" | paste -sd, -)
    authorize_batch "${_tui_joined}" "${_tui_reason}"
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
    echo "Usage: $0 {authorize|tui|check|status|list} [args...] [--repo OWNER/NAME] [--ttl MINUTES]"
    echo ""
    echo "Commands:"
    echo "  authorize <pr[,pr...]> <reason>  - Create merge authorization(s)"
    echo "        --ttl MINUTES      - Lifetime, default 30, max $((MAX_TTL_SECONDS / 60))."
    echo "                             Use it for a sequential batch, so the last PR"
    echo "                             is still authorized when you reach it."
    echo "  tui [reason]             - Pick open mergeable PRs from a list and authorize them"
    echo "  check <pr>               - Check if PR is authorized (exit 0/1)"
    echo "  status <pr>              - Show detailed authorization status"
    echo "  list                     - List all active authorizations"
    echo ""
    echo "Locks are keyed on repo + PR number. The repo comes from --repo OWNER/NAME"
    echo "(after the subcommand) or from 'gh repo view' in the current directory."
    ;;
esac
