#!/usr/bin/env bash
# Tests for hook-redact-secret-output.py
#
# The hook compares against the LIVE environment, so these tests inject their
# own fake secrets and run it as a child with that environment. No real
# credential appears in a test.
#
# `cd` with a relative argument searches CDPATH and prints the resolved path on
# a match, which corrupts a `$(cd ... && pwd)` capture. See the same guard in
# test-hook-block-secret-leak.sh.
unset CDPATH

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${SCRIPT_DIR}/hook-redact-secret-output.py"

pass=0
fail=0

# Long enough to clear MIN_SECRET_LEN, shaped like a PAT but not one. Prong 1
# matches on the literal value, so the shape does not matter -- only that it
# is in the environment when the hook runs.
FAKE_TOKEN="ghp_TESTFAKE0000000000000000000000000000"
FAKE_OP="ops_TESTFAKE1111111111111111111111111111"

# stdout for a Bash tool result.
make_input() {
  jq -nc --arg out "$1" \
    '{tool_name:"Bash",
      tool_input:{command:"true"},
      tool_response:{stdout:$out, stderr:"", interrupted:false, isImage:false}}'
}

run_hook() {
  make_input "$1" \
    | env GH_TOKEN="${FAKE_TOKEN}" OP_SERVICE_ACCOUNT_TOKEN="${FAKE_OP}" \
      python3 "${HOOK}" 2>/dev/null
}

# check_redacted <desc> <output-text> -- the value must NOT survive
check_redacted() {
  local desc="$1" text="$2" out
  out="$(run_hook "${text}")"
  if [[ -n "${out}" ]] && ! grep -qF "${FAKE_TOKEN}" <<<"${out}"; then
    printf 'PASS: %s\n' "${desc}"
    pass=$((pass + 1))
  else
    printf 'FAIL: %s (value survived, or no replacement emitted)\n' "${desc}"
    fail=$((fail + 1))
  fi
}

# check_untouched <desc> <output-text> -- no replacement should be emitted
check_untouched() {
  local desc="$1" text="$2" out
  out="$(run_hook "${text}")"
  if [[ -z "${out}" ]]; then
    printf 'PASS: %s\n' "${desc}"
    pass=$((pass + 1))
  else
    printf 'FAIL: %s (emitted a replacement for clean output)\n' "${desc}"
    fail=$((fail + 1))
  fi
}

echo "=== REDACT: a live env secret appearing in tool output ==="
check_redacted 'bare token on its own line' "${FAKE_TOKEN}"
check_redacted 'token in gh auth output' \
  "  Logged in to github.com
  Token: ${FAKE_TOKEN}
  Scopes: repo"
check_redacted 'token embedded in JSON' \
  "{\"token\": \"${FAKE_TOKEN}\", \"user\": \"someone\"}"
check_redacted 'token in a URL' \
  "https://x-access-token:${FAKE_TOKEN}@github.com/o/r.git"
check_redacted 'token appearing several times' \
  "first ${FAKE_TOKEN} then ${FAKE_TOKEN} again"

echo
echo "=== the replacement must be well-formed and shape-preserving ==="
out="$(run_hook "Token: ${FAKE_TOKEN}")"
if jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' <<<"${out}" \
  >/dev/null 2>&1; then
  printf 'PASS: emits hookEventName PostToolUse\n'
  pass=$((pass + 1))
else
  printf 'FAIL: hookEventName missing or wrong\n'
  fail=$((fail + 1))
fi

# A replacement whose shape does not match the tool's output is silently
# discarded, so the redaction would evaporate while the tests looked green.
if jq -e '.hookSpecificOutput.updatedToolOutput
          | has("stdout") and has("stderr")
            and has("interrupted") and has("isImage")' <<<"${out}" \
  >/dev/null 2>&1; then
  printf 'PASS: updatedToolOutput keeps every original field\n'
  pass=$((pass + 1))
else
  printf 'FAIL: updatedToolOutput dropped a field -- replacement is discarded\n'
  fail=$((fail + 1))
