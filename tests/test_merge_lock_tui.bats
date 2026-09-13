#!/usr/bin/env bats
# Tests for the bulk-authorize picker (issue #508).
# Run: bats tests/test_merge_lock_tui.bats
#
# The motivating case: a wave of PRs across several repos is authorized one
# command at a time, so the operator retypes numbers they just read off a
# screen. `tui` lists the open, mergeable PRs and grants locks for the ones
# picked.
#
# Both halves are driven without a terminal: the fzf stub reads the candidate
# list on stdin and prints a fixed pick, and the fallback path reads its
# selection numbers the same way. That is also why the reason is a positional
# argument rather than a prompt.

SCRIPT="${BATS_TEST_DIRNAME}/../hooks/merge-lock.sh"
HOOK="${BATS_TEST_DIRNAME}/../scripts/hook-block-merge-lock-authorize.sh"

setup() {
  # The real gh is an exported shell function, and it shadows the PATH stub
  # below unless both it and BASH_ENV are cleared. Without this, every call
  # fails on the wrapper's identity check instead of reaching the stub.
  unset BASH_ENV
  unset CDPATH
  unset -f gh 2>/dev/null || true
  export -n gh 2>/dev/null || true

  TMP_HOME="$(mktemp -d)"
  readonly TMP_HOME
  # Exported, not just set: the fzf stub writes its recorded args and stdin
  # under this directory, and it runs as a separate process.
  export TMP_HOME
  export HOME="${TMP_HOME}"
  mkdir -p "${TMP_HOME}/bin"

  # Candidates the search returns, as "repo#number|title" records.
  export SEARCH_PRS="acme/widgets#10|Fix the thing
acme/widgets#11|Bump a dep
other/gadgets#7|Rework the parser"

  # Per-PR mergeability, as "repo#number=MERGEABLE:CLEAN" records. Anything
  # absent from this table reports MERGEABLE:CLEAN.
  export PR_STATES=""

  # Arg-aware gh stub: `search prs` emits the SEARCH_PRS table as JSON,
  # `pr view` answers from PR_STATES.
  cat >"${TMP_HOME}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "search" && "${2:-}" == "prs" ]]; then
  printf '['
  first=1
  while IFS='|' read -r token title; do
    [[ -n "${token}" ]] || continue
    repo="${token%%#*}"; num="${token#*#}"
    [[ "${first}" -eq 1 ]] || printf ','
    first=0
    printf '{"number":%s,"title":"%s","repository":{"nameWithOwner":"%s"}}' \
      "${num}" "${title}" "${repo}"
  done <<<"${SEARCH_PRS}"
  printf ']\n'
  exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
  num="$3"; repo=""
  shift 3
  while [[ $# -gt 0 ]]; do
    [[ "$1" == "--repo" ]] && repo="$2"
    shift
  done
  want="${repo}#${num}"
  answer="MERGEABLE:CLEAN"
  for rec in ${PR_STATES}; do
    [[ "${rec%%=*}" == "${want}" ]] && answer="${rec#*=}"
  done
  [[ "${answer}" == "MISSING" ]] && exit 1
  printf '{"mergeable":"%s","mergeStateStatus":"%s"}\n' "${answer%%:*}" "${answer#*:}"
  exit 0
fi
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  echo acme/widgets
  exit 0
fi
exit 1
STUB
  chmod +x "${TMP_HOME}/bin/gh"
  export PATH="${TMP_HOME}/bin:${PATH}"
}

teardown() {
  rm -rf "${TMP_HOME}"
}

# Install an fzf stub that records its arguments and its stdin, then prints
# the candidate lines matching the tokens in FZF_PICK.
stub_fzf() {
  cat >"${TMP_HOME}/bin/fzf" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${TMP_HOME}/fzf-args"
cat >"${TMP_HOME}/fzf-stdin"
for want in ${FZF_PICK:-}; do
  grep -F "${want}	" "${TMP_HOME}/fzf-stdin" || true
done
STUB
  chmod +x "${TMP_HOME}/bin/fzf"
}

# Remove fzf from PATH entirely, to exercise the numbered fallback.
hide_fzf() {
  mkdir -p "${TMP_HOME}/only"
  cp "${TMP_HOME}/bin/gh" "${TMP_HOME}/only/gh"
  export PATH="${TMP_HOME}/only:/usr/bin:/bin"
}

lock_file() {
  local repo="${1%%#*}" pr="${1#*#}"
  echo "${TMP_HOME}/.claude/merge-locks/${repo}/pr-${pr}.lock"
}

# --- selection grants locks --------------------------------------------------

@test "tui grants a lock for the selected PR" {
  stub_fzf
  FZF_PICK="acme/widgets#10" run bash "${SCRIPT}" tui "wave 3"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 'acme/widgets#10')" ]
}

@test "tui does not grant a lock for an unselected PR" {
  stub_fzf
  FZF_PICK="acme/widgets#10" run bash "${SCRIPT}" tui "wave 3"
  [ "${status}" -eq 0 ]
  [ ! -f "$(lock_file 'acme/widgets#11')" ]
}

@test "tui grants locks across different repos in one pass" {
  stub_fzf
  FZF_PICK="acme/widgets#10 other/gadgets#7" run bash "${SCRIPT}" tui "wave 3"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 'acme/widgets#10')" ]
  [ -f "$(lock_file 'other/gadgets#7')" ]
}

