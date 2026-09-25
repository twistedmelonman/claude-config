#!/usr/bin/env bats
# Tests for scripts/merge-audit.sh and the merge-lock ledger it reads
# (dev-env#109).
# Run: bats tests/test_merge_audit.bats
#
# The audit exists because a UI merge skips the merge-lock gate silently. Most
# cases below are known-bad: each proves a merge that was NOT authorized is
# reported, never passed as clean.

AUDIT="${BATS_TEST_DIRNAME}/../scripts/merge-audit.sh"
LOCK_SCRIPT="${BATS_TEST_DIRNAME}/../hooks/merge-lock.sh"
WRITE_HOOK="${BATS_TEST_DIRNAME}/../scripts/hook-block-merge-locks-write.sh"

# 2026-09-01T00:00:00Z, the --since date used throughout.
SINCE_DATE=2026-09-01
SINCE_EPOCH=1788220800

setup() {
  unset BASH_ENV
  unset CDPATH
  unset -f gh 2>/dev/null || true
  export -n gh 2>/dev/null || true

  TMP="$(mktemp -d)"
  export HOME="${TMP}/home"
  mkdir -p "${HOME}" "${TMP}/bin" "${TMP}/fx"
  export STUB_FX="${TMP}/fx"
  export STUB_LOG="${TMP}/gh-calls.log"
  : >"${STUB_LOG}"

  install_audit_stub
  export PATH="${TMP}/bin:${PATH}"

  export GH_TOKEN_SWM=tok-swm GH_TOKEN_NOS=tok-nos GH_TOKEN_TWM=tok-twm
  LEDGER="${TMP}/ledger.tsv"
}

install_audit_stub() {
  # gh stub. `repo list OWNER` prints fx/repos-OWNER; `api repos/O/R/pulls...
  # &page=N` prints fx/pulls-O_R-N.json. A missing fixture fails like an API
  # error. Every call logs its args and the token it saw, so tests can prove
  # each owner is read with its own token.
  cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'token=%s args=%s\n' "${GH_TOKEN:-}" "$*" >>"${STUB_LOG}"
if [[ "$1 $2" == "repo list" ]]; then
  f="${STUB_FX}/repos-$3"
  [[ -f "${f}" ]] || { echo "stub: no repos for $3" >&2; exit 1; }
  cat "${f}"
  exit 0
fi
if [[ "$1" == "api" ]]; then
  path="${2%%\?*}"
  repo="${path#repos/}"
  repo="${repo%/pulls}"
  page="${2##*page=}"
  f="${STUB_FX}/pulls-${repo//\//_}-${page}.json"
  [[ -f "${f}" ]] || { echo "stub: no fixture ${f}" >&2; exit 1; }
  cat "${f}"
  exit 0
fi
echo "stub: unhandled: $*" >&2
exit 1
STUB
  chmod +x "${TMP}/bin/gh"
}

teardown() {
  rm -rf "${TMP}"
}

iso() { jq -nr --argjson t "$1" '$t | todateiso8601'; }

# repos OWNER REPO... : the repos gh repo list returns for OWNER.
repos() {
  local owner="$1"
  shift
  printf '%s\n' "$@" >"${STUB_FX}/repos-${owner}"
}

# pulls OWNER/REPO PAGE JSON : one page of the closed-PR listing.
pulls() {
  printf '%s' "$3" >"${STUB_FX}/pulls-${1//\//_}-$2.json"
}

# pr NUMBER MERGED_EPOCH [AUTHOR] : one merged PR object.
pr() {
  local m
  m="$(iso "$2")"
  jq -nc --argjson n "$1" --arg m "${m}" --arg a "${3:-twistedmelonman}" \
    '{number:$n, merged_at:$m, updated_at:$m, merged_by:{login:"twistedmelonman"},
      user:{login:$a}, html_url:"https://example.test/pr/\($n)", title:"PR \($n)"}'
}

# ledger START [ROW...] : write a ledger started at START; each row is
# "ts repo pr ttl".
ledger() {
  local start="$1"
  shift
  printf '# merge-lock ledger v1, started %s\n' "${start}" >"${LEDGER}"
  local row ts repo n ttl
  for row in "$@"; do
    read -r ts repo n ttl <<<"${row}"
    printf '%s\t%s\t%s\t%s\tandrewrich\treason\n' "${ts}" "${repo}" "${n}" "${ttl}" >>"${LEDGER}"
  done
}

MERGED=$((SINCE_EPOCH + 86400)) # a merge one day into the window
START=$((SINCE_EPOCH - 86400))  # ledger started before the window

