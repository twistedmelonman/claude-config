#!/usr/bin/env bash
# Regression suite for the two Bash-path gate hooks:
#   hook-block-personify.sh    -- gates commit/PR text on an approved artifact
#   hook-block-gate-dir-write.sh -- keeps the approval dirs agent-unwritable
#
# Cases are base64-encoded so this file's own source carries no literal
# VCS-command text. A literal `git commit` here trips hook-block-main-commit.sh
# whenever the tool cwd sits in a repo on main, which makes the suite
# unrunnable from exactly the state it is most often run in.
#
# Promoted from dev-env's git-excluded scratch (claude-config#545, second item):
# a matcher with no committed coverage is how the bypass it now tests got in.

set -uo pipefail
unset CDPATH

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERSONIFY="${SCRIPTS}/hook-block-personify.sh"
DIRWRITE="${SCRIPTS}/hook-block-gate-dir-write.sh"

for h in "${PERSONIFY}" "${DIRWRITE}"; do
  [[ -x "${h}" ]] || {
    echo "missing or not executable: ${h}" >&2
    exit 1
  }
done

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Drive the hooks against a fixture dir, not the real one: the suite must not
# depend on what happens to be approved on this machine, and must never write
# into the dir it is testing the protection of.
export GATE_REVIEW_DIR="${TMP}/gate"
mkdir -p "${GATE_REVIEW_DIR}/pending" "${GATE_REVIEW_DIR}/approved"

APPROVED_TEXT="${TMP}/approved-body.txt"
UNAPPROVED_TEXT="${TMP}/unapproved-body.txt"
printf 'fix(gate): a body that was approved\n' >"${APPROVED_TEXT}"
printf 'fix(gate): a body nobody reviewed\n' >"${UNAPPROVED_TEXT}"
# Seed the approval directly. `gate-review open` needs a GUI and a human, so
# the suite writes the approved bytes itself -- this is the fixture, not a
# bypass of the real gate.
cp "${APPROVED_TEXT}" "${GATE_REVIEW_DIR}/approved/commit-1"

pass=0
fail=0

_case() {
  local hook="$1" desc="$2" b64="$3" want="$4" cmd got
  cmd="$(printf '%s' "${b64}" | base64 -d)"
  printf '{"tool_input":{"command":%s}}' "$(printf '%s' "${cmd}" | jq -Rs .)" |
    "${hook}" >/dev/null 2>&1
  got=$?
  if [[ "${got}" == "${want}" ]]; then
    echo "  PASS (${got}) ${desc}"
    pass=$((pass + 1))
  else
    echo "  FAIL (got ${got} want ${want}) ${desc}"
    fail=$((fail + 1))
  fi
}

_b64() { printf '%s' "$1" | base64; }

echo "=== personify: unverifiable text must BLOCK (exit 2) ==="
_case "${PERSONIFY}" "inline -m message" \
  "$(_b64 'git commit -m "x"')" 2
_case "${PERSONIFY}" "INLINE ASSIGNMENT BYPASS (the 2026-09-18 hole)" \
  "$(_b64 'PERSONIFY_OK=1 git commit -m "x"')" 2
_case "${PERSONIFY}" "env-wrapped assignment" \
  "$(_b64 'env PERSONIFY_OK=1 git commit -m x')" 2
_case "${PERSONIFY}" "after &&" \
  "$(_b64 'cd /tmp && git commit -m "x"')" 2
_case "${PERSONIFY}" "absolute path binary" \
  "$(_b64 '/usr/bin/git commit -m x')" 2
_case "${PERSONIFY}" "no message flag at all (editor mode, no TTY)" \
  "$(_b64 'git commit')" 2
_case "${PERSONIFY}" "amend --no-edit reuses text but names no file" \
  "$(_b64 'git commit --amend --no-edit')" 2
_case "${PERSONIFY}" "gh pr create with inline --body" \
  "$(_b64 'gh pr create --body "x"')" 2
_case "${PERSONIFY}" "gh issue comment with inline --body" \
  "$(_b64 'gh issue comment 5 --body "x"')" 2