@test "each lock lands under its own repo, not the cwd's" {
  # The whole point of the qualified token: a lock for other/gadgets#7 must
  # not be written under acme/widgets, which is what gh repo view returns.
  stub_fzf
  FZF_PICK="other/gadgets#7" run bash "${SCRIPT}" tui "wave 3"
  [ "${status}" -eq 0 ]
  [ ! -f "${TMP_HOME}/.claude/merge-locks/acme/widgets/pr-7.lock" ]
}

@test "the reason argument is recorded on the lock" {
  stub_fzf
  FZF_PICK="acme/widgets#10" run bash "${SCRIPT}" tui "wave 3"
  [ "${status}" -eq 0 ]
  grep -q "^REASON=wave 3$" "$(lock_file 'acme/widgets#10')"
}

@test "the reason is optional" {
  stub_fzf
  FZF_PICK="acme/widgets#10" run bash "${SCRIPT}" tui
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 'acme/widgets#10')" ]
}

# --- empty cases -------------------------------------------------------------

@test "selecting nothing grants no locks and exits clean" {
  stub_fzf
  FZF_PICK="" run bash "${SCRIPT}" tui "wave 3"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Nothing selected"* ]]
  [ ! -d "${TMP_HOME}/.claude/merge-locks/acme" ]
}

@test "no candidates at all exits clean with a message" {
  stub_fzf
  SEARCH_PRS="" run bash "${SCRIPT}" tui "wave 3"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No open, mergeable PRs"* ]]
}

# --- filtering ---------------------------------------------------------------

@test "a BLOCKED PR is not offered" {
  stub_fzf
  PR_STATES="acme/widgets#10=MERGEABLE:BLOCKED" \
    FZF_PICK="acme/widgets#10" run bash "${SCRIPT}" tui "wave 3"
  [ "${status}" -eq 0 ]
  [ ! -f "$(lock_file 'acme/widgets#10')" ]
}

@test "a CONFLICTING PR is not offered" {
  stub_fzf
  PR_STATES="acme/widgets#10=CONFLICTING:DIRTY" \
    FZF_PICK="acme/widgets#10" run bash "${SCRIPT}" tui "wave 3"
  [ "${status}" -eq 0 ]
  [ ! -f "$(lock_file 'acme/widgets#10')" ]
}

@test "an UNKNOWN PR is offered, marked rather than dropped" {
  # GitHub computes mergeability lazily, so a PR pushed seconds ago reports
  # UNKNOWN. Hiding it would silently omit exactly the PR just worked on.
  stub_fzf
  PR_STATES="acme/widgets#10=UNKNOWN:UNKNOWN" \
    FZF_PICK="acme/widgets#10" run bash "${SCRIPT}" tui "wave 3"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 'acme/widgets#10')" ]
  grep -q "?" "${TMP_HOME}/fzf-stdin"
}

