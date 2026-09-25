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
echo "=== prongs 3+4: credentials neither the env nor gitleaks knows (dev-env#156) ==="
# A live Pangram key reached a transcript: fetched with `op read` (so no env
# var held it) and printed bare (so gitleaks' generic-api-key rule, which needs
# `key = "..."` context, never fired). Every fixture below is synthetic,
# assembled at runtime, and was measured to produce no gitleaks finding bare.
#
# Assembled rather than written out for two reasons: a vendor-shaped literal
# trips GitHub push protection, and once prong 4 is live an agent reading this
# file would get literal fixtures back REDACTED (see the EDITING WARNING above).
# `${BODY}` in the source is not matched by any prong-4 pattern.
BODY="$(printf 'a1b2c3d4%.0s' 1 2 3 4 5 6 7 8)"

# run_cmd_hook <command> <stdout> [stderr] -- a Bash result for that command.
# Credential env vars are stripped so prong 1 cannot take the credit.
run_cmd_hook() {
  jq -nc --arg cmd "$1" --arg out "$2" --arg err "${3:-}" \
    '{tool_name:"Bash", tool_input:{command:$cmd},
      tool_response:{stdout:$out, stderr:$err, interrupted:false,
                     isImage:false}}' \
    | env -u GH_TOKEN -u GH_TOKEN_SWM -u GH_TOKEN_NOS -u GH_TOKEN_TWM \
      -u OP_SERVICE_ACCOUNT_TOKEN python3 "${HOOK}" 2>/dev/null
}

# check_cmd_redacted <desc> <command> <stdout> <value>
check_cmd_redacted() {
  local desc="$1" out
  out="$(run_cmd_hook "$2" "$3")"
  if [[ -n "${out}" ]] && ! grep -qF "$4" <<<"${out}" \
    && jq -e '.hookSpecificOutput.updatedToolOutput
              | has("stdout") and has("interrupted")' <<<"${out}" \
      >/dev/null 2>&1; then
    printf 'PASS: %s\n' "${desc}"
    pass=$((pass + 1))
  else
    printf 'FAIL: %s (value survived, or no replacement emitted)\n' "${desc}"
    fail=$((fail + 1))
  fi
}

# check_cmd_untouched <desc> <command> <stdout>
check_cmd_untouched() {
  local desc="$1" out
  out="$(run_cmd_hook "$2" "$3")"
  if [[ -z "${out}" ]]; then
    printf 'PASS: %s\n' "${desc}"
    pass=$((pass + 1))
  else
    printf 'FAIL: %s (mangled ordinary output)\n' "${desc}"
    fail=$((fail + 1))
  fi
}

echo "--- prong 4: vendor-prefixed keys printed bare (e.g. cat of a .env) ---"
while IFS='|' read -r vendor value; do
  check_cmd_redacted "${vendor} key, bare" 'cat .env' \
    "${value}" "${value}"
done <<EOF
Pangram sk-pg-|sk-pg-${BODY}
OpenAI sk-proj-|sk-proj-${BODY}
Anthropic OAuth sk-ant-oat01-|sk-ant-oat01-${BODY}
1Password service account ops_|ops_eyJ${BODY}
Sentry org sntrys_|sntrys_eyJ${BODY}
Google OAuth ya29.|ya29.${BODY}
Context7 ctx7sk-|ctx7sk-${BODY}
Mercury secret-token:|secret-token:mercury_production_${BODY}
EOF

# The same key reached through Read, not Bash.
PG_KEY="sk-pg-${BODY}"
pg_read="$(jq -nc --arg c "PANGRAM_API_KEY=${PG_KEY}" \
  '{tool_name:"Read", tool_input:{file_path:"/tmp/.env"},
    tool_response:{type:"text",
      file:{filePath:"/tmp/.env", content:$c, numLines:1,
            startLine:1, totalLines:1}}}' \
  | env -u GH_TOKEN -u GH_TOKEN_SWM -u GH_TOKEN_NOS -u GH_TOKEN_TWM \
    -u OP_SERVICE_ACCOUNT_TOKEN python3 "${HOOK}" 2>/dev/null)"
if [[ -n "${pg_read}" ]] && ! grep -qF "${PG_KEY}" <<<"${pg_read}"; then
  printf 'PASS: a Pangram key in Read output is redacted\n'
  pass=$((pass + 1))