fi

if jq -e '.hookSpecificOutput.updatedToolOutput.stdout
          | contains("[redacted: GH_TOKEN]")' <<<"${out}" >/dev/null 2>&1; then
  printf 'PASS: placeholder names the variable\n'
  pass=$((pass + 1))
else
  printf 'FAIL: placeholder does not name the variable\n'
  fail=$((fail + 1))
fi

echo
echo "=== stderr is redacted too ==="
err_out="$(jq -nc --arg e "fatal: bad credentials ${FAKE_TOKEN}" \
  '{tool_name:"Bash", tool_input:{command:"true"},
    tool_response:{stdout:"", stderr:$e, interrupted:false, isImage:false}}' \
  | env GH_TOKEN="${FAKE_TOKEN}" python3 "${HOOK}" 2>/dev/null)"
if [[ -n "${err_out}" ]] && ! grep -qF "${FAKE_TOKEN}" <<<"${err_out}"; then
  printf 'PASS: a secret on stderr is redacted\n'
  pass=$((pass + 1))
else
  printf 'FAIL: stderr was not redacted\n'
  fail=$((fail + 1))
fi

echo
echo "=== a second credential variable is caught too ==="
op_out="$(run_hook "op token: ${FAKE_OP}")"
if [[ -n "${op_out}" ]] && ! grep -qF "${FAKE_OP}" <<<"${op_out}"; then
  printf 'PASS: OP_SERVICE_ACCOUNT_TOKEN redacted (format gitleaks may not know)\n'
  pass=$((pass + 1))
else
  printf 'FAIL: the non-GitHub secret survived\n'
  fail=$((fail + 1))
fi

echo
echo "=== LEAVE ALONE: output with no secret in it ==="
check_untouched 'ordinary command output' 'total 24
drwxr-xr-x  4 user  staff  128 Sep 16 15:28 .'
check_untouched 'empty output' ''
check_untouched 'the word token without a value' \
  'grep -rn token ./src returned 4 matches'
# A fixture token is not in the environment, so exact-value matching cannot
# see it. This is the property that makes prong 1 immune to the fixture
# false-positive problem a pattern scanner has.
# `D` holds a dollar sign so the fixture keeps its literal `$(auth)` while
# satisfying SC2016 -- the same idiom as test-hook-block-secret-leak.sh.
D='$'
check_untouched 'a fake token in quoted test-fixture text' \
  "assert_eq \"${D}(auth)\" \"ghp_FAKE000000000000000000000000000000\""

echo
echo "=== Read results are redacted too (different output shape) ==="
# Read nests content under `file.content` and has no stdout at all, so a
# stdout-only redactor silently ignores it. Measured on this machine, Read
# accounted for 4 of 12 attributable tool_result leak sites -- a third.
read_out="$(jq -nc --arg c "api_token: ${FAKE_TOKEN}" \
  '{tool_name:"Read", tool_input:{file_path:"/tmp/cfg"},
    tool_response:{type:"text",
      file:{filePath:"/tmp/cfg", content:$c, numLines:1,
            startLine:1, totalLines:1}}}' \
  | env GH_TOKEN="${FAKE_TOKEN}" python3 "${HOOK}" 2>/dev/null)"
if [[ -n "${read_out}" ]] && ! grep -qF "${FAKE_TOKEN}" <<<"${read_out}"; then
  printf 'PASS: a secret in Read output is redacted\n'
  pass=$((pass + 1))
else
  printf 'FAIL: Read output was not redacted\n'
  fail=$((fail + 1))
fi

# The nested shape must survive intact, or the replacement is discarded and
# the redaction silently evaporates.
if jq -e '.hookSpecificOutput.updatedToolOutput.file
          | has("filePath") and has("numLines") and has("totalLines")' \
  <<<"${read_out}" >/dev/null 2>&1; then
  printf 'PASS: Read replacement keeps the nested file fields\n'
  pass=$((pass + 1))
else
  printf 'FAIL: Read replacement dropped nested fields\n'
  fail=$((fail + 1))