@test "a PR that cannot be inspected is skipped rather than offered" {
  stub_fzf
  PR_STATES="acme/widgets#10=MISSING" \
    FZF_PICK="acme/widgets#10" run bash "${SCRIPT}" tui "wave 3"
  [ "${status}" -eq 0 ]
  [ ! -f "$(lock_file 'acme/widgets#10')" ]
}

@test "the candidate list shows repo#number and title" {
  stub_fzf
  FZF_PICK="acme/widgets#10" run bash "${SCRIPT}" tui "wave 3"
  [ "${status}" -eq 0 ]
  grep -q "acme/widgets#10" "${TMP_HOME}/fzf-stdin"
  grep -q "Fix the thing" "${TMP_HOME}/fzf-stdin"
}

@test "fzf is asked for a multi-select" {
  stub_fzf
  FZF_PICK="acme/widgets#10" run bash "${SCRIPT}" tui "wave 3"
  [ "${status}" -eq 0 ]
  grep -q -- "--multi" "${TMP_HOME}/fzf-args"
}

# --- fallback without fzf ----------------------------------------------------

@test "the numbered fallback grants the selected lock without fzf" {
  hide_fzf
  run bash -c "printf '1\n' | bash '${SCRIPT}' tui 'wave 3'"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 'acme/widgets#10')" ]
}

@test "the numbered fallback accepts several picks" {
  hide_fzf
  run bash -c "printf '1 3\n' | bash '${SCRIPT}' tui 'wave 3'"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 'acme/widgets#10')" ]
  [ -f "$(lock_file 'other/gadgets#7')" ]
}

@test "the numbered fallback treats a blank line as cancel" {
  hide_fzf
  run bash -c "printf '\n' | bash '${SCRIPT}' tui 'wave 3'"
  [ "${status}" -eq 0 ]
  [ ! -d "${TMP_HOME}/.claude/merge-locks/acme" ]
}

@test "the numbered fallback ignores an out-of-range pick" {
  hide_fzf
  run bash -c "printf '99\n' | bash '${SCRIPT}' tui 'wave 3'"
  [ "${status}" -eq 0 ]
  [ ! -d "${TMP_HOME}/.claude/merge-locks/acme" ]
}

# --- help --------------------------------------------------------------------

@test "tui appears in the usage text" {
  run bash "${SCRIPT}" help
  [[ "${output}" == *"tui"* ]]
}

# --- the hook blocks it ------------------------------------------------------
#
# tui grants locks, so it must be as unreachable to the agent as authorize is.
# These live here rather than in the hook's own test file because that file is
# added on another branch; keeping them together avoids an add/add conflict.

@test "the hook blocks the .sh spelling of tui" {
  run bash -c "printf '%s' '{\"tool_input\":{\"command\":\"merge-lock.sh tui\"}}' | bash '${HOOK}'"
  [ "${status}" -eq 2 ]
}

@test "the hook blocks the extensionless spelling of tui" {
  # ~/.local/bin/merge-lock is the installed name and the one a human types,
  # so a regex anchored on the .sh suffix would miss it entirely.
  run bash -c "printf '%s' '{\"tool_input\":{\"command\":\"merge-lock tui\"}}' | bash '${HOOK}'"
  [ "${status}" -eq 2 ]
}

@test "the hook still blocks the extensionless spelling of auth" {
  run bash -c "printf '%s' '{\"tool_input\":{\"command\":\"merge-lock auth 42 ok\"}}' | bash '${HOOK}'"
  [ "${status}" -eq 2 ]
}

@test "the hook leaves read-only subcommands alone" {
  run bash -c "printf '%s' '{\"tool_input\":{\"command\":\"merge-lock list\"}}' | bash '${HOOK}'"
  [ "${status}" -eq 0 ]
}