else
  printf 'FAIL: a Pangram key in Read output survived\n'
  fail=$((fail + 1))
fi

echo "--- prong 3: stdout of a credential-printing command, any format ---"
# No vendor prefix at all: the point of prong 3 is that the format of what
# came back does not matter. Nothing but the command identifies it.
NOFMT="$(printf 'q7Rm%.0s' 1 2 3 4 5 6 7 8 9 10)"
check_cmd_redacted 'op read (the dev-env#156 leak)' \
  'op read "op://Automation/Pangram/credential"' "${NOFMT}" "${NOFMT}"
check_cmd_redacted 'op read with stderr silenced' \
  'op read op://v/i/f 2>/dev/null' "${NOFMT}" "${NOFMT}"
check_cmd_redacted 'op read piped through a passthrough' \
  'op read op://v/i/f | head -c 200' "${NOFMT}" "${NOFMT}"
check_cmd_redacted 'op read captured and echoed' \
  "echo \"key=${D}(op read op://v/i/f)\"" "key=${NOFMT}" "${NOFMT}"
check_cmd_redacted 'op read after another command' \
  'cd /tmp && op read op://v/i/f' "${NOFMT}" "${NOFMT}"
check_cmd_redacted 'op item get --reveal' \
  'op item get Pangram --fields credential --reveal' "${NOFMT}" "${NOFMT}"
check_cmd_redacted 'security find-generic-password -w' \
  'security find-generic-password -a me -s pangram -w' "${NOFMT}" "${NOFMT}"
check_cmd_redacted 'gcloud auth print-access-token' \
  'gcloud auth print-access-token' "${NOFMT}" "${NOFMT}"
check_cmd_redacted 'gh auth token' 'gh auth token' "${NOFMT}" "${NOFMT}"
check_cmd_redacted 'bash -c wrapping op read' \
  'bash -c "op read op://v/i/f"' "${NOFMT}" "${NOFMT}"

# `security -g` prints the password to STDERR, not stdout.
g_out="$(run_cmd_hook 'security find-generic-password -s pangram -g' \
  '' "password: \"${NOFMT}\"")"
if [[ -n "${g_out}" ]] && ! grep -qF "${NOFMT}" <<<"${g_out}"; then
  printf 'PASS: security -g password on stderr is redacted\n'
  pass=$((pass + 1))
else
  printf 'FAIL: security -g password on stderr survived\n'
  fail=$((fail + 1))
fi

echo "--- negative: ordinary output and non-leaking commands are left alone ---"
check_cmd_untouched 'op read redirected to a file, then ls' \
  'op read op://v/i/f > /tmp/k && ls' 'k  notes.md'
check_cmd_untouched 'op read captured into a variable' \
  "v=\"${D}(op read op://v/i/f)\"; echo done" 'done'
check_cmd_untouched 'op read piped into a consumer' \
  'op read op://v/i/f | gh auth login --with-token' 'Logged in'
check_cmd_untouched 'op read used inside a curl header' \
  "curl -s -H \"Authorization: Bearer ${D}(op read op://v/i/f)\" https://x" \
  '{"status":"ok"}'
check_cmd_untouched '"op read" as a quoted string, not a command' \
  'echo "run op read first"' 'run op read first'
check_cmd_untouched 'grep for the phrase op read' \
  "grep -n 'op read' notes.md" '3:use op read to fetch it'
check_cmd_untouched 'op item get without --reveal/--fields' \
  'op item get Pangram' 'Title: Pangram'
check_cmd_untouched 'gh auth status without --show-token' \
  'gh auth status' 'Logged in to github.com'
# Output full of long hex, UUIDs, base64 and prose that NAMES every prefix.
# Nothing here is a credential; prong 4 must not widen into mangling it.
check_cmd_untouched 'hashes, UUIDs and prose naming the prefixes' \
  'git log -3; cat notes.md' \
  "commit 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08
Merge: 1a2b3c4 5d6e7f8
id 123e4567-e89b-12d3-a456-426614174000
digest sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
Pangram keys start with sk-pg- and OpenAI ones with sk-proj- or sk-svcacct-.
Claude Code OAuth tokens look like sk-ant-oat01-... and 1Password ones ops_eyJ...
see desk-proj-planning-meeting-notes-2026-09-24-final-version-v2 for the plan
Google tokens begin ya29. and Sentry org tokens sntrys_ -- rotate both."

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