echo "=== personify: -F path forms ==="
_case "${PERSONIFY}" "relative -F path (git and hook resolve it differently)" \
  "$(_b64 'git commit -F ./msg.txt')" 2
_case "${PERSONIFY}" "tilde -F path (unresolvable from the command string)" \
  "$(_b64 'git commit -F ~/msg.txt')" 2
# The `${MSG}` here is test data, not an expansion this script wants: the point
# is that the hook cannot resolve a variable-spelled path. Built from a literal
# `$` so shellcheck sees no unexpanded expression (SC2016), which disable
# directives are not permitted to silence.
_dollar=$(printf '\044')
_case "${PERSONIFY}" "variable -F path (unresolvable from the command string)" \
  "$(_b64 "git commit -F ${_dollar}{MSG}/x.txt")" 2
_case "${PERSONIFY}" "absolute -F path, text NOT approved" \
  "$(_b64 "git commit -F ${UNAPPROVED_TEXT}")" 2
_case "${PERSONIFY}" "absolute -F path, text APPROVED" \
  "$(_b64 "git commit -F ${APPROVED_TEXT}")" 0
_case "${PERSONIFY}" "--file= form, APPROVED" \
  "$(_b64 "git commit --file=${APPROVED_TEXT}")" 0
_case "${PERSONIFY}" "quoted absolute -F path, APPROVED" \
  "$(_b64 "git commit -F \"${APPROVED_TEXT}\"")" 0
_case "${PERSONIFY}" "commit from the approved dir itself, APPROVED" \
  "$(_b64 "git commit -F ${GATE_REVIEW_DIR}/approved/commit-1")" 0
_case "${PERSONIFY}" "gh pr create --body-file, APPROVED" \
  "$(_b64 "gh pr create --title t --body-file ${APPROVED_TEXT}")" 0
_case "${PERSONIFY}" "gh pr create --body-file, NOT approved" \
  "$(_b64 "gh pr create --title t --body-file ${UNAPPROVED_TEXT}")" 2

echo "=== personify: ungated surfaces must ALLOW (exit 0) ==="
_case "${PERSONIFY}" "status" "$(_b64 'git status')" 0
_case "${PERSONIFY}" "log" "$(_b64 'git log --oneline -1')" 0
_case "${PERSONIFY}" "gh pr view" "$(_b64 'gh pr view 12')" 0
_case "${PERSONIFY}" "gh pr edit --add-label (no body flag)" \
  "$(_b64 'gh pr edit 12 --add-label ready')" 0
_case "${PERSONIFY}" "gh pr edit --title only (titles stay ungated)" \
  "$(_b64 'gh pr edit 12 --title "a new title"')" 0
_case "${PERSONIFY}" "gh pr edit --body-file, NOT approved" \
  "$(_b64 "gh pr edit 12 --body-file ${UNAPPROVED_TEXT}")" 2

echo "=== personify: multiple gated commands on one line ==="
# Every extracted path must verify, or the line blocks. Checking only the
# first would let an unapproved second command ride along on the first's
# approval.
_case "${PERSONIFY}" "approved then unapproved" \
  "$(_b64 "git commit -F ${APPROVED_TEXT} && gh pr create --body-file ${UNAPPROVED_TEXT}")" 2
_case "${PERSONIFY}" "approved then approved" \
  "$(_b64 "git commit -F ${APPROVED_TEXT} && gh pr create --body-file ${APPROVED_TEXT}")" 0

echo "=== dir-write: writes into the lock dirs must BLOCK (exit 2) ==="
_case "${DIRWRITE}" "cp into merge-locks (the measured hole)" \
  "$(_b64 'cp /tmp/x /Users/andrewrich/.claude/merge-locks/fake')" 2
_case "${DIRWRITE}" "cp into gate-review/approved" \
  "$(_b64 'cp /tmp/x /Users/andrewrich/.claude/gate-review/approved/fake')" 2
_case "${DIRWRITE}" "redirect into approved" \
  "$(_b64 'echo text > /Users/andrewrich/.claude/gate-review/approved/fake')" 2
