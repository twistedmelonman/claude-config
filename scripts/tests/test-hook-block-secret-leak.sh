#!/usr/bin/env bash
# Tests for hook-block-secret-leak.sh
#
# The hook compares against the LIVE environment, so these tests inject their
# own fake secrets and run the hook as a child with that environment. No real
# credential is ever placed in a test.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${SCRIPT_DIR}/hook-block-secret-leak.sh"

pass=0
fail=0

# A fake secret long enough to clear MIN_SECRET_LEN, shaped like a real PAT but
# not one. Its literal value is what prong 1 must match.
FAKE_TOKEN="ghp_TESTFAKE0000000000000000000000000000"
FAKE_OP="ops_TESTFAKE1111111111111111111111111111"

make_input() {
  jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'
}

# check <description> <expected_exit> <command-text>
check() {
  local desc="$1" want="$2" cmdtext="$3"
  local got
  make_input "${cmdtext}" \
    | env GH_TOKEN="${FAKE_TOKEN}" OP_SERVICE_ACCOUNT_TOKEN="${FAKE_OP}" \
      bash "${HOOK}" >/dev/null 2>&1
  got=$?
  if [[ "${got}" -eq "${want}" ]]; then
    printf 'PASS: %s\n' "${desc}"
    pass=$((pass + 1))
  else
    printf 'FAIL: %s (want exit %s, got %s)\n' "${desc}" "${want}" "${got}"
    fail=$((fail + 1))
  fi
}

echo "=== BLOCK: the two real-world leak shapes ==="

# Fixtures must reach the hook as LITERAL text -- if the test shell expanded
# them, the hook would receive an already-substituted string and every test
# would be meaningless. `D` holds a dollar sign so the fixtures can be written
# in double quotes (satisfying SC2016) while staying unexpanded.
D='$'

# The exact command that leaked GH_TOKEN on 2026-09-09.
check "the actual 2026-09-09 leak: ${D}{VAR:-fallback}" 2 \
  "echo \"GH_TOKEN set? ${D}{GH_TOKEN:+YES}${D}{GH_TOKEN:-NO}\""
check "${D}{VAR-fallback} (no colon)" 2 "echo \"${D}{GH_TOKEN-none}\""
check "${D}{VAR:=default}" 2 "echo \"${D}{GH_TOKEN:=x}\""
check "${D}{VAR:?message}" 2 "echo \"${D}{GH_TOKEN:?unset}\""
check 'literal secret value in command text' 2 \
  "curl -H \"Authorization: Bearer ${FAKE_TOKEN}\" https://api.github.com"
check "bare ${D}VAR in echo" 2 "echo ${D}GH_TOKEN"
check "bare ${D}{VAR} in printf" 2 "printf \"%s\" ${D}{GH_TOKEN}"
check 'a non-GH secret is caught too' 2 "echo \"${D}{OP_SERVICE_ACCOUNT_TOKEN:-no}\""

echo
echo "=== BLOCK: environment dumps ==="
check 'bare env' 2 'env'
check 'printenv' 2 'printenv'
check 'export -p' 2 'export -p'
check 'env piped to grep (values survive)' 2 'env | grep TOKEN'

echo
echo "=== ALLOW: the safe idioms the error message recommends ==="
# If these ever block, the hook has made itself unusable and the model will
# have no correct way to check whether a variable is set.
check "${D}{VAR:+SET} marker" 0 "echo \"${D}{GH_TOKEN:+SET}\""
check "${D}{#VAR} length" 0 "echo \"${D}{#GH_TOKEN}\""
check "[[ -n \"${D}VAR\" ]] test" 0 "if [[ -n \"${D}GH_TOKEN\" ]]; then echo yes; fi"
check 'env piped to cut -d= -f1 (names only)' 0 'env | cut -d= -f1'
check "env piped to awk print ${D}1 (names only)" 0 "env | awk -F= '{print ${D}1}'"
check 'compgen -v' 0 'compgen -v'

echo
echo "=== BLOCK: partial-value expansions ==="
# Every operator except `:+` / `+` reveals some of the value. `${VAR:0:4}` is
# the natural "just show me the prefix" move and must not be a loophole.
check "${D}{VAR:0:4} first four chars" 2 "echo \"${D}{GH_TOKEN:0:4}\""
check "${D}{VAR:1} all but the first" 2 "echo \"${D}{GH_TOKEN:1}\""
check "${D}{VAR#prefix} strip prefix" 2 "echo \"${D}{GH_TOKEN#ghp_}\""
check "${D}{VAR%suffix} strip suffix" 2 "echo \"${D}{GH_TOKEN%xyz}\""
check "${D}{VAR/a/b} search-replace" 2 "echo \"${D}{GH_TOKEN/ghp_/X}\""