run_audit() {
  run "${AUDIT}" --since "${SINCE_DATE}" --owner acme=GH_TOKEN_SWM --ledger "${LEDGER}" "$@"
}

# --- Known-bad: merges without a live authorization are reported -------------

@test "known-bad: a merge with no ledger row is NO_LOCK and exits 1" {
  repos acme acme/widgets
  pulls acme/widgets 1 "[$(pr 7 "${MERGED}")]"
  ledger "${START}"
  run_audit
  [ "${status}" -eq 1 ]
  [[ "${output}" == *$'NO_LOCK\tacme/widgets#7'* ]]
}

@test "known-bad: a lock for the same PR number in another repo does not clear it" {
  repos acme acme/widgets
  pulls acme/widgets 1 "[$(pr 7 "${MERGED}")]"
  ledger "${START}" "$((MERGED - 60)) acme/gadgets 7 1800"
  run_audit
  [ "${status}" -eq 1 ]
  [[ "${output}" == *$'NO_LOCK\tacme/widgets#7'* ]]
}

@test "known-bad: a lock for another PR in the same repo does not clear it" {
  repos acme acme/widgets
  pulls acme/widgets 1 "[$(pr 7 "${MERGED}")]"
  ledger "${START}" "$((MERGED - 60)) acme/widgets 8 1800"
  run_audit
  [ "${status}" -eq 1 ]
  [[ "${output}" == *$'NO_LOCK\tacme/widgets#7'* ]]
}

@test "known-bad: a lock that expired before the merge is LOCK_NOT_LIVE" {
  repos acme acme/widgets
  pulls acme/widgets 1 "[$(pr 7 "${MERGED}")]"
  # Granted two hours before the merge with a 30-minute TTL: past TTL, the
  # 900s analysis allowance, and the 120s skew allowance.
  ledger "${START}" "$((MERGED - 7200)) acme/widgets 7 1800"
  run_audit
  [ "${status}" -eq 1 ]
  [[ "${output}" == *$'LOCK_NOT_LIVE\tacme/widgets#7'* ]]
}

@test "known-bad: a lock granted after the merge does not clear it" {
  repos acme acme/widgets
  pulls acme/widgets 1 "[$(pr 7 "${MERGED}")]"
  ledger "${START}" "$((MERGED + 600)) acme/widgets 7 1800"
  run_audit
  [ "${status}" -eq 1 ]
  [[ "${output}" == *$'LOCK_NOT_LIVE\tacme/widgets#7'* ]]
}

@test "known-bad: a merge before the ledger started is UNCLASSIFIED, not clean" {
  repos acme acme/widgets
  pulls acme/widgets 1 "[$(pr 7 "${MERGED}")]"
  ledger "$((MERGED + 3600))"
  run_audit
  [ "${status}" -eq 1 ]
  [[ "${output}" == *$'UNCLASSIFIED\tacme/widgets#7'* ]]
}

@test "known-bad: a missing ledger makes every merge UNCLASSIFIED, not clean" {
  repos acme acme/widgets
  pulls acme/widgets 1 "[$(pr 7 "${MERGED}")]"
  run_audit
  [ "${status}" -eq 1 ]
  [[ "${output}" == *$'UNCLASSIFIED\tacme/widgets#7'* ]]
  [[ "${output}" == *"ledger not found"* ]]
}

@test "known-bad: an unreadable repo exits 2 even when the other repos are clean" {
  repos acme acme/widgets acme/broken
  pulls acme/widgets 1 "[$(pr 7 "${MERGED}")]"
  ledger "${START}" "$((MERGED - 60)) acme/widgets 7 1800"
  run_audit
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"could not read merged PRs for acme/broken"* ]]
}

@test "known-bad: an error object from the API fails the repo instead of reading as no merges" {
  repos acme acme/widgets
  pulls acme/widgets 1 '{"message":"Bad credentials"}'
  ledger "${START}"
  run_audit
  [ "${status}" -eq 2 ]
}

@test "known-bad: an unset token variable exits 2 without calling gh" {
  unset GH_TOKEN_SWM
  ledger "${START}"
  run_audit
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"GH_TOKEN_SWM is not set"* ]]
  [ ! -s "${STUB_LOG}" ]
}

@test "known-bad: an owner listing no repos exits 2 rather than reading as clean" {
  repos acme
  : >"${STUB_FX}/repos-acme"
  ledger "${START}"
  run_audit
  [ "${status}" -eq 2 ]
}

# --- Positive cases ------------------------------------------------------------

@test "a merge inside a live lock window is LOCKED and exits 0" {
  repos acme acme/widgets
  pulls acme/widgets 1 "[$(pr 7 "${MERGED}")]"
  ledger "${START}" "$((MERGED - 300)) acme/widgets 7 1800"
  run_audit --all
  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'LOCKED\tacme/widgets#7'* ]]
}