_case "${DIRWRITE}" "append-redirect into approved" \
  "$(_b64 'echo text >> /Users/andrewrich/.claude/gate-review/approved/fake')" 2
_case "${DIRWRITE}" "tee into approved" \
  "$(_b64 'echo text | tee /Users/andrewrich/.claude/gate-review/approved/fake')" 2
_case "${DIRWRITE}" "sed -i on an approval" \
  "$(_b64 'sed -i "" s/a/b/ /Users/andrewrich/.claude/gate-review/approved/commit-1')" 2
_case "${DIRWRITE}" "mv into approved" \
  "$(_b64 'mv /tmp/x /Users/andrewrich/.claude/gate-review/approved/fake')" 2
_case "${DIRWRITE}" "rm an approval" \
  "$(_b64 'rm /Users/andrewrich/.claude/gate-review/approved/commit-1')" 2
_case "${DIRWRITE}" "touch into approved" \
  "$(_b64 'touch /Users/andrewrich/.claude/gate-review/approved/fake')" 2
_case "${DIRWRITE}" "ln into approved" \
  "$(_b64 'ln -s /tmp/x /Users/andrewrich/.claude/gate-review/approved/fake')" 2
_case "${DIRWRITE}" "tilde-spelled path into merge-locks" \
  "$(_b64 'cp /tmp/x ~/.claude/merge-locks/fake')" 2
_case "${DIRWRITE}" "batch.txt is a gate file too" \
  "$(_b64 'echo "# STATUS: APPROVED" > /Users/andrewrich/.claude/gate-review/batch.txt')" 2

echo "=== dir-write: READS must ALLOW (exit 0) ==="
# The whole point of the gate is `git commit -F <approved file>`. If reading
# from the dir blocked, the approved bytes could never reach git and the gate
# would block the workflow it exists to permit.
_case "${DIRWRITE}" "commit -F from the approved dir" \
  "$(_b64 'git commit -F /Users/andrewrich/.claude/gate-review/approved/commit-1')" 0
_case "${DIRWRITE}" "cat an approval" \
  "$(_b64 'cat /Users/andrewrich/.claude/gate-review/approved/commit-1')" 0
_case "${DIRWRITE}" "ls the approved dir" \
  "$(_b64 'ls -l /Users/andrewrich/.claude/gate-review/approved')" 0
_case "${DIRWRITE}" "grep an approval" \
  "$(_b64 'grep -c . /Users/andrewrich/.claude/gate-review/approved/commit-1')" 0
_case "${DIRWRITE}" "gate-review stage writes via the tool, not a shell redirect" \
  "$(_b64 'gate-review.sh stage commit-1 /tmp/msg.txt')" 0
_case "${DIRWRITE}" "cp OUT of the approved dir" \
  "$(_b64 'cp /Users/andrewrich/.claude/gate-review/approved/commit-1 /tmp/x')" 0
_case "${DIRWRITE}" "unrelated cp" \
  "$(_b64 'cp /tmp/a /tmp/b')" 0
_case "${DIRWRITE}" "a path merely mentioning the name" \
  "$(_b64 'echo gate-review > /tmp/notes.txt')" 0

# The tool is named after the directory it guards. An earlier pattern matched
# the bare name and made `scripts/gate-review.sh` uneditable -- the hook locked
# out edits to itself. Only paths INSIDE the directories are approval state.
_case "${DIRWRITE}" "writing the gate script itself is not writing the gate dir" \
  "$(_b64 'sed -i "" s/a/b/ /Users/andrewrich/Developer/claude-config/scripts/gate-review.sh')" 0
_case "${DIRWRITE}" "redirect into a file named after the dir" \
  "$(_b64 'echo x > /tmp/gate-review.log')" 0
_case "${DIRWRITE}" "cp to a merge-locks-named file outside the dir" \
  "$(_b64 'cp /tmp/a /tmp/merge-locks.bak')" 0

echo "--- ${pass} passed, ${fail} failed"
[[ "${fail}" == "0" ]]