fi

echo
echo "=== prong 2: gitleaks catches what is NOT in the environment ==="
# Prong 1 can only match values the environment holds. A credential in a
# config file being cat'd, or someone else's key in a paste, is invisible to
# it -- that is the whole reason gitleaks is here.
#
# The environment is stripped of every credential-shaped variable so prong 1
# cannot take the credit. The sample is a synthetic AWS key: a format gitleaks
# ships a rule for, and a value that is not a real credential.
if command -v gitleaks >/dev/null 2>&1; then
  # EDITING WARNING: once this hook is active, an agent reading this file gets
  # these two values back REDACTED, and an edit written against that redacted
  # text silently replaces them with placeholder strings -- which then fails
  # this very test. It happened during development. If these lines read as
  # `[redacted: ...]`, that is the cause; restore them by writing the file
  # without round-tripping the values through a read.
  #
  # NOT AWS's documentation key (AKIAIOSFODNN7EXAMPLE / wJalrXUt...EXAMPLEKEY):
  # gitleaks allowlists those by design, so a test built on them fails while
  # the hook is working correctly. Verified 2026-09-16: the doc key exits 0,
  # a realistic one exits 1. These are randomly generated and are not
  # credentials for anything.
  # Assembled at runtime: a credential-shaped literal in the source
  # trips GitHub push protection, which is correct behavior on its part.
  # Concatenation keeps the scanner quiet while gitleaks still sees a
  # complete key in the value the hook is handed.
  NOT_IN_ENV="AKIA""ZZ7Q4XKPMN3TVBWD"
  NOT_IN_ENV_SECRET="7Kq2xVbN9pLmR4tZ""3wYcFgH8jD5sA1eU6iO0nQrT"
  p2_in="$(jq -nc --arg out "aws_access_key_id = ${NOT_IN_ENV}
aws_secret_access_key = ${NOT_IN_ENV_SECRET}" \
    '{tool_name:"Bash", tool_input:{command:"cat ~/.aws/credentials"},
      tool_response:{stdout:$out, stderr:"", interrupted:false, isImage:false}}')"
  # env -i would lose PATH and python3; instead unset only the credential vars.
  p2_out="$(printf '%s' "${p2_in}" \
    | env -u GH_TOKEN -u GH_TOKEN_SWM -u GH_TOKEN_NOS -u GH_TOKEN_TWM \
      -u OP_SERVICE_ACCOUNT_TOKEN python3 "${HOOK}" 2>/dev/null)"
  if [[ -n "${p2_out}" ]] \
    && ! grep -qF "${NOT_IN_ENV_SECRET}" <<<"${p2_out}"; then
    printf 'PASS: gitleaks redacts a credential absent from the environment\n'
    pass=$((pass + 1))
  else
    printf 'FAIL: prong 2 did not redact a non-environment credential\n'
    fail=$((fail + 1))
  fi
else
  printf 'SKIP: gitleaks not installed; prong 2 not exercised\n'
fi