@test "a merge landing after TTL but within the analysis allowance is LOCKED" {
  repos acme acme/widgets
  pulls acme/widgets 1 "[$(pr 7 "${MERGED}")]"
  # 1800s TTL + 600s: pre-merge-review checked the lock, then analysis ran.
  ledger "${START}" "$((MERGED - 2400)) acme/widgets 7 1800"
  run_audit
  [ "${status}" -eq 0 ]
}

@test "ledger repo matching is case-insensitive" {
  repos acme Acme/Widgets
  pulls Acme/Widgets 1 "[$(pr 7 "${MERGED}")]"
  ledger "${START}" "$((MERGED - 60)) acme/widgets 7 1800"
  run_audit
  [ "${status}" -eq 0 ]
}

@test "LOCKED rows are hidden without --all" {
  repos acme acme/widgets
  pulls acme/widgets 1 "[$(pr 7 "${MERGED}")]"
  ledger "${START}" "$((MERGED - 60)) acme/widgets 7 1800"
  run_audit
  [ "${status}" -eq 0 ]
  [[ "${output}" != *$'LOCKED\t'* ]]
  [[ "${output}" == *"locked=1 no_lock=0"* ]]
}

@test "a bot-authored merge with no lock is BOT and does not fail the audit" {
  repos acme acme/widgets
  pulls acme/widgets 1 "[$(pr 9 "${MERGED}" 'dependabot[bot]')]"
  ledger "${START}"
  run_audit
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"bot=1"* ]]
}

@test "merges before --since and unmerged closed PRs are ignored" {
  repos acme acme/widgets
  local closed
  closed=$(jq -nc '{number:3, merged_at:null, updated_at:"2026-09-03T00:00:00Z", user:{login:"x"}, html_url:"u", title:"t"}')
  pulls acme/widgets 1 "[$(pr 5 $((SINCE_EPOCH - 60))), ${closed}]"
  ledger "${START}"
  run_audit
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"locked=0 no_lock=0 lock_not_live=0 unclassified=0"* ]]
}

@test "each default owner is read with its own token" {
  repos smartwatermelon smartwatermelon/a
  repos nightowlstudiollc nightowlstudiollc/b
  repos twistedmelonman twistedmelonman/c
  pulls smartwatermelon/a 1 '[]'
  pulls nightowlstudiollc/b 1 '[]'
  pulls twistedmelonman/c 1 '[]'
  ledger "${START}"
  run "${AUDIT}" --since "${SINCE_DATE}" --ledger "${LEDGER}"
  [ "${status}" -eq 0 ]
  grep -q 'token=tok-swm args=repo list smartwatermelon' "${STUB_LOG}"
  grep -q 'token=tok-nos args=api repos/nightowlstudiollc/b/pulls' "${STUB_LOG}"
  grep -q 'token=tok-twm args=repo list twistedmelonman' "${STUB_LOG}"
}

@test "a full page whose oldest PR is still in the window fetches the next page" {
  repos acme acme/widgets
  local page1
  page1=$(for i in $(seq 1 100); do pr "$((i + 100))" "${MERGED}"; done | jq -sc '.')
  pulls acme/widgets 1 "${page1}"
  pulls acme/widgets 2 "[$(pr 7 "${MERGED}")]"
  ledger "${START}"
  run_audit
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"no_lock=101"* ]]
}

@test "a full page whose oldest PR predates the window stops paging" {
  repos acme acme/widgets
  local page1
  page1=$(for i in $(seq 1 100); do pr "$((i + 100))" $((SINCE_EPOCH - 60)); done | jq -sc '.')
  pulls acme/widgets 1 "${page1}"
  # No page 2 fixture: fetching it would fail the audit with exit 2.
  ledger "${START}"
  run_audit
  [ "${status}" -eq 0 ]
}

@test "known-bad: a merge in the window is not missed behind a page of recently-updated old merges" {
  repos acme acme/widgets
  # Page 1: 100 PRs merged before SINCE but commented on inside the window,
  # so they sort first by updated_at. The in-window merge is on page 2.
  local page1 upd
  upd="$(iso $((MERGED + 3600)))"
  page1=$(for i in $(seq 1 100); do
    pr "$((i + 100))" $((SINCE_EPOCH - 86400)) | jq -c --arg u "${upd}" '.updated_at = $u'
  done | jq -sc '.')
  pulls acme/widgets 1 "${page1}"
  pulls acme/widgets 2 "[$(pr 7 "${MERGED}")]"
  ledger "${START}"
  run_audit
  [ "${status}" -eq 1 ]
  [[ "${output}" == *$'NO_LOCK\tacme/widgets#7'* ]]
  [[ "${output}" == *"no_lock=1 "* ]]
}