echo
echo "=== BLOCK: printing one named variable ==="
# These take the NAME with no dollar sign, so the expansion patterns never
# see them.
check 'printenv NAME' 2 'printenv GH_TOKEN'
check 'declare -p NAME' 2 'declare -p GH_TOKEN'
check 'bare set (dumps vars and functions)' 2 'set'

echo
echo "=== ALLOW: ordinary commands ==="
check 'plain git status' 0 'git status'
check 'a command merely mentioning the word token' 0 'grep -rn token ./src'
check 'unrelated variable expansion' 0 "echo \"${D}{HOME}\""
check 'gh command that uses the token implicitly' 0 'gh pr list --limit 5'
check 'empty command' 0 ''

# PATH is >=16 chars and contains "PAT". If the name hints ever match it as a
# substring again, this blocks -- and a hook that blocks `echo "$PATH"` gets
# switched off within the hour.
check "echo ${D}PATH is not a secret" 0 "echo \"${D}PATH\""
check "echo ${D}PYTHONPATH" 0 "echo \"${D}PYTHONPATH\""
check 'KEYBOARD-style name is not a secret' 0 "echo \"${D}KEYBOARD_LAYOUT_NAME\""

# The documented workaround for the dead token this session. A future regex
# edit that breaks this would silently kill gh.
check 'env -u GH_TOKEN gh pr list (the workaround)' 0 'env -u GH_TOKEN gh pr list'
check 'set with arguments is not a dump' 0 'set -euo pipefail'
check 'set +x is not a dump' 0 'set +x'

# `set` and `env` appearing mid-command, not as the command.
check 'the word env inside a path' 0 'ls ~/Developer/dev-env'

echo
echo "=== ALLOW: fixtures must not false-positive ==="
# This is the failure mode of a token-pattern regex. These fake tokens are not
# in the environment, so exact-value matching cannot match them.
check 'a fake token in a test fixture' 0 \
  "assert_eq \"${D}(auth)\" \"ghp_FAKE000000000000000000000000000000\""
check 'a token-shaped string in a comment' 0 \
  'echo "# example: ghp_abcdefghijklmnopqrstuvwxyz0123456789"'

echo
echo "=== PINNED DECISION: \${VAR:-} blocks even without a printer ==="
# `[[ -n "${GH_TOKEN:-}" ]]` cannot actually print anything, and blocking a
# grep for the literal string ':-' is over-broad. Both are blocked anyway:
# _DANGEROUS_BRACE does not require a printing context.
#
# This is deliberate, and the conservative side of the tradeoff. The `:-`
# form is what leaked the token twice; `${VAR:+}` is a correct, equally short
# substitute for the set-check, and the block message names it. Recorded as a
# test so a future change to this behavior is a decision, not a regression.
check "safe-looking [[ -n \"${D}{VAR:-}\" ]] still blocks (by design)" 2 \
  "if [[ -n \"${D}{GH_TOKEN:-}\" ]]; then echo yes; fi"

# Searching for the literal text is NOT blocked: the pattern requires a real
# `${` expansion, so grepping the codebase for this idiom still works. That
# matters -- auditing for the dangerous form must not itself be forbidden.
check "grep for the literal string is allowed" 0 \
  "grep -rn 'GH_TOKEN:-' ."

echo
echo "=== control: the detector must actually be running ==="
# If the detector silently no-ops, every test above passes for the wrong
# reason. This asserts a known-bad input really does block.
control_out=$(make_input "echo \"${D}{GH_TOKEN:-LEAK}\"" \
  | env GH_TOKEN="${FAKE_TOKEN}" bash "${HOOK}" 2>&1 >/dev/null)
control_rc=$?
if [[ "${control_rc}" -eq 2 ]] && printf '%s' "${control_out}" | grep -q 'GH_TOKEN'; then
  printf 'PASS: control -- known-bad input blocks and names the variable\n'
  pass=$((pass + 1))
else
  printf 'FAIL: control -- known-bad input did not block (rc=%s)\n' "${control_rc}"
  fail=$((fail + 1))
fi

# The block message must never contain the secret itself.
if printf '%s' "${control_out}" | grep -qF "${FAKE_TOKEN}"; then
  printf 'FAIL: the block message leaked the secret value\n'
  fail=$((fail + 1))
else
  printf 'PASS: the block message does not contain the secret value\n'
  pass=$((pass + 1))
fi

echo
echo "======================================="
printf 'Results: %d passed, %d failed\n' "${pass}" "${fail}"
echo "======================================="
[[ "${fail}" -eq 0 ]]