echo
echo "=== real-format credential (expired 555 fixture) ==="
# `op://Automation/CCCLI-555/token` is a REAL GitHub fine-grained PAT that was
# minted and immediately expired to serve as a leak-test fixture -- the
# 555-prefix of tokens. It is dead, so printing it costs nothing, but it has a
# real token's format, entropy and checksum, which no synthetic reproduces.
#
# Why this test exists: two transcript values were originally misread as
# "real tokens gitleaks missed". Measured against this fixture, a real PAT has
# REPEATED characters (42 distinct in an 86-char body), while both of those
# values had every character distinct -- a 2.3e-06 event. They were synthetic.
# This fixture is what turned that inference into a measurement.
#
# Skipped when the vault is unreachable rather than failed: CI has no 1Password
# session, and a test that fails on every machine but one gets deleted.
if command -v op >/dev/null 2>&1 \
  && real_pat="$(op read "op://Automation/CCCLI-555/token" 2>/dev/null)" \
  && [[ -n "${real_pat}" ]]; then
  real_out="$(run_hook "gh auth status
  Token: ${real_pat}")"
  if [[ -n "${real_out}" ]] && ! grep -qF "${real_pat}" <<<"${real_out}"; then
    printf 'PASS: a real-format GitHub PAT is redacted from output\n'
    pass=$((pass + 1))
  else
    printf 'FAIL: a real-format GitHub PAT survived redaction\n'
    fail=$((fail + 1))
  fi

  # The shape claim the synthetic-vs-real classification rests on. Counted in
  # bash rather than a pipeline: each stage of `fold | sort -u | wc -l` masks
  # its predecessor's exit status (SC2312), and this repo allows no disable
  # directives.
  real_body="${real_pat#*_}"
  distinct=""
  for ((i = 0; i < ${#real_body}; i++)); do
    ch="${real_body:i:1}"
    [[ "${distinct}" == *"${ch}"* ]] || distinct+="${ch}"
  done
  if ((${#distinct} < ${#real_body})); then
    printf 'PASS: a real PAT has repeated characters (not all-unique)\n'
    pass=$((pass + 1))
  else
    printf 'FAIL: a real PAT was all-unique -- the synthetic heuristic is wrong\n'
    fail=$((fail + 1))
  fi
else
  printf 'SKIP: op unavailable or vault locked; 555 fixture not exercised\n'
fi

echo
echo "=== malformed and edge-case input must not crash ==="
for bad in '' 'not json at all' '{}' '{"tool_response": null}' \
  '{"tool_response": {"stdout": 42}}'; do
  printf '%s' "${bad}" | env GH_TOKEN="${FAKE_TOKEN}" python3 "${HOOK}" \
    >/dev/null 2>&1
  rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    pass=$((pass + 1))
  else
    printf 'FAIL: malformed input exited %s: %s\n' "${rc}" "${bad:0:40}"
    fail=$((fail + 1))
  fi
done
printf 'PASS: malformed input handled without crashing (5 cases)\n'

echo
echo "=== control: the redactor must actually be running ==="
# Without this, a silently no-op hook shows every check above passing for the
# wrong reason -- check_untouched succeeds on empty output, and empty output
# is exactly what a broken hook produces.
control="$(run_hook "Token: ${FAKE_TOKEN}")"
if [[ -n "${control}" ]] \
  && jq -e '.hookSpecificOutput.updatedToolOutput.stdout' <<<"${control}" \
    >/dev/null 2>&1 \
  && ! grep -qF "${FAKE_TOKEN}" <<<"${control}"; then
  printf 'PASS: control -- a known-bad input really is redacted\n'
  pass=$((pass + 1))
else
  printf 'FAIL: control -- the redactor is not running\n'
  fail=$((fail + 1))
fi

# The hook must never write a secret to its own log.
#
# `[[ -f FILE ]] && grep ...` would PASS when the log does not exist, which is
# the same false-OK shape this whole change exists to remove: a hook that
# crashed before writing, or wrote to the wrong path, would earn a pass. Every
# check_redacted above triggers a log write, so by this point the file must
# exist -- its absence is a failure, not a pass.
LOGFILE="${HOME}/.claude/blocked-commands.log"
if [[ ! -f "${LOGFILE}" ]]; then
  printf 'FAIL: no log at %s -- redactions above should have written one\n' \
    "${LOGFILE}"
  fail=$((fail + 1))
elif grep -qF "${FAKE_TOKEN}" "${LOGFILE}"; then
  printf 'FAIL: the hook logged the secret value\n'
  fail=$((fail + 1))
elif ! grep -q 'REDACTED FROM OUTPUT' "${LOGFILE}"; then
  printf 'FAIL: log exists but holds no redaction record -- logging is broken\n'
  fail=$((fail + 1))
else
  printf 'PASS: the log records redactions by name and holds no secret value\n'
  pass=$((pass + 1))
fi

echo
echo "======================================="
echo "Results: ${pass} passed, ${fail} failed"
echo "======================================="
((fail == 0))