@test "--since is required and validated" {
  run "${AUDIT}"
  [ "${status}" -eq 2 ]
  run "${AUDIT}" --since 2026-13-45
  [ "${status}" -eq 2 ]
}

# --- The ledger merge-lock.sh writes -----------------------------------------

lock_stub() {
  # merge-lock.sh resolves the repo and probes PR existence through gh.
  cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "${TMP}/bin/gh"
}

@test "authorize appends one ledger row per lock, with a single header" {
  lock_stub
  run "${LOCK_SCRIPT}" authorize 7 "first" --repo acme/widgets
  [ "${status}" -eq 0 ]
  run "${LOCK_SCRIPT}" authorize acme/widgets#8,acme/gadgets#9 "second" --repo acme/widgets --ttl 60
  [ "${status}" -eq 0 ]
  local f="${HOME}/.claude/merge-locks/ledger.tsv"
  [ "$(grep -c '^# merge-lock ledger v1, started ' "${f}")" -eq 1 ]
  [ "$(grep -vc '^#' "${f}")" -eq 3 ]
  awk -F'\t' '$1 ~ /^[0-9]+$/ && $2 == "acme/widgets" && $3 == "7" && $4 == "1800" && $6 == "first"' "${f}" | grep -q .
  awk -F'\t' '$1 ~ /^[0-9]+$/ && $2 == "acme/gadgets" && $3 == "9" && $4 == "3600" && $6 == "second"' "${f}" | grep -q .
}

@test "an existing ledger keeps its header and start time" {
  lock_stub
  local dir="${HOME}/.claude/merge-locks"
  mkdir -p "${dir}"
  printf '# merge-lock ledger v1, started 1\n' >"${dir}/ledger.tsv"
  run "${LOCK_SCRIPT}" authorize 7 "r" --repo acme/widgets
  [ "${status}" -eq 0 ]
  [ "$(grep -c '^# merge-lock ledger v1' "${dir}/ledger.tsv")" -eq 1 ]
  grep -q '^# merge-lock ledger v1, started 1$' "${dir}/ledger.tsv"
  [ "$(grep -vc '^#' "${dir}/ledger.tsv")" -eq 1 ]
}

@test "a tab or newline in the reason cannot add ledger columns or rows" {
  lock_stub
  run "${LOCK_SCRIPT}" authorize 7 $'a\tb\nc' --repo acme/widgets
  [ "${status}" -eq 0 ]
  local f="${HOME}/.claude/merge-locks/ledger.tsv"
  [ "$(grep -vc '^#' "${f}")" -eq 1 ]
  [ "$(grep -v '^#' "${f}" | awk -F'\t' '{print NF}')" -eq 6 ]
}

@test "the ledger survives lock expiry and purge" {
  lock_stub
  run "${LOCK_SCRIPT}" authorize 7 "r" --repo acme/widgets
  local lock="${HOME}/.claude/merge-locks/acme/widgets/pr-7.lock"
  local ts
  ts=$(grep '^TIMESTAMP=' "${lock}" | cut -d= -f2)
  local tmp
  tmp=$(mktemp)
  sed "s/^TIMESTAMP=.*/TIMESTAMP=$((ts - 7200))/" "${lock}" >"${tmp}"
  mv "${tmp}" "${lock}"
  run "${LOCK_SCRIPT}" list
  [ "${status}" -eq 0 ]
  [ ! -f "${lock}" ]
  [ "$(grep -vc '^#' "${HOME}/.claude/merge-locks/ledger.tsv")" -eq 1 ]
}

@test "a ledger merge-lock.sh wrote is read by the audit as LOCKED" {
  lock_stub
  run "${LOCK_SCRIPT}" authorize 7 "r" --repo acme/widgets
  [ "${status}" -eq 0 ]
  # Swap back to the audit stub and merge "now".
  install_audit_stub
  repos acme acme/widgets
  pulls acme/widgets 1 "[$(pr 7 "$(date +%s)")]"
  run "${AUDIT}" --since "${SINCE_DATE}" --owner acme=GH_TOKEN_SWM
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"locked=1"* ]]
}

@test "known-bad: the agent's Write tool cannot write the ledger" {
  local payload
  payload=$(jq -nc --arg p "${HOME}/.claude/merge-locks/ledger.tsv" '{tool_input:{file_path:$p}}')
  run bash -c "printf '%s' '${payload}' | '${WRITE_HOOK}'"
  [ "${status}" -eq 2 ]
}
