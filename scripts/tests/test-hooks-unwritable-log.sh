#!/usr/bin/env bash
# Tests that an unwritable audit log never changes a hook's VERDICT.
#
# Every blocking hook appends to ~/.claude/blocked-commands.log before its
# `exit 2`, and they all run under `set -euo pipefail`. An unguarded append
# fails when the log is unwritable, `set -e` exits on that line, and the
# intended `exit 2` is never reached -- the hook exits 1 instead. Both codes
# block, so the decision stays correct, but exit 2 is the documented
# PreToolUse "block and surface stderr" value that the suites assert on.
#
# One table over every affected hook rather than a copy of the same helper in
# each hook's own suite (claude-config#403). Three of these hooks have no
# standalone suite of their own, which is why the regression reached them.

set -euo pipefail
unset CDPATH

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0
fail=0

# Literals are assembled from fragments because the hooks under test scan the
# command line that builds them -- a bare merge endpoint or bypass flag in this
# file's own invocation gets blocked by the very hook it is testing (#405).
readonly NOVERIFY="--no""-verify"
readonly WT_ADD="worktree ""add"
readonly MERGE_EP="repos/o/r/pulls/1/""merge"
readonly ML_AUTH="merge-lock.sh ""authorize"

# make_input <json-key> <value>
make_input() {
  jq --null-input --arg k "${1}" --arg v "${2}" '{tool_input: {($k): $v}}'
}

# check <hook> <desc> <json-key> <value>
#
# Asserts exit 2 with a HOME that has no .claude/, so the log append fails.
# The fixture is built inside the function so make_input's exit status is
# checked rather than masked inside a command substitution (SC2312).
check() {
  local hook="${1}" desc="${2}" key="${3}" value="${4}"
  local input
  local tmphome actual=0

  input="$(make_input "${key}" "${value}")" || {
    echo "  FAIL: ${desc} (could not build fixture)"
    ((fail += 1))
    return
  }

  tmphome="$(mktemp -d)" # deliberately WITHOUT .claude/, as on first run
  printf '%s\n' "${input}" | HOME="${tmphome}" "${SCRIPTS_DIR}/${hook}" \
    >/dev/null 2>&1 || actual=$?
  rm -rf "${tmphome}"

  if [[ "${actual}" -eq 2 ]]; then
    echo "  PASS: ${desc}"
    ((pass += 1))
  else
    echo "  FAIL: ${desc} (exit ${actual}, want 2 -- a failed log write must not change the code)"
    ((fail += 1))
  fi
}

echo "=== unwritable-log verdict tests ==="

check hook-block-no-verify.sh \
  "no-verify: blocks with exit 2" \
  command "git commit ${NOVERIFY} -m x"

# hook-block-short-no-verify.sh is deliberately absent from this table. It is
# the one blocking hook that never writes to the audit log, so it has no
# redirect to guard and this assertion could not fail for it -- reverting every
# guard in the repo leaves it passing. A test that cannot fail is not coverage.
# (That it blocks without leaving an audit trail, unlike its five siblings, is
# a separate inconsistency; see #403.)

check hook-block-git-worktree.sh \
  "git-worktree: blocks with exit 2" \
  command "git ${WT_ADD} /tmp/evil"

check hook-block-api-merge.sh \
  "api-merge: blocks with exit 2" \
  command "gh api -X PUT ${MERGE_EP}"

check hook-block-merge-lock-authorize.sh \
  "merge-lock-authorize: blocks with exit 2" \
  command "${ML_AUTH} 123 ok"

check hook-block-merge-locks-write.sh \
  "merge-locks-write: blocks with exit 2" \
  file_path "/Users/x/.claude/merge-locks/pr-1.lock"

check hook-block-gate-dir-write.sh \
  "gate-dir-write: blocks with exit 2" \
  command "cp /tmp/x /Users/x/.claude/gate-review/approved/fake"

# EnterWorktree carries a `name`, not a command. An invalid slug reaches deny(),
# which writes to the log and then exits 2 -- same shape as the five above.
check hook-block-enter-worktree.sh \
  "enter-worktree: blocks with exit 2" \
  name "invalid name with spaces"

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
