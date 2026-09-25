#!/usr/bin/env bash
# ~/.claude/scripts/merge-audit.sh
# List merged PRs that had no merge-lock authorization (dev-env#109).
#
# A merge done in the GitHub web or mobile UI skips pre-merge-review.sh and
# the merge-lock check entirely, and nothing records that it happened. This
# script makes those merges visible after the fact: it lists every PR merged
# since a date, across the owners below, and joins each one against the
# append-only ledger that `merge-lock.sh authorize` writes.
#
# Usage:
#   merge-audit.sh --since YYYY-MM-DD [--owner OWNER[=TOKEN_VAR]]...
#                  [--ledger PATH]... [--all]
#
#   --since    Required. Merges on or after this UTC date are audited.
#   --owner    Audit only these owners. Defaults to all three. Each owner is
#              read with its own token, named indirectly (the variable NAME,
#              never the value). Built-in: smartwatermelon=GH_TOKEN_SWM,
#              nightowlstudiollc=GH_TOKEN_NOS, twistedmelonman=GH_TOKEN_TWM.
#   --ledger   Ledger file(s) to read. Defaults to
#              ~/.claude/merge-locks/ledger.tsv. Pass one per machine to audit
#              authorizations granted on several laptops.
#   --all      Also print LOCKED and BOT rows, not just the ones needing
#              attention.
#
# Output: one tab-separated row per merged PR, then a summary.
#
#   STATUS  OWNER/REPO#N  MERGED_AT  AUTHOR  URL  TITLE
#
# There is no merged-by column: the PR list endpoint omits it, and it would say
# twistedmelonman for every merge anyway, agent or human.
#
#   LOCKED         A ledger lock for this exact repo and PR was live at merge
#                  time (see the window below).
#   NO_LOCK        No ledger row for this repo and PR. A UI merge, or a merge
#                  on a machine whose ledger was not passed.
#   LOCK_NOT_LIVE  Ledger rows exist for this PR, but none was live at merge
#                  time.
#   UNCLASSIFIED   Merged before the ledger started. The ledger cannot speak
#                  to that time, so this is NOT a clean result.
#   BOT            Bot-authored (e.g. Dependabot) with no lock. Auto-merge is
#                  policy for these; listed only with --all.
#
# Exit status: 0 only when every non-bot merge is LOCKED; 1 when anything is
# NO_LOCK, LOCK_NOT_LIVE or UNCLASSIFIED (an unknown is not a pass); 2 on a
# usage error or when any owner or repo could not be read. A partial
# read exits 2 even if the rows it did get are clean: an audit that silently
# skips a repo reports success while checking nothing.
#
# What LOCKED does and does not prove. It means an authorization for this PR
# was live when GitHub recorded the merge. It does not prove the merge went
# through pre-merge-review.sh: a UI merge inside a live window also reads
# LOCKED. The window is [lock - SKEW, lock + TTL + ANALYSIS + SKEW], because
# pre-merge-review.sh checks the lock before its analysis runs, and the merge
# lands only after that analysis, which can take up to its 900-second ceiling.
set -euo pipefail
unset CDPATH

SKEW_SECONDS=120
ANALYSIS_SECONDS=900

declare -A TOKEN_VAR_FOR=(
  [smartwatermelon]=GH_TOKEN_SWM
  [nightowlstudiollc]=GH_TOKEN_NOS
  [twistedmelonman]=GH_TOKEN_TWM
)
DEFAULT_OWNERS=(smartwatermelon nightowlstudiollc twistedmelonman)

usage() {
  sed -n '12,26p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

SINCE=""
OWNERS=()
LEDGERS=()
SHOW_ALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)
      [[ -n "${2:-}" ]] || usage
      SINCE="$2"
      shift 2
      ;;
    --since=*)
      SINCE="${1#*=}"
      shift
      ;;
    --owner)
      [[ -n "${2:-}" ]] || usage
      OWNERS+=("$2")
      shift 2
      ;;
    --owner=*)
      OWNERS+=("${1#*=}")
      shift
      ;;
    --ledger)
      [[ -n "${2:-}" ]] || usage
      LEDGERS+=("$2")
      shift 2
      ;;
    --ledger=*)
      LEDGERS+=("${1#*=}")
      shift
      ;;
    --all)
      SHOW_ALL=true
      shift
      ;;
    -h | --help) usage ;;
    *)
      echo "Error: unknown argument: $1" >&2
      usage
      ;;
  esac
done

if [[ ! "${SINCE}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "Error: --since YYYY-MM-DD is required" >&2
  usage
fi
if ! SINCE_EPOCH=$(jq -nr --arg d "${SINCE}T00:00:00Z" '$d | fromdateiso8601' 2>/dev/null); then
  echo "Error: --since is not a real date: ${SINCE}" >&2
  exit 2
fi

[[ ${#OWNERS[@]} -gt 0 ]] || OWNERS=("${DEFAULT_OWNERS[@]}")
[[ ${#LEDGERS[@]} -gt 0 ]] || LEDGERS=("${HOME}/.claude/merge-locks/ledger.tsv")

# --- Ledger ------------------------------------------------------------------

# LOCKS["owner/repo#n"] holds space-separated "timestamp:ttl" pairs. Keys are
# lowercased: GitHub treats owner and repo names case-insensitively, and a
# human typing --repo may not match the API's casing.
declare -A LOCKS=()
LEDGER_START=""

for ledger in "${LEDGERS[@]}"; do
  if [[ ! -f "${ledger}" ]]; then
    echo "Warning: ledger not found: ${ledger}" >&2
    continue
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^#\ merge-lock\ ledger\ v1,\ started\ ([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      if [[ -z "${LEDGER_START}" || "${start}" -lt "${LEDGER_START}" ]]; then
        LEDGER_START="${start}"
      fi
      continue
    fi
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    IFS=$'\t' read -r ts repo pr ttl _rest <<<"${line}"
    if [[ ! "${ts}" =~ ^[0-9]+$ || ! "${pr}" =~ ^[0-9]+$ || ! "${ttl}" =~ ^[0-9]+$ || -z "${repo}" ]]; then
      echo "Warning: skipping malformed ledger row in ${ledger}: ${line}" >&2
      continue
    fi
    key="${repo,,}#${pr}"
    LOCKS["${key}"]="${LOCKS["${key}"]:-} ${ts}:${ttl}"
  done <"${ledger}"
done

if [[ -z "${LEDGER_START}" ]]; then
  echo "Warning: no ledger start found; every merge will be UNCLASSIFIED." >&2
fi

# Print the status for one merged PR.
classify() {
  local key="$1" merged="$2" author="$3"
  local entries="${LOCKS["${key,,}"]:-}"
  if [[ -n "${entries}" ]]; then
    local entry ts ttl
    for entry in ${entries}; do
      ts="${entry%%:*}"
      ttl="${entry#*:}"
      if ((merged >= ts - SKEW_SECONDS && merged <= ts + ttl + ANALYSIS_SECONDS + SKEW_SECONDS)); then
        echo LOCKED
        return
      fi
    done
  fi
  if [[ -z "${LEDGER_START}" ]] || ((merged < LEDGER_START)); then
    echo UNCLASSIFIED
    return
  fi
  if [[ -n "${entries}" ]]; then
    echo LOCK_NOT_LIVE
    return
  fi
  if [[ "${author}" == *"[bot]" || "${author}" == app/* ]]; then
    echo BOT
    return
  fi
  echo NO_LOCK
}

# --- GitHub ------------------------------------------------------------------

READ_ERRORS=0
declare -A COUNT=([LOCKED]=0 [NO_LOCK]=0 [LOCK_NOT_LIVE]=0 [UNCLASSIFIED]=0 [BOT]=0)

# Print "number<TAB>merged_epoch<TAB>merged_at<TAB>author<TAB>url<TAB>title"
# for every PR in <repo> merged at or after SINCE_EPOCH.
#
# Pages closed PRs sorted by updated_at, newest first, and stops after the
# first page whose LAST row was updated before SINCE. Why that cannot miss a
# merge inside the window:
#   1. Merging a PR updates it, so updated_at >= merged_at for every merged PR.
#   2. The sort is by updated_at, so every row on later pages has an
#      updated_at at or below that last row's, which is below SINCE.
#   3. By (1), each of those rows was merged before SINCE, or not at all.
# A PR merged long ago but commented on recently sorts early and is paged
# over, then dropped by the merged_at filter: that costs a request, not a
# miss. The stop deliberately does not use merged_at, which is not the sort
# key and so says nothing about later pages.
#
# REST rather than search, because search results are token-scoped and
# index-lagged. One residual gap: a PR updated while the audit is paging moves
# to page 1 and shifts the rest down by one, so a row at a page boundary can be
# skipped. Re-running closes it; the audit is not meant to race live merges.
merged_prs() {
  local repo="$1"
  local page=1 body
  while :; do
    if ! body=$(gh api "repos/${repo}/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=${page}"); then
      return 1
    fi
    printf '%s' "${body}" | jq -r --argjson since "${SINCE_EPOCH}" '
      .[]
      | select(.merged_at != null)
      | (.merged_at | fromdateiso8601) as $m
      | select($m >= $since)
      | [ .number, $m, .merged_at, (.user.login // "?"),
          .html_url, (.title | gsub("[\t\n]"; " ")) ]
      | @tsv' || return 1
    local n oldest
    # A non-array body (an error object) must fail the repo, not read as zero
    # merges.
    n=$(printf '%s' "${body}" | jq 'if type == "array" then length else error("not a list") end') || return 1
    [[ "${n}" -lt 100 ]] && return 0
    oldest=$(printf '%s' "${body}" | jq '.[-1].updated_at | fromdateiso8601')
    [[ "${oldest}" -lt "${SINCE_EPOCH}" ]] && return 0
    page=$((page + 1))
  done
}

audit_owner() {
  local owner="$1" token_var="$2"
  if [[ -z "${token_var}" ]]; then
    echo "Error: no token variable known for owner '${owner}'; pass --owner ${owner}=VAR" >&2
    READ_ERRORS=$((READ_ERRORS + 1))
    return
  fi
  if [[ -z "${!token_var:-}" ]]; then
    echo "Error: ${token_var} is not set; cannot audit ${owner}" >&2
    READ_ERRORS=$((READ_ERRORS + 1))
    return
  fi
  local GH_TOKEN="${!token_var}"
  export GH_TOKEN

  local repos
  if ! repos=$(gh repo list "${owner}" --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner'); then
    echo "Error: could not list repos for ${owner}" >&2
    READ_ERRORS=$((READ_ERRORS + 1))
    return
  fi
  if [[ -z "${repos}" ]]; then
    echo "Error: ${owner} returned no repos; the token may not cover it" >&2
    READ_ERRORS=$((READ_ERRORS + 1))
    return
  fi

  local repo rows number merged merged_at author url title status
  while IFS= read -r repo; do
    [[ -z "${repo}" ]] && continue
    if ! rows=$(merged_prs "${repo}"); then
      echo "Error: could not read merged PRs for ${repo}" >&2
      READ_ERRORS=$((READ_ERRORS + 1))
      continue
    fi
    while IFS=$'\t' read -r number merged merged_at author url title; do
      [[ -z "${number}" ]] && continue
      status=$(classify "${repo}#${number}" "${merged}" "${author}")
      COUNT["${status}"]=$((COUNT["${status}"] + 1))
      if [[ "${SHOW_ALL}" == true || ("${status}" != LOCKED && "${status}" != BOT) ]]; then
        printf '%s\t%s#%s\t%s\t%s\t%s\t%s\n' "${status}" "${repo}" "${number}" \
          "${merged_at}" "${author}" "${url}" "${title}"
      fi
    done <<<"${rows}"
  done <<<"${repos}"
}

for spec in "${OWNERS[@]}"; do
  if [[ "${spec}" == *=* ]]; then
    audit_owner "${spec%%=*}" "${spec#*=}"
  else
    audit_owner "${spec}" "${TOKEN_VAR_FOR[${spec}]:-}"
  fi
done

ledger_note="none"
if [[ -n "${LEDGER_START}" ]]; then
  ledger_note=$(jq -nr --argjson t "${LEDGER_START}" '$t | todateiso8601')
fi
printf '# since=%s ledger_start=%s locked=%d no_lock=%d lock_not_live=%d unclassified=%d bot=%d read_errors=%d\n' \
  "${SINCE}" "${ledger_note}" "${COUNT[LOCKED]}" "${COUNT[NO_LOCK]}" "${COUNT[LOCK_NOT_LIVE]}" \
  "${COUNT[UNCLASSIFIED]}" "${COUNT[BOT]}" "${READ_ERRORS}"

if ((READ_ERRORS > 0)); then
  exit 2
fi
if ((COUNT[NO_LOCK] + COUNT[LOCK_NOT_LIVE] + COUNT[UNCLASSIFIED] > 0)); then
  exit 1
fi
exit 0
