#!/usr/bin/env bash
# Tests for run-review.sh
# Run from any directory: bash ~/.claude/hooks/tests/run-review-test.sh
#
# Tests cover:
# The assertion total in the summary line is computed from PASS+FAIL, not
# hardcoded: the literal drifted twice, and a `grep -c assert_` proxy is
# wrong too (it counts the two helper definitions as call sites).
#
#   1. set -e propagation: transient Claude CLI failure must produce log output beyond bare exit_code
#   2. Chunked review log: reviewer output must appear in REVIEW_LOG when chunked path runs
#   3. Chunked review with 0/N files reviewed is fail-closed (issue #200); 3b: partial skip still passes
#   4. Stderr hint: chunked review failure (blocking verdict) must emit workaround hint
#   5. review.timeout git config is honoured
#   6. make_mock_claude must handle double-quotes in output without script syntax errors
#   7. REVIEW_LOG env var must override the hardcoded production log path in run-review.sh
#   8. Empty reviewer output (exit 0, no stdout) must not block the commit
#   9. Chunked-mode timeout verdicts are skips, not warnings; all-timeout batch is fail-closed (#200)
#   10. sync/* branches skip review regardless of diff size
#   11. "VERDICT: Revise" is treated as a synonym for FAIL
#   12/13. adversarial-reviewer only blocks on SEVERITY: BLOCKING, matching code-reviewer (issue #199)
#   14. Empty/template-only commit message does not abort the script under pipefail (issue #148)
#   15. Codebase mode: stderr noise must not corrupt VERDICT parsing (issue #89)
#   16. EXIT trap cleanup includes DIFF_TMPFILE (issue #90) — static guard
#   17. Permission-only diff is still skipped after the SIGPIPE-safe rewrite (issues #166, #171)
#   18. "VERDICT: Revise" is treated as blocking FAIL in chunked mode (issue #173)
#   19. "VERDICT: Revise" is treated as blocking FAIL in full-diff mode (issue #173)
#   20. "VERDICT: Revise" is treated as blocking FAIL in codebase mode (issue #173); also
#       covers issue #159 (model logging in full-diff/codebase modes)
#   21. review.model git config overrides the default model passed to the CLI (issue #160)
#   22. CODE_REVIEWER_AGENT default resolves to the installed agent ID (issue #209)
#   23. review.adversarialModel overrides adversarial-reviewer's model independently
#       of review.model / REVIEW_MODE (issue #235)
#   30-33. Reviewer disagreements: every disagreement logs locally and NOTHING is
#       ever filed as a GitHub issue (claude-config#418, which removed the
#       arbiter-FAIL filing that #332 had narrowed); verbatim reviewer output
#       stays in the local log; an unwritable log path never fails the run
#   34-36. --no-file / REVIEW_NO_FILE=1 dry-run prints non-blocking findings
#       instead of filing them, and the flag is opt-in (#415)
#   37-39. Severity gates tolerate markdown emphasis, case, and spacing, so a
#       bolded or lowercased BLOCKING no longer slips the gate; a WARNING-only
#       FAIL still does not block
#   40-47. Structured output is the decision channel (claude-config#443): a
#       schema-constrained boolean decides, with #442's prose matcher as the
#       fallback when the reviewer did not answer one. Test 42 is the fail-open
#       guard — an absent structured_output must NOT read as "no blocking
#       issues"; 43/44 reject null and the string "false"; 45 keeps a timeout
#       non-blocking (#172); 46 degrades to prose for an older CLI; 47 keeps
#       the transport marker out of human-facing output
#   48. The real CLI's tool-call response shape: .result is the SERIALIZED
#       object with no prose in it, so the VERDICT block is rendered out of
#       .structured_output. Caught by a live dry-run, not by any mock — every
#       mock was green while the gate would have hard-blocked every commit

set -euo pipefail

# Resolve script directory without cd to avoid CDPATH side effects.
# When CDPATH is set, 'cd relative/dir' prints the resolved path to stdout,
# polluting $(cd dir && pwd) with a doubled path. Use parameter expansion
# on an absolute form of BASH_SOURCE[0] to avoid any external commands.
_src="${BASH_SOURCE[0]}"
[[ "${_src}" == /* ]] || _src="${PWD}/${_src}"
SCRIPT_DIR="${_src%/*}"
unset _src
SUBJECT="${SCRIPT_DIR}/../run-review.sh"
# Each test sets its own REVIEW_LOG to a temp path and passes it as an env var
# to run-review.sh, preventing test runs from clobbering the production log at
# ~/.claude/last-review-result.log (Warning 2 fix: run-review.sh now honours
# REVIEW_LOG env var override).

PASS=0
FAIL=0

# --- Test helpers ---
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${desc}"
    ((PASS += 1))
  else
    echo "  FAIL: ${desc}"
    echo "        expected to find: ${needle}"
    echo "        in log (first 10 lines):"
    echo "${haystack}" | head -10 | sed 's/^/          /'
    ((FAIL += 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "${haystack}" | grep -qF -- "${needle}"; then
    echo "  FAIL: ${desc}"
    echo "        expected NOT to find: ${needle}"
    echo "        in log (first 10 lines):"
    echo "${haystack}" | head -10 | sed 's/^/          /'
    ((FAIL += 1))
  else
    echo "  PASS: ${desc}"
    ((PASS += 1))
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "  PASS: ${desc}"
    ((PASS += 1))
  else
    echo "  FAIL: ${desc}"
    echo "        expected: ${expected}"
    echo "        actual:   ${actual}"
    ((FAIL += 1))
  fi
}

# --- Test repo setup ---
# Creates a real git repo with a staged file so git diff --cached works
TMPDIR_TEST="$(mktemp -d)"
REPO_DIR="${TMPDIR_TEST}/testrepo"

setup_repo() {
  rm -rf "${REPO_DIR}"
  mkdir -p "${REPO_DIR}"
  cd "${REPO_DIR}"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  # Create and commit a base file
  echo "#!/usr/bin/env bash" >foo.sh
  git add foo.sh
  git commit -q -m "base" --no-verify
}

# Stage a change to foo.sh and return to original dir
stage_small_change() {
  cd "${REPO_DIR}"
  echo "echo hello" >>foo.sh
  git add foo.sh
  cd - >/dev/null
}

# Stage changes to multiple files (for chunked review path)
stage_large_change() {
  cd "${REPO_DIR}"
  for i in $(seq 1 5); do
    printf '#!/usr/bin/env bash\n# File %d\n' "${i}" >"file${i}.sh"
    for j in $(seq 1 8); do
      echo "echo line_${j}_of_file_${i}" >>"file${i}.sh"
    done
    git add "file${i}.sh"
  done
  cd - >/dev/null
}

# Create mock claude binary with given exit code and stdout output.
# Output is written to a separate file and cat'd by the mock to avoid
# heredoc expansion issues when output contains double-quotes or other
# special characters that would break an inline printf '%s\n' "${output}".
#
# The mock short-circuits on --version so run-review.sh's CLI preflight
# passes quickly (preflight calls `timeout 5 ${CLI} --version` and only
# fails the whole script on exit 124). Without this fast-path, a mock
# configured to exit nonzero would still pass preflight (preflight tolerates
# non-124 exits) but a mock that sleeps — like Test 5's inline sleep mock —
# would hit the 5s timeout and kill the whole test run.
# run-review.sh invokes the CLI with --output-format json --json-schema
# (claude-config#443), so the mock must speak that envelope: the reviewer prose
# in `.result`, the schema-constrained decision in `.structured_output`.
#
# The envelope is DERIVED from the text argument rather than demanded from each
# of the ~40 call sites: the text goes into .result verbatim, and .blocking is
# inferred from whether that text declares a BLOCKING severity — i.e. the mock
# reproduces the same decision the old prose path produced. Existing call sites
# therefore keep working unchanged while now exercising the structured channel.
#
# $4 (optional) overrides the derived structured_output, so a test can pin an
# exact shape: a raw JSON object, or the literal "none" to emit an envelope
# with NO structured_output key at all (the fail-open case), or "raw" to emit
# the text with no JSON envelope whatsoever (an older CLI).
# Build the --output-format json envelope the real CLI returns under
# --json-schema (claude-config#443).
#
# MEASURED, and it is the non-obvious part: under --json-schema the model is
# constrained to a TOOL CALL, so it emits no prose. `.result` holds the
# SERIALIZED structured object, and run-review.sh renders the
# VERDICT/ISSUE/SEVERITY/LOCATION/DETAILS block back out of
# `.structured_output`. A mock that puts prose in `.result` and an unrelated
# object in `.structured_output` does NOT resemble the CLI, and would let a
# rendering bug pass. So: derive the structured object FROM the prose, then
# serialize that same object into `.result`.
#
# $1 prose, $2 override ("" = derive, "none" = omit structured_output,
# anything else = a raw JSON object), $3 destination file.
_mock_write_envelope() {
  local _text="$1" _override="$2" _dest="$3" _so
  printf '%s\n' "${_text}" >"${_dest}.txt"

  case "${_override}" in
    "")
      # Derive: split the prose into findings so the rendered output round-trips
      # back to (materially) the text the call site asked for.
      # Strip markdown emphasis first, exactly as has_blocking_severity() does.
      # Without this a call site written as "**SEVERITY:** BLOCKING" would
      # derive blocking=false, and the structured false would then correctly
      # override its own prose — a mock artifact, not a production behavior.
      _so=$(printf '%s\n' "${_text}" | tr -d '*`_' | jq -Rn '
        [inputs] as $lines
        | ($lines | map(select(test("^VERDICT:";"i"))) | .[0] // "VERDICT: PASS") as $v
        | (if ($v | ascii_upcase | test("VERDICT:[[:space:]]*PASS")) then "PASS" else "FAIL" end) as $verdict
        | ($lines | map(select(test("^ISSUE:";"i"))    | sub("^[Ii][Ss][Ss][Uu][Ee]:[[:space:]]*";""))) as $issues
        | ($lines | map(select(test("^SEVERITY:";"i")) | sub("^[Ss][Ee][Vv][Ee][Rr][Ii][Tt][Yy]:[[:space:]]*";""))) as $sevs
        | ($lines | map(select(test("^LOCATION:";"i")) | sub("^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*";""))) as $locs
        | {verdict: $verdict,
           blocking: ($sevs | map(ascii_upcase) | any(. == "BLOCKING")),
           findings: [ range(0; ($issues | length))
                       | { severity: ($sevs[.] // "WARNING"),
                           location: ($locs[.] // "unspecified"),
                           issue:    ($issues[.]) } ]}')
      ;;
    none) _so="" ;;
    *) _so="${_override}" ;;
  esac

  if [[ -n "${_so}" ]]; then
    # .result carries the prose the call site asked for, and structured_output
    # carries the boolean derived from it. This is the prose-bearing response
    # shape: the reviewer answered the schema AND explained itself, so the
    # prose sub-languages the schema does not model (NON_BLOCKING_ISSUE /
    # TITLE / END_ISSUE) survive. The serialized-object shape the real CLI
    # returns for a pure tool call is covered separately by
    # make_mock_claude_structured_only above.
    jq -n --rawfile r "${_dest}.txt" --argjson so "${_so}" \
      '{type:"result",subtype:"success",is_error:false,result:$r,structured_output:$so}' >"${_dest}"
  else
    # No structured_output: the fail-open case, and an older CLI. Here .result
    # genuinely is prose, because no tool call constrained the model.
    jq -n --rawfile r "${_dest}.txt" \
      '{type:"result",subtype:"success",is_error:false,result:$r}' >"${_dest}"
  fi
}

make_mock_claude() {
  local mock_dir="$1" exit_code="$2" output="$3" structured="${4:-}"
  mkdir -p "${mock_dir}"

  if [[ "${structured}" == "raw" ]]; then
    # No envelope at all: exercises the degrade-to-prose path (older CLI).
    printf '%s\n' "${output}" >"${mock_dir}/envelope.json"
  elif [[ -z "${output}" && -z "${structured}" ]]; then
    # Empty output stays empty — that is what a timeout or a crashed CLI
    # actually produces, and run-review.sh normalises it into a synthetic
    # transient verdict. Wrapping it in an envelope would misrepresent it.
    : >"${mock_dir}/envelope.json"
  else
    _mock_write_envelope "${output}" "${structured}" "${mock_dir}/envelope.json"
  fi

  cat >"${mock_dir}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
cat "${mock_dir}/envelope.json"
exit ${exit_code}
EOF
  chmod +x "${mock_dir}/claude"
}

# Inline trap: restore review.maxLines if set, then remove temp dir.
# REPO_DIR is a script-level variable set above; TMPDIR_TEST likewise.
trap 'cd "${REPO_DIR}" 2>/dev/null && git config --unset review.maxLines 2>/dev/null || true; rm -rf "${TMPDIR_TEST}"' EXIT

# =========================================================
# TEST 1: set -e propagation at call site (single-pass path)
#
# When Claude CLI exits non-zero, run-review.sh should NOT exit silently.
# The REVIEW_LOG must contain the agent error description, not just exit_code.
# (Currently fails because set -e kills the script at CODE_REVIEWER_OUTPUT=$(invoke_agent ...)
#  before the log-writing section at lines 608+ is reached.)
# =========================================================
echo ""
echo "=== Test 1: set -e protection — Claude CLI transient failure (single-pass) ==="

setup_repo
stage_small_change

MOCK1_DIR="${TMPDIR_TEST}/mock1"
make_mock_claude "${MOCK1_DIR}" 1 ""

TEST1_LOG="${TMPDIR_TEST}/test1-review.log"
rm -f "${TEST1_LOG}"

cd "${REPO_DIR}"
REVIEW_LOG="${TEST1_LOG}" CLAUDE_CLI="${MOCK1_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

log_content="$(cat "${TEST1_LOG}" 2>/dev/null || echo "")"

assert_contains \
  "log contains agent error info (not just bare exit_code: 1)" \
  "agent error" \
  "${log_content}"

# Transient agent failure (both reviewers error) must not block the commit.
# Both produce VERDICT: FAIL (agent error: 1) with no SEVERITY: BLOCKING —
# they should be treated as non-blocking warnings, not genuine rejections.
exit_t1=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST1_LOG}" CLAUDE_CLI="${MOCK1_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t1=$?
cd - >/dev/null

assert_eq \
  "transient agent failure (both reviewers error) does not block commit" \
  "0" \
  "${exit_t1}"

# =========================================================
# TEST 2: Chunked review path writes output to REVIEW_LOG
#
# When diff > maxLines, perform_chunked_review() runs. Its results (which file
# was reviewed, verdict per file, summary) must appear in REVIEW_LOG.
# (Currently only diff_lines: N (chunked review) + exit_code: N are written.)
# =========================================================
echo ""
echo "=== Test 2: Chunked review log completeness ==="

setup_repo
stage_large_change

MOCK2_DIR="${TMPDIR_TEST}/mock2"
make_mock_claude "${MOCK2_DIR}" 0 "VERDICT: PASS

No blocking issues found."

TEST2_LOG="${TMPDIR_TEST}/test2-review.log"
rm -f "${TEST2_LOG}"

cd "${REPO_DIR}"
git config review.maxLines 10
REVIEW_LOG="${TEST2_LOG}" CLAUDE_CLI="${MOCK2_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
git config --unset review.maxLines 2>/dev/null || true
cd - >/dev/null

log_content="$(cat "${TEST2_LOG}" 2>/dev/null || echo "")"

assert_contains \
  "log contains CHUNKED REVIEW section header" \
  "CHUNKED REVIEW" \
  "${log_content}"

assert_contains \
  "log contains file review count (Reviewed: N/N files)" \
  "Reviewed:" \
  "${log_content}"

# =========================================================
# TEST 3: Agent error on EVERY file in chunked mode blocks the commit (fail-closed)
#
# When Claude CLI fails for a file chunk, that file is SKIPPED (logged as
# skipped due to agent error) rather than counting as a blocking issue in
# its own right. But if EVERY file in the batch is skipped this way,
# reviewed_files ends up at 0 with file_count > 0 — a review that reviewed
# nothing provides no safety signal and must not be reported as a pass.
# Issue #200: previously this fell through to "Chunked review passed (0
# files reviewed)" and returned 0 (fail-open). Now it returns 1.
# =========================================================
echo ""
echo "=== Test 3: Agent error on every file in chunked mode blocks (fail-closed, exit 1) ==="

setup_repo
stage_large_change

MOCK3_DIR="${TMPDIR_TEST}/mock3"
make_mock_claude "${MOCK3_DIR}" 1 "" # Claude exits non-zero (transient failure) on every file

TEST3_LOG="${TMPDIR_TEST}/test3-review.log"
rm -f "${TEST3_LOG}"

exit_code_t3=0
cd "${REPO_DIR}"
git config review.maxLines 10
REVIEW_LOG="${TEST3_LOG}" CLAUDE_CLI="${MOCK3_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_code_t3=$?
git config --unset review.maxLines 2>/dev/null || true
cd - >/dev/null

log_content="$(cat "${TEST3_LOG}" 2>/dev/null || echo "")"

assert_eq \
  "chunked review with 0/N files reviewed blocks commit (exit 1) - issue #200" \
  "1" \
  "${exit_code_t3}"

assert_contains \
  "log notes files were skipped due to agent error" \
  "skipped" \
  "${log_content}"

assert_contains \
  "log shows 0 files were reviewed" \
  "Reviewed: 0/" \
  "${log_content}"

# =========================================================
# TEST 3b: Partial skip (some files reviewed) is still non-fatal
#
# Regression guard for #200: the fail-closed behavior above must trigger
# ONLY when reviewed_files is exactly 0. If at least one file was actually
# reviewed (and passed), a mix of skipped + reviewed files must still allow
# the commit through — the fix should not regress the original "one bad
# file doesn't kill the whole batch" behavior.
# =========================================================
echo ""
echo "=== Test 3b: Partial skip (some files reviewed) does not block commit ==="

setup_repo
stage_large_change

MOCK3B_DIR="${TMPDIR_TEST}/mock3b"
mkdir -p "${MOCK3B_DIR}"
# Mock inspects stdin (the per-file review prompt, which embeds the diff)
# to distinguish file1.sh (reviewed, PASS) from all other files (agent error).
cat >"${MOCK3B_DIR}/claude" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
stdin_content="$(cat)"
if [[ "${stdin_content}" == *"file1.sh"* ]]; then
  echo "VERDICT: PASS"
  echo ""
  echo "No blocking issues found."
  exit 0
fi
exit 1
MOCKEOF
chmod +x "${MOCK3B_DIR}/claude"

TEST3B_LOG="${TMPDIR_TEST}/test3b-review.log"
rm -f "${TEST3B_LOG}"

exit_code_t3b=0
cd "${REPO_DIR}"
git config review.maxLines 10
REVIEW_LOG="${TEST3B_LOG}" CLAUDE_CLI="${MOCK3B_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_code_t3b=$?
git config --unset review.maxLines 2>/dev/null || true
cd - >/dev/null

log_content_t3b="$(cat "${TEST3B_LOG}" 2>/dev/null || echo "")"

assert_eq \
  "partial skip (1 reviewed, 4 skipped) still passes (exit 0)" \
  "0" \
  "${exit_code_t3b}"

assert_contains \
  "log shows at least 1 file was reviewed" \
  "Reviewed: 1/" \
  "${log_content_t3b}"

# =========================================================
# TEST 4: Stderr hint on chunked review with genuine blocking failure
#
# When chunked review finds a genuine BLOCKING verdict, stderr should include
# the review.maxLines workaround hint (to guide users who think it's a false positive).
# =========================================================
echo ""
echo "=== Test 4: Stderr hint on chunked review blocking failure ==="

setup_repo
stage_large_change

MOCK4_DIR="${TMPDIR_TEST}/mock4"
make_mock_claude "${MOCK4_DIR}" 0 "VERDICT: FAIL

ISSUE: Hardcoded secret
SEVERITY: BLOCKING
LOCATION: file1.sh:3
DETAILS: Remove the hardcoded credential."

TEST4_LOG="${TMPDIR_TEST}/test4-review.log"
rm -f "${TEST4_LOG}"

stderr_out=""
cd "${REPO_DIR}"
git config review.maxLines 10
stderr_out="$(REVIEW_LOG="${TEST4_LOG}" CLAUDE_CLI="${MOCK4_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>&1 || true)"
git config --unset review.maxLines 2>/dev/null || true
cd - >/dev/null

assert_contains \
  "stderr includes review.maxLines workaround hint" \
  "review.maxLines" \
  "${stderr_out}"

# =========================================================
# TEST 5: review.timeout git config is read by the script
#
# The error message "git config review.timeout 300" is shown on timeout,
# but TIMEOUT_SECONDS was previously hardcoded to 120 and never read
# from git config. Verify that setting review.timeout actually changes
# the timeout value passed to `timeout`.
# =========================================================
echo ""
echo "=== Test 5: review.timeout git config is honoured ==="

setup_repo
stage_small_change

# Create a mock that sleeps longer than a 1s timeout then outputs PASS.
# If review.timeout=1 is honoured, the agent will be killed and we get a timeout verdict.
# If review.timeout is ignored (TIMEOUT_SECONDS=120 hardcoded), the mock would finish in ~2s.
MOCK5_DIR="${TMPDIR_TEST}/mock5"
mkdir -p "${MOCK5_DIR}"
# Fast-path --version so the CLI preflight (timeout 5) doesn't kill us before
# the real test scenario. The real invocation (without --version) still sleeps.
cat >"${MOCK5_DIR}/claude" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
sleep 5
echo "VERDICT: PASS"
echo "No blocking issues found."
MOCKEOF
chmod +x "${MOCK5_DIR}/claude"

TEST5_LOG="${TMPDIR_TEST}/test5-review.log"
rm -f "${TEST5_LOG}"

cd "${REPO_DIR}"
git config review.timeout 1
REVIEW_LOG="${TEST5_LOG}" CLAUDE_CLI="${MOCK5_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
git config --unset review.timeout 2>/dev/null || true
cd - >/dev/null

log_content5="$(cat "${TEST5_LOG}" 2>/dev/null || echo "")"

# If the config is honoured, the 1s timeout fires and the log records the timeout
assert_contains \
  "review.timeout=1 causes timeout to fire (config is read)" \
  "timeout" \
  "${log_content5}"

# =========================================================
# TEST 6: make_mock_claude handles double-quotes in output
#
# make_mock_claude uses an unquoted heredoc (<<EOF), so ${output} is expanded
# at generation time. If output contains double-quotes, the generated
# printf '%s\n' "${output}" line gets unbalanced quotes and the mock script
# fails with a syntax error.
# Fix: write output to a separate file and have the mock cat it.
# =========================================================
echo ""
echo "=== Test 6: make_mock_claude handles double-quotes in output ==="

MOCK6_DIR="${TMPDIR_TEST}/mock6"
# Single-quoted here to prevent shell expansion of the double-quotes
make_mock_claude "${MOCK6_DIR}" 0 'VERDICT: FAIL (agent error: "timeout")'

# The mock now emits an --output-format json envelope (claude-config#443), so
# the prose lives in .result with its quotes JSON-escaped. The property under
# test is unchanged — embedded double-quotes must survive the mock intact — but
# it is now asserted after unwrapping, which additionally proves the envelope
# is well-formed JSON rather than a broken concatenation.
mock6_out="$("${MOCK6_DIR}/claude" 2>/dev/null | jq -r '.result' || true)"

assert_contains \
  "mock correctly outputs string with embedded double-quotes" \
  'VERDICT: FAIL (agent error: "timeout")' \
  "${mock6_out}"

# =========================================================
# TEST 7: REVIEW_LOG env var overrides production log path
#
# run-review.sh hardcodes REVIEW_LOG="${HOME}/.claude/last-review-result.log".
# Tests should be able to pass REVIEW_LOG as an env var to redirect log output
# to a temporary path, preventing test runs from clobbering the production log.
# =========================================================
echo ""
echo "=== Test 7: REVIEW_LOG env var overrides production log path ==="

setup_repo
stage_small_change

MOCK7_DIR="${TMPDIR_TEST}/mock7"
make_mock_claude "${MOCK7_DIR}" 0 "VERDICT: PASS

No blocking issues found."

ISOLATED_LOG="${TMPDIR_TEST}/isolated-review.log"
rm -f "${ISOLATED_LOG}"

cd "${REPO_DIR}"
REVIEW_LOG="${ISOLATED_LOG}" CLAUDE_CLI="${MOCK7_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

isolated_log_content="$(cat "${ISOLATED_LOG}" 2>/dev/null || echo "")"
assert_contains \
  "isolated log is written when REVIEW_LOG env var is set" \
  "exit_code:" \
  "${isolated_log_content}"

# =========================================================
# TEST 8: Empty reviewer output (exit 0) does not block commit
#
# If invoke_agent exits 0 but produces no stdout, CODE_REVIEWER_OUTPUT="".
# Both PASS and FAIL greps fail, falling to "Could not parse verdict" -> exit 1.
# Fix: add empty-output guard after || true:
#   [[ -n "${CODE_REVIEWER_OUTPUT}" ]] || CODE_REVIEWER_OUTPUT="VERDICT: FAIL (agent error: ...)"
# This synthesises a transient-error verdict that the existing non-blocking check
# handles correctly, resulting in exit 0.
# =========================================================
echo ""
echo "=== Test 8: empty reviewer output (exit 0) does not block commit ==="

setup_repo
stage_small_change

MOCK8_DIR="${TMPDIR_TEST}/mock8"
mkdir -p "${MOCK8_DIR}"
cat >"${MOCK8_DIR}/claude" <<'MOCKEOF'
#!/usr/bin/env bash
# Fast-path --version so CLI preflight passes (see make_mock_claude).
if [[ "$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
# Exits successfully but produces no output (simulates a silent agent failure)
exit 0
MOCKEOF
chmod +x "${MOCK8_DIR}/claude"

TEST8_LOG="${TMPDIR_TEST}/test8-review.log"
exit_t8=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST8_LOG}" CLAUDE_CLI="${MOCK8_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t8=$?
cd - >/dev/null

assert_eq \
  "empty reviewer output (exit 0) does not block commit" \
  "0" \
  "${exit_t8}"

# =========================================================
# TEST 9: Chunked-mode timeout verdicts are counted as skips, not warnings —
# and an all-timeout batch is fail-closed (issue #200)
#
# invoke_agent emits two distinct synthetic verdicts on transient failure:
#   - "VERDICT: FAIL (timeout)"       — exit 124 from `timeout` command
#   - "VERDICT: FAIL (agent error: N)" — any other non-zero exit
# The parallel aggregate loop greps for "VERDICT: FAIL (" so both are
# classified as skips (non-fatal per-file — they don't count toward
# blocking_count). Regression test: previously the grep was "VERDICT: FAIL
# (agent error", which missed the timeout case and miscounted timeouts as
# warnings. Caught by Seer on PR #128; see issue #129.
#
# Since every file in this batch times out, reviewed_files ends up at 0 —
# per issue #200 this must now block the commit (exit 1), not pass silently.
# =========================================================
echo ""
echo "=== Test 9: chunked-mode timeout verdicts classified as skips ==="

setup_repo
stage_large_change

# Mock emits a timeout-style synthetic verdict (matches what invoke_agent
# produces on real timeout) instead of actual sleep — faster, deterministic.
MOCK9_DIR="${TMPDIR_TEST}/mock9"
make_mock_claude "${MOCK9_DIR}" 0 "VERDICT: FAIL (timeout)"

TEST9_LOG="${TMPDIR_TEST}/test9-review.log"
rm -f "${TEST9_LOG}"

exit_t9=0
cd "${REPO_DIR}"
git config review.maxLines 10
REVIEW_LOG="${TEST9_LOG}" CLAUDE_CLI="${MOCK9_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t9=$?
git config --unset review.maxLines 2>/dev/null || true
cd - >/dev/null

log_content9="$(cat "${TEST9_LOG}" 2>/dev/null || echo "")"

assert_eq \
  "chunked all-timeout (0/N reviewed) blocks commit (exit 1) - issue #200" \
  "1" \
  "${exit_t9}"

assert_contains \
  "log notes files were skipped (not counted as warnings)" \
  "skipped" \
  "${log_content9}"

# =========================================================
# TEST 10: sync/* branches skip review regardless of diff size
#
# Sync commits aggregate content already reviewed in the source repo.
# Running the size cap against them produces false blocks, so `sync/*`
# branches must exit 0 without invoking the reviewer.
# =========================================================
echo ""
echo "=== Test 10: sync/* branch skips review even when diff > skipThreshold ==="

setup_repo
cd "${REPO_DIR}"
git checkout -q -b "sync/2026-04-23-test"
# Stage a diff well above the default 2500-line skipThreshold so the
# test would hit the "BLOCKING: Diff too large" path if the sync-skip
# logic regressed.
for i in $(seq 1 3000); do echo "line_${i}_content" >>bigfile.sh; done
git add bigfile.sh
cd - >/dev/null

MOCK10_DIR="${TMPDIR_TEST}/mock10"
# Mock should never be invoked — if run-review.sh calls it, the sync skip
# broke and the test's "skipped: sync branch" assertion will also fail.
make_mock_claude "${MOCK10_DIR}" 1 "MOCK SHOULD NOT RUN"

TEST10_LOG="${TMPDIR_TEST}/test10-review.log"
rm -f "${TEST10_LOG}"

exit_t10=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST10_LOG}" CLAUDE_CLI="${MOCK10_DIR}/claude" \
  bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t10=$?
cd - >/dev/null

assert_eq \
  "sync branch exits 0 (review skipped)" \
  "0" \
  "${exit_t10}"

log_content10="$(cat "${TEST10_LOG}" 2>/dev/null || echo "")"

assert_contains \
  "log notes sync-branch skip reason" \
  "skipped: sync branch" \
  "${log_content10}"

# =========================================================
# TEST 11: "VERDICT: Revise" is treated as FAIL (blocking)
#
# Reviewers sometimes emit "VERDICT: Revise" instead of "VERDICT: FAIL".
# The script must treat Revise as a synonym for FAIL: when combined with
# SEVERITY: BLOCKING, it should block the commit (exit 1).
# =========================================================
echo ""
echo "=== Test 11: VERDICT: Revise treated as blocking FAIL ==="

setup_repo
stage_small_change

MOCK11_DIR="${TMPDIR_TEST}/mock11"
make_mock_claude "${MOCK11_DIR}" 0 "VERDICT: Revise

ISSUE: Hardcoded secret
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Remove the hardcoded credential."

TEST11_LOG="${TMPDIR_TEST}/test11-review.log"
rm -f "${TEST11_LOG}"

exit_t11=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST11_LOG}" CLAUDE_CLI="${MOCK11_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t11=$?
cd - >/dev/null

assert_eq \
  "VERDICT: Revise with BLOCKING severity blocks commit (exit 1)" \
  "1" \
  "${exit_t11}"

log_content11="$(cat "${TEST11_LOG}" 2>/dev/null || echo "")"

assert_contains \
  "log records FAIL verdict (Revise normalized to FAIL)" \
  "FAIL" \
  "${log_content11}"

# Mock that returns different output depending on which agent is invoked.
# The single-pass path calls: --agent "<agent_name>" ... so $2 is the agent
# name. Used to test the code-reviewer / adversarial-reviewer asymmetry
# fixed in issue #199.
# Per-agent variant of make_mock_claude. Same --output-format json envelope
# (claude-config#443) and the same derive-from-prose rule, applied to each of
# the two reviewers independently so existing call sites keep working.
#
# $4/$5 optionally override the code-reviewer / adversarial structured_output:
# a raw JSON object, or "none" for an envelope with NO structured_output key.
# Build a mock emitting the REAL CLI's pure-tool-call shape: `.result` is the
# SERIALIZED structured object, carrying no prose at all, so run-review.sh must
# RENDER the VERDICT/ISSUE/SEVERITY block out of `.structured_output`.
#
# This is the shape measured against the live CLI (see Test 48). It matters
# because the renderer is skipped entirely when `.result` already contains a
# VERDICT line, so a prose-bearing mock silently routes around it — which is
# how the FIX_NOW exclusion went unpinned: the assertion existed, the code was
# correct, and no mock ever reached the code being asserted about.
#
# $2/$3 are the structured objects for code-reviewer / adversarial-reviewer.
make_mock_claude_structured_only() {
  local mock_dir="$1" cr_structured="$2" ar_structured="$3"
  mkdir -p "${mock_dir}"
  jq -n --argjson so "${cr_structured}" \
    '{type:"result",subtype:"success",is_error:false,stop_reason:"tool_use",result:($so|tojson),structured_output:$so}' \
    >"${mock_dir}/cr_output.json"
  jq -n --argjson so "${ar_structured}" \
    '{type:"result",subtype:"success",is_error:false,stop_reason:"tool_use",result:($so|tojson),structured_output:$so}' \
    >"${mock_dir}/ar_output.json"
  cat >"${mock_dir}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
if [[ "\$2" == *adversarial* ]]; then
  cat "${mock_dir}/ar_output.json"
else
  cat "${mock_dir}/cr_output.json"
fi
exit 0
EOF
  chmod +x "${mock_dir}/claude"
}

# Mock emitting an envelope whose .structured_output.blocking is NOT a boolean
# and whose .result is narration rather than a VERDICT block -- the shape that
# hard-blocked a clean PASS in smartwatermelon/claude-config#450. Distinct from
# make_mock_claude_structured_only, which serializes .result from the structured
# object and so always carries a "verdict" string in the prose.
make_mock_claude_nonboolean_blocking() {
  local mock_dir="$1" cr_structured="$2" cr_prose="$3" ar_structured="$4"
  mkdir -p "${mock_dir}"
  jq -n --argjson so "${cr_structured}" --arg prose "${cr_prose}" \
    '{type:"result",subtype:"success",is_error:false,stop_reason:"tool_use",result:$prose,structured_output:$so}' \
    >"${mock_dir}/cr_output.json"
  jq -n --argjson so "${ar_structured}" \
    '{type:"result",subtype:"success",is_error:false,stop_reason:"tool_use",result:($so|tojson),structured_output:$so}' \
    >"${mock_dir}/ar_output.json"
  cat >"${mock_dir}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
if [[ "\$2" == *adversarial* ]]; then
  cat "${mock_dir}/ar_output.json"
else
  cat "${mock_dir}/cr_output.json"
fi
exit 0
EOF
  chmod +x "${mock_dir}/claude"
}

make_mock_claude_by_agent() {
  local mock_dir="$1" cr_output="$2" ar_output="$3"
  local cr_structured="${4:-}" ar_structured="${5:-}"
  mkdir -p "${mock_dir}"
  _mock_write_envelope "${cr_output}" "${cr_structured}" "${mock_dir}/cr_output.json"
  _mock_write_envelope "${ar_output}" "${ar_structured}" "${mock_dir}/ar_output.json"

  cat >"${mock_dir}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
if [[ "\$2" == *adversarial* ]]; then
  cat "${mock_dir}/ar_output.json"
else
  cat "${mock_dir}/cr_output.json"
fi
exit 0
EOF
  chmod +x "${mock_dir}/claude"
}

# =========================================================
# TEST 12: adversarial-reviewer WARNING-only FAIL is non-blocking (issue #199)
#
# Before the fix, adversarial-reviewer blocked on ANY non-transient FAIL
# verdict regardless of severity, while code-reviewer only blocked on
# SEVERITY: BLOCKING. This asymmetry meant a warnings-only adversarial FAIL
# rejected commits that code-reviewer's own rule would have allowed through.
# Fix: gate adversarial the same way — only SEVERITY: BLOCKING blocks.
# =========================================================
echo ""
echo "=== Test 12: adversarial-reviewer WARNING-only FAIL is non-blocking ==="

setup_repo
stage_small_change

MOCK12_DIR="${TMPDIR_TEST}/mock12"
make_mock_claude_by_agent "${MOCK12_DIR}" \
  "VERDICT: PASS

No blocking issues found." \
  "VERDICT: FAIL

ISSUE: Unpin needs rationale
SEVERITY: WARNING
LOCATION: settings.json:1
DETAILS: Document why the pin was removed."

TEST12_LOG="${TMPDIR_TEST}/test12-review.log"
rm -f "${TEST12_LOG}"

exit_t12=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST12_LOG}" CLAUDE_CLI="${MOCK12_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t12=$?
cd - >/dev/null

assert_eq \
  "adversarial WARNING-only FAIL does not block commit (exit 0) - issue #199" \
  "0" \
  "${exit_t12}"

# =========================================================
# TEST 13: adversarial-reviewer BLOCKING FAIL still blocks (issue #199)
#
# The symmetry fix must not make adversarial-reviewer toothless — a genuine
# SEVERITY: BLOCKING verdict from adversarial-reviewer must still reject
# the commit, exactly like code-reviewer's own BLOCKING gate.
# =========================================================
echo ""
echo "=== Test 13: adversarial-reviewer BLOCKING FAIL still blocks commit ==="

setup_repo
stage_small_change

MOCK13_DIR="${TMPDIR_TEST}/mock13"
make_mock_claude_by_agent "${MOCK13_DIR}" \
  "VERDICT: PASS

No blocking issues found." \
  "VERDICT: FAIL

ISSUE: Hardcoded credential
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Remove the hardcoded credential."

TEST13_LOG="${TMPDIR_TEST}/test13-review.log"
rm -f "${TEST13_LOG}"

exit_t13=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST13_LOG}" CLAUDE_CLI="${MOCK13_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t13=$?
cd - >/dev/null

assert_eq \
  "adversarial BLOCKING FAIL still blocks commit (exit 1) - issue #199" \
  "1" \
  "${exit_t13}"

# =========================================================
# TEST 14: Empty/template-only commit message does not crash the script
# (issue #148)
#
# _read_commit_message's `grep -v '^#' ... | awk ...` pipeline exits 1 (no
# output) when the source file contains only comment lines. Under
# `set -euo pipefail`, without a `|| true` guard on the assignment, this
# would abort the whole script. Exercised via --message-file (the highest-
# priority source, checked unconditionally regardless of REVIEW_MODE).
# =========================================================
echo ""
echo "=== Test 14: template-only commit message does not crash the script ==="

setup_repo
stage_small_change

TEMPLATE_MSG_FILE="${TMPDIR_TEST}/template-only-msg.txt"
printf '# Please enter the commit message\n# Lines starting with # are ignored\n' >"${TEMPLATE_MSG_FILE}"

MOCK14_DIR="${TMPDIR_TEST}/mock14"
make_mock_claude "${MOCK14_DIR}" 0 "VERDICT: PASS

No blocking issues found."

TEST14_LOG="${TMPDIR_TEST}/test14-review.log"
rm -f "${TEST14_LOG}"

exit_t14=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST14_LOG}" CLAUDE_CLI="${MOCK14_DIR}/claude" \
  bash "${SUBJECT}" "--message-file=${TEMPLATE_MSG_FILE}" < <(git diff --cached || true) 2>/dev/null || exit_t14=$?
cd - >/dev/null

log_content14="$(cat "${TEST14_LOG}" 2>/dev/null || echo "")"

assert_eq \
  "template-only commit message does not abort the script (exit 0)" \
  "0" \
  "${exit_t14}"

assert_contains \
  "script ran to completion (exit_code recorded in log)" \
  "exit_code:" \
  "${log_content14}"

# =========================================================
# TEST 15: Codebase mode - stderr noise does not corrupt VERDICT parsing
# (issue #89)
#
# CODEBASE_OUTPUT previously captured stdout+stderr together via 2>&1, so
# any stderr noise (CLI upgrade notices, deprecation warnings) could land
# in the text that `grep -q "VERDICT:"` parses. Fix: stderr is now routed
# to its own temp file, separate from CODEBASE_OUTPUT. Regression test:
# a mock that emits noise on stderr AND a clean PASS verdict on stdout
# must still parse as PASS (exit 0), not be corrupted by the noise.
# =========================================================
echo ""
echo "=== Test 15: codebase mode - stderr noise does not corrupt VERDICT parsing ==="

setup_repo
stage_small_change
cd "${REPO_DIR}"
git add foo.sh
git commit -q -m "stage a change" --no-verify
cd - >/dev/null

MOCK15_DIR="${TMPDIR_TEST}/mock15"
mkdir -p "${MOCK15_DIR}"
cat >"${MOCK15_DIR}/claude" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
# Simulate CLI noise (upgrade notice, deprecation warning) on stderr,
# interleaved with a clean VERDICT on stdout.
echo "warning: a new version of the CLI is available" >&2
echo "VERDICT: PASS"
echo ""
echo "No blocking issues found."
echo "deprecation notice: some flag will be removed" >&2
MOCKEOF
chmod +x "${MOCK15_DIR}/claude"

TEST15_LOG="${TMPDIR_TEST}/test15-review.log"
rm -f "${TEST15_LOG}"

exit_t15=0
cd "${REPO_DIR}"
git diff main~1 main | REVIEW_LOG="${TEST15_LOG}" CLAUDE_CLI="${MOCK15_DIR}/claude" \
  bash "${SUBJECT}" --mode=codebase 2>/dev/null || exit_t15=$?
cd - >/dev/null

log_content15="$(cat "${TEST15_LOG}" 2>/dev/null || echo "")"

assert_eq \
  "codebase mode PASS verdict is not corrupted by stderr noise (exit 0)" \
  "0" \
  "${exit_t15}"

assert_contains \
  "log records codebase PASS verdict" \
  "codebase:" \
  "${log_content15}"

# =========================================================
# TEST 16: EXIT trap cleans up DIFF_TMPFILE and _codebase_err (issue #90)
# — static guard
#
# Codebase mode writes the diff to a mktemp'd DIFF_TMPFILE so the agent can
# re-Read it, and (per #89) captures stderr in a separate mktemp'd
# _codebase_err. If the script is killed before their explicit `rm -f`
# cleanup lines run, both leak in $TMPDIR. This is only observable via
# SIGTERM/SIGKILL timing, which isn't practical to assert deterministically
# in this harness — instead this is a static regression guard: both must be
# listed in the EXIT trap's cleanup alongside the other known temp
# artifacts. (Caught by adversarial-reviewer during local review: the first
# pass of the #89 fix added _codebase_err's mktemp/rm but missed the trap.)
# =========================================================
echo ""
echo "=== Test 16: EXIT trap includes DIFF_TMPFILE and _codebase_err cleanup ==="

trap_line="$(grep -m1 "^trap '_ec=\$?;" "${SUBJECT}")"

assert_contains \
  "EXIT trap cleanup references DIFF_TMPFILE" \
  "DIFF_TMPFILE" \
  "${trap_line}"

assert_contains \
  "EXIT trap cleanup references _codebase_err" \
  "_codebase_err" \
  "${trap_line}"

# =========================================================
# TEST 17: Permission-only diff is still correctly skipped (issues #166, #171)
#
# The empty-diff / no-code-changes check was rewritten from
# `echo "${DIFF}" | grep -qE ...` to a here-string form to eliminate a
# SIGPIPE race on large diffs (grep exiting before echo finishes writing
# could make the pipeline's exit status echo's 141 instead of grep's real
# result under pipefail). Regression test: the intended behavior — skipping
# review when the diff contains no `+`/`-` code-content lines (e.g. a pure
# mode/permission change) — must still work after the rewrite.
# =========================================================
echo ""
echo "=== Test 17: permission-only diff is skipped (no code changes) ==="

setup_repo
cd "${REPO_DIR}"
chmod +x foo.sh
git add foo.sh
cd - >/dev/null

MOCK17_DIR="${TMPDIR_TEST}/mock17"
# Mock should never be invoked — if run-review.sh calls it, the empty-diff
# skip broke and the exit-code / log assertions below will also fail.
make_mock_claude "${MOCK17_DIR}" 1 "MOCK SHOULD NOT RUN"

TEST17_LOG="${TMPDIR_TEST}/test17-review.log"
rm -f "${TEST17_LOG}"

exit_t17=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST17_LOG}" CLAUDE_CLI="${MOCK17_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t17=$?
cd - >/dev/null

assert_eq \
  "permission-only diff exits 0 (review skipped, agent never invoked)" \
  "0" \
  "${exit_t17}"

log_content17="$(cat "${TEST17_LOG}" 2>/dev/null || echo "")"

assert_contains \
  "log notes permission/metadata-only skip reason" \
  "skipped: permission/metadata only" \
  "${log_content17}"

# =========================================================
# TEST 18: "VERDICT: Revise" is treated as blocking FAIL in chunked mode
# (issue #173)
#
# Test 11 covers the single-pass (small diff, no --mode) path. This mirrors
# Test 3/Test 4's chunked-mode setup (stage_large_change + review.maxLines=10
# to force chunking) with a mock that returns VERDICT: Revise + SEVERITY:
# BLOCKING for every file. The chunked aggregate loop must normalize Revise
# to FAIL and block the commit (exit 1), matching the single-pass behavior.
# =========================================================
echo ""
echo "=== Test 18: VERDICT: Revise treated as blocking FAIL (chunked mode) ==="

setup_repo
stage_large_change

MOCK18_DIR="${TMPDIR_TEST}/mock18"
make_mock_claude "${MOCK18_DIR}" 0 "VERDICT: Revise

ISSUE: Hardcoded secret
SEVERITY: BLOCKING
LOCATION: file1.sh:3
DETAILS: Remove the hardcoded credential."

TEST18_LOG="${TMPDIR_TEST}/test18-review.log"
rm -f "${TEST18_LOG}"

exit_t18=0
cd "${REPO_DIR}"
git config review.maxLines 10
REVIEW_LOG="${TEST18_LOG}" CLAUDE_CLI="${MOCK18_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t18=$?
git config --unset review.maxLines 2>/dev/null || true
cd - >/dev/null

assert_eq \
  "chunked-mode VERDICT: Revise with BLOCKING severity blocks commit (exit 1)" \
  "1" \
  "${exit_t18}"

log_content18="$(cat "${TEST18_LOG}" 2>/dev/null || echo "")"

assert_contains \
  "chunked-mode log records blocking issue count (Revise normalized to FAIL/blocking)" \
  "Blocking: 5" \
  "${log_content18}"

# =========================================================
# TEST 19: "VERDICT: Revise" is treated as blocking FAIL in full-diff mode
# (issue #173); also exercises model logging (issue #159)
#
# Mirrors Test 15's invocation pattern (commit a change, then pipe
# `git diff main~1 main` in with --mode=full-diff) with a mock that returns
# VERDICT: Revise + SEVERITY: BLOCKING. The full-diff path must normalize
# Revise to FAIL and block (exit 1). Also asserts the "model:" log line
# introduced for issue #159 appears, since full-diff mode exits internally
# before the previously-dead model logging at the end of the script.
# =========================================================
echo ""
echo "=== Test 19: VERDICT: Revise treated as blocking FAIL (full-diff mode) ==="

setup_repo
stage_small_change
cd "${REPO_DIR}"
git add foo.sh
git commit -q -m "stage a change" --no-verify
cd - >/dev/null

MOCK19_DIR="${TMPDIR_TEST}/mock19"
make_mock_claude "${MOCK19_DIR}" 0 "VERDICT: Revise

ISSUE: Cross-file inconsistency
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Fix the cross-file mismatch."

TEST19_LOG="${TMPDIR_TEST}/test19-review.log"
rm -f "${TEST19_LOG}"

exit_t19=0
cd "${REPO_DIR}"
git diff main~1 main | REVIEW_LOG="${TEST19_LOG}" CLAUDE_CLI="${MOCK19_DIR}/claude" \
  bash "${SUBJECT}" --mode=full-diff 2>/dev/null || exit_t19=$?
cd - >/dev/null

assert_eq \
  "full-diff-mode VERDICT: Revise with BLOCKING severity blocks commit (exit 1)" \
  "1" \
  "${exit_t19}"

log_content19="$(cat "${TEST19_LOG}" 2>/dev/null || echo "")"

assert_contains \
  "full-diff-mode log records FAIL (blocking) verdict (Revise normalized to FAIL)" \
  "full-diff: FAIL (blocking)" \
  "${log_content19}"

assert_contains \
  "full-diff-mode log records resolved model (issue #159)" \
  "model:" \
  "${log_content19}"

# =========================================================
# TEST 20: "VERDICT: Revise" is treated as blocking FAIL in codebase mode
# (issue #173); also exercises model logging (issue #159)
#
# Mirrors Test 15's invocation pattern with --mode=codebase and a mock that
# returns VERDICT: Revise + SEVERITY: BLOCKING. The codebase path must
# normalize Revise to FAIL and block (exit 1), and the "model:" log line
# (issue #159) must appear since codebase mode also exits internally.
# =========================================================
echo ""
echo "=== Test 20: VERDICT: Revise treated as blocking FAIL (codebase mode) ==="

setup_repo
stage_small_change
cd "${REPO_DIR}"
git add foo.sh
git commit -q -m "stage a change" --no-verify
cd - >/dev/null

MOCK20_DIR="${TMPDIR_TEST}/mock20"
make_mock_claude "${MOCK20_DIR}" 0 "VERDICT: Revise

ISSUE: Field contract violation
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Fix the renamed field reference."

TEST20_LOG="${TMPDIR_TEST}/test20-review.log"
rm -f "${TEST20_LOG}"

exit_t20=0
cd "${REPO_DIR}"
git diff main~1 main | REVIEW_LOG="${TEST20_LOG}" CLAUDE_CLI="${MOCK20_DIR}/claude" \
  bash "${SUBJECT}" --mode=codebase 2>/dev/null || exit_t20=$?
cd - >/dev/null

assert_eq \
  "codebase-mode VERDICT: Revise with BLOCKING severity blocks commit (exit 1)" \
  "1" \
  "${exit_t20}"

log_content20="$(cat "${TEST20_LOG}" 2>/dev/null || echo "")"

assert_contains \
  "codebase-mode log records FAIL (blocking) verdict (Revise normalized to FAIL)" \
  "codebase: FAIL (blocking)" \
  "${log_content20}"

assert_contains \
  "codebase-mode log records resolved model (issue #159)" \
  "model:" \
  "${log_content20}"

# =========================================================
# TEST 21: review.model git config overrides the default model (issue #160)
#
# run-review.sh reads review.model via git config and passes it through
# MODEL_ARGS=(--model "${REVIEW_MODEL}") to the CLI invocation. There was
# previously no test exercising this override path. This mock records its
# full invocation argv (mirroring how make_mock_claude_by_agent inspects
# $2 for the agent name) so the test can assert that --model plus the
# configured value actually reached the CLI's argv.
# =========================================================
echo ""
echo "=== Test 21: review.model git config overrides default model ==="

setup_repo
stage_small_change

MOCK21_DIR="${TMPDIR_TEST}/mock21"
mkdir -p "${MOCK21_DIR}"
MOCK21_ARGS_FILE="${MOCK21_DIR}/invocation-args.txt"
rm -f "${MOCK21_ARGS_FILE}"
cat >"${MOCK21_DIR}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
printf '%s\n' "\$*" >>"${MOCK21_ARGS_FILE}"
echo "VERDICT: PASS"
echo ""
echo "No blocking issues found."
exit 0
EOF
chmod +x "${MOCK21_DIR}/claude"

TEST21_LOG="${TMPDIR_TEST}/test21-review.log"
rm -f "${TEST21_LOG}"

cd "${REPO_DIR}"
git config review.model "some-custom-model-id"
REVIEW_LOG="${TEST21_LOG}" CLAUDE_CLI="${MOCK21_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
git config --unset review.model 2>/dev/null || true
cd - >/dev/null

invocation_args="$(cat "${MOCK21_ARGS_FILE}" 2>/dev/null || echo "")"

assert_contains \
  "custom review.model value is passed through to the CLI invocation (issue #160)" \
  "--model some-custom-model-id" \
  "${invocation_args}"

# =========================================================
# TEST 22: CODE_REVIEWER_AGENT default resolves to the actually-installed
# fully-qualified agent name (issue #209, and its regression in #212)
#
# The real installed agent ID doubles the plugin name — "comprehensive-review:
# comprehensive-review-code-reviewer" — per the comprehensive-review plugin's
# agents/code-reviewer.md frontmatter. #212 mistakenly "fixed" the default to
# the bare-looking "comprehensive-review:code-reviewer", which does not match
# any installed agent, so run-review.sh's code-reviewer pass silently errored
# on every commit again. Assert the --agent value that actually reaches the
# CLI invocation matches the real installed agent ID (verify with
# `claude --agent bogus -p`, which lists installed agents in its error).
# =========================================================
echo ""
echo "=== Test 22: CODE_REVIEWER_AGENT default matches installed agent ID (issue #209) ==="

setup_repo
stage_small_change

MOCK22_DIR="${TMPDIR_TEST}/mock22"
mkdir -p "${MOCK22_DIR}"
MOCK22_ARGS_FILE="${MOCK22_DIR}/invocation-args.txt"
rm -f "${MOCK22_ARGS_FILE}"
cat >"${MOCK22_DIR}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
printf '%s\n' "\$*" >>"${MOCK22_ARGS_FILE}"
echo "VERDICT: PASS"
echo ""
echo "No blocking issues found."
exit 0
EOF
chmod +x "${MOCK22_DIR}/claude"

TEST22_LOG="${TMPDIR_TEST}/test22-review.log"
rm -f "${TEST22_LOG}"

cd "${REPO_DIR}"
git config --unset review.codeReviewerAgent 2>/dev/null || true
REVIEW_LOG="${TEST22_LOG}" CLAUDE_CLI="${MOCK22_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

invocation_args22="$(cat "${MOCK22_ARGS_FILE}" 2>/dev/null || echo "")"

assert_contains \
  "default CODE_REVIEWER_AGENT resolves to installed agent ID (issue #209)" \
  "--agent comprehensive-review:comprehensive-review-code-reviewer " \
  "${invocation_args22}"

# =========================================================
# TEST 23: review.adversarialModel git config overrides the adversarial-
# reviewer model independently of review.model / REVIEW_MODE (issue #235)
#
# adversarial-reviewer previously rode the same REVIEW_MODEL as code-reviewer
# via a shared MODEL_ARGS global (Haiku on commit-mode, the highest-frequency
# path). run-review.sh now resolves a separate ADVERSARIAL_MODEL_ARGS,
# defaulting to claude-sonnet-4-6 regardless of mode, overridable via
# `git config review.adversarialModel`. invoke_agent() takes model args as a
# per-call parameter instead of reading a shared global, so this test asserts
# (a) code-reviewer still gets the mode-based default (Haiku, unaffected by
# the adversarialModel override) and (b) adversarial-reviewer gets the
# configured override, in the same commit-mode run.
# =========================================================
echo ""
echo "=== Test 23: review.adversarialModel overrides adversarial-reviewer model independently (issue #235) ==="

setup_repo
stage_small_change

MOCK23_DIR="${TMPDIR_TEST}/mock23"
mkdir -p "${MOCK23_DIR}"
MOCK23_ARGS_FILE="${MOCK23_DIR}/invocation-args.txt"
rm -f "${MOCK23_ARGS_FILE}"
cat >"${MOCK23_DIR}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
printf '%s\n' "\$*" >>"${MOCK23_ARGS_FILE}"
echo "VERDICT: PASS"
echo ""
echo "No blocking issues found."
exit 0
EOF
chmod +x "${MOCK23_DIR}/claude"

TEST23_LOG="${TMPDIR_TEST}/test23-review.log"
rm -f "${TEST23_LOG}"

cd "${REPO_DIR}"
git config review.adversarialModel "some-adversarial-model-id"
REVIEW_LOG="${TEST23_LOG}" CLAUDE_CLI="${MOCK23_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
git config --unset review.adversarialModel 2>/dev/null || true
cd - >/dev/null

invocation_args23="$(cat "${MOCK23_ARGS_FILE}" 2>/dev/null || echo "")"

assert_contains \
  "configured review.adversarialModel reaches the adversarial-reviewer CLI invocation (issue #235)" \
  "--agent adversarial-reviewer -p --model some-adversarial-model-id" \
  "${invocation_args23}"

assert_contains \
  "code-reviewer still uses its own mode-based default model, unaffected by review.adversarialModel (issue #235)" \
  "--agent comprehensive-review:comprehensive-review-code-reviewer -p --model claude-haiku-4-5-20251001" \
  "${invocation_args23}"

# =========================================================
# TEST 24: extract_file_header_context surfaces stated scope
# (dev-env#35 — code-reviewer flagged Linux portability on a script whose
# header explicitly says "macOS-only, not intended for Linux/CI" because
# the diff-only prompt never showed that line)
# =========================================================
echo ""
echo "=== Test 24: file header context is extracted and injected into prompt ==="

setup_repo
cd "${REPO_DIR}"
cat >scoped.sh <<'SCRIPT'
#!/usr/bin/env bash
# macOS-only: uses BSD sed (`sed -i ''`). Operator script for this user's
# own machines, not intended for Linux/CI.
echo "hello"
SCRIPT
git add scoped.sh
cd - >/dev/null
stage_small_change

MOCK24_DIR="${TMPDIR_TEST}/mock24"
# Mock records the prompt it received so the test can assert on prompt content.
mkdir -p "${MOCK24_DIR}"
cat >"${MOCK24_DIR}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
cat >> "${MOCK24_DIR}/received_prompt.txt"
echo "VERDICT: PASS

No blocking issues found."
exit 0
EOF
chmod +x "${MOCK24_DIR}/claude"
rm -f "${MOCK24_DIR}/received_prompt.txt"

TEST24_LOG="${TMPDIR_TEST}/test24-review.log"
rm -f "${TEST24_LOG}"

cd "${REPO_DIR}"
REVIEW_LOG="${TEST24_LOG}" CLAUDE_CLI="${MOCK24_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

received="$(cat "${MOCK24_DIR}/received_prompt.txt" 2>/dev/null || echo "")"

assert_contains \
  "prompt includes the file's stated macOS-only scope (dev-env#35)" \
  "not intended for Linux/CI" \
  "${received}"

# =========================================================
# TEST 25: round-over-round feedback is injected on a retry after a FAIL
# (dev-env#35 — code-reviewer re-litigated already-addressed findings
# with a different remedy each round because each --no-session-persistence
# call started from zero)
# =========================================================
echo ""
echo "=== Test 25: prior-round FAIL feedback is injected into the retry prompt ==="

setup_repo
stage_small_change

MOCK25A_DIR="${TMPDIR_TEST}/mock25a"
make_mock_claude "${MOCK25A_DIR}" 0 "VERDICT: FAIL

ISSUE: Hardcoded path
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Use \$HOME instead of a literal path."

TEST25_LOG="${TMPDIR_TEST}/test25-review.log"
rm -f "${TEST25_LOG}"

cd "${REPO_DIR}"
REVIEW_LOG="${TEST25_LOG}" CLAUDE_CLI="${MOCK25A_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

# Second round: same branch, same changed file (foo.sh) — simulates a retry
# after an edit that didn't fully address round 1's finding. Mock records
# the prompt it receives.
MOCK25B_DIR="${TMPDIR_TEST}/mock25b"
mkdir -p "${MOCK25B_DIR}"
cat >"${MOCK25B_DIR}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
cat >> "${MOCK25B_DIR}/received_prompt.txt"
echo "VERDICT: PASS

No blocking issues found."
exit 0
EOF
chmod +x "${MOCK25B_DIR}/claude"
rm -f "${MOCK25B_DIR}/received_prompt.txt"

cd "${REPO_DIR}"
echo "echo round2edit" >>foo.sh
git add foo.sh
REVIEW_LOG="${TEST25_LOG}" CLAUDE_CLI="${MOCK25B_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

received25="$(cat "${MOCK25B_DIR}/received_prompt.txt" 2>/dev/null || echo "")"

assert_contains \
  "retry prompt includes round 1's BLOCKING finding (dev-env#35)" \
  "Hardcoded path" \
  "${received25}"

# Like make_mock_claude_by_agent, but differentiates three agent identities.
# The real arbiter call reuses agent_name="adversarial-reviewer" (see
# run-review.sh), so $2 alone cannot distinguish it from the real
# adversarial-reviewer call — both would match "*adversarial*". Instead,
# detect the arbiter call by its distinctive prompt content (piped on
# stdin): the arbiter prompt contains "CODE-REVIEWER VERDICT" as a section
# header, which never appears in the normal per-commit review prompt. Check
# stdin content FIRST, before falling back to $2, so it takes precedence
# over the "*adversarial*" branch.
make_mock_claude_three_way() {
  local mock_dir="$1" cr_output="$2" ar_output="$3" arbiter_output="$4"
  mkdir -p "${mock_dir}"
  printf '%s\n' "${cr_output}" >"${mock_dir}/cr_output.txt"
  printf '%s\n' "${ar_output}" >"${mock_dir}/ar_output.txt"
  printf '%s\n' "${arbiter_output}" >"${mock_dir}/arbiter_output.txt"
  cat >"${mock_dir}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
_stdin_input="\$(cat)"
if echo "\${_stdin_input}" | grep -q "CODE-REVIEWER VERDICT"; then
  cat "${mock_dir}/arbiter_output.txt"
elif [[ "\$2" == *adversarial* ]]; then
  cat "${mock_dir}/ar_output.txt"
else
  cat "${mock_dir}/cr_output.txt"
fi
exit 0
EOF
  chmod +x "${mock_dir}/claude"
}

# =========================================================
# TEST 26: arbiter overrides a code-reviewer BLOCKING FAIL when it sides
# with adversarial-reviewer's PASS (dev-env#35)
# =========================================================
echo ""
echo "=== Test 26: arbiter can override code-reviewer FAIL when adversarial-reviewer PASSes ==="

setup_repo
stage_small_change

MOCK26_DIR="${TMPDIR_TEST}/mock26"
make_mock_claude_three_way "${MOCK26_DIR}" \
  "VERDICT: FAIL

ISSUE: Missing Linux platform guard
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Add a runtime OS check." \
  "VERDICT: PASS

No blocking issues found. Script header already states macOS-only scope." \
  "VERDICT: PASS

The adversarial-reviewer is correct: the script's header comment already
documents macOS-only scope, so code-reviewer's finding does not apply."

TEST26_LOG="${TMPDIR_TEST}/test26-review.log"
rm -f "${TEST26_LOG}"

exit_t26=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST26_LOG}" CLAUDE_CLI="${MOCK26_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t26=$?
cd - >/dev/null

assert_eq \
  "arbiter PASS overrides code-reviewer BLOCKING FAIL (exit 0) - dev-env#35" \
  "0" \
  "${exit_t26}"

# =========================================================
# TEST 27: arbiter siding with code-reviewer still blocks the commit
# =========================================================
echo ""
echo "=== Test 27: arbiter siding with code-reviewer still blocks commit ==="

setup_repo
stage_small_change

MOCK27_DIR="${TMPDIR_TEST}/mock27"
make_mock_claude_three_way "${MOCK27_DIR}" \
  "VERDICT: FAIL

ISSUE: Hardcoded credential
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Remove the hardcoded credential." \
  "VERDICT: PASS

No blocking issues found." \
  "VERDICT: FAIL

ISSUE: Hardcoded credential
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: code-reviewer is correct; adversarial-reviewer missed this."

TEST27_LOG="${TMPDIR_TEST}/test27-review.log"
rm -f "${TEST27_LOG}"

exit_t27=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST27_LOG}" CLAUDE_CLI="${MOCK27_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t27=$?
cd - >/dev/null

assert_eq \
  "arbiter siding with code-reviewer still blocks commit (exit 1)" \
  "1" \
  "${exit_t27}"

test27_log_content="$(cat "${TEST27_LOG}")"
assert_contains \
  "arbiter ran for test 27 (not just coincidental pre-existing block)" \
  "=== ARBITER" \
  "${test27_log_content}"

# =========================================================
# TEST 28: arbiter-resolved false positive does not survive into the next
# commit's round history (dev-env#35 — write_round_feedback runs based on
# CODE_REVIEWER_VERDICT alone, before the arbiter has a chance to overrule
# it, so the PASS path must explicitly clear what was already written)
# =========================================================
echo ""
echo "=== Test 28: arbiter PASS clears the round-history entry code-reviewer wrote before it ran ==="

setup_repo
stage_small_change

MOCK28A_DIR="${TMPDIR_TEST}/mock28a"
make_mock_claude_three_way "${MOCK28A_DIR}" \
  "VERDICT: FAIL

ISSUE: Missing Linux platform guard
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Add a runtime OS check." \
  "VERDICT: PASS

No blocking issues found. Script header already states macOS-only scope." \
  "VERDICT: PASS

The adversarial-reviewer is correct: the script's header comment already
documents macOS-only scope, so code-reviewer's finding does not apply."

TEST28_LOG="${TMPDIR_TEST}/test28-review.log"
rm -f "${TEST28_LOG}"

cd "${REPO_DIR}"
REVIEW_LOG="${TEST28_LOG}" CLAUDE_CLI="${MOCK28A_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

# Second commit on the same branch+file-set. If round-history wasn't
# cleared, this retry's prompt would carry forward the already-resolved
# "Missing Linux platform guard" finding as PRIOR ROUND FEEDBACK.
MOCK28B_DIR="${TMPDIR_TEST}/mock28b"
mkdir -p "${MOCK28B_DIR}"
cat >"${MOCK28B_DIR}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
cat >> "${MOCK28B_DIR}/received_prompt.txt"
echo "VERDICT: PASS

No blocking issues found."
exit 0
EOF
chmod +x "${MOCK28B_DIR}/claude"
rm -f "${MOCK28B_DIR}/received_prompt.txt"

cd "${REPO_DIR}"
echo "echo round2edit" >>foo.sh
git add foo.sh
REVIEW_LOG="${TEST28_LOG}" CLAUDE_CLI="${MOCK28B_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

received28="$(cat "${MOCK28B_DIR}/received_prompt.txt" 2>/dev/null || echo "")"

contains_stale_finding="false"
if [[ "${received28}" == *"Missing Linux platform guard"* ]]; then
  contains_stale_finding="true"
fi

assert_eq \
  "arbiter-resolved false positive does not resurface in next commit's prompt (dev-env#35)" \
  "false" \
  "${contains_stale_finding}"

# =========================================================
# TEST 29: adversarial-reviewer cache is bypassed during a retry-after-FAIL,
# so the arbiter never gets handed a stale verdict (claude-config#246 —
# a cached PASS from an earlier attempt was reused across retries and misled
# the arbiter, which noticed the cache was stale but sided with a fabricated
# code-reviewer claim anyway rather than forcing a live check)
# =========================================================
echo ""
echo "=== Test 29: adversarial-reviewer cache is bypassed on a retry after a prior FAIL ==="

setup_repo
stage_small_change

# Prime the round-history file as if a prior round on this branch/file-set
# already FAILed (same mechanism Test 25/28 exercise) — this is the signal
# that should force cache bypass.
# Derive the key with the production function rather than rebuilding it here.
# A hand-rolled copy silently drifts: the previous version omitted the `sort`
# that round_history_key applies, and matched only because this test stages a
# single file, where sorting one line is a no-op. Staging a second file would
# have made the primed key stop matching the one run-review.sh computes — the
# cache bypass would stop being exercised and the test would still pass
# (smartwatermelon/claude-config#447).
# shellcheck source=hooks/lib-review-context.sh
source "${SCRIPT_DIR}/../lib-review-context.sh"
TEST29_ROUND_KEY="$(cd "${REPO_DIR}" && round_history_key "foo.sh")"
TEST29_CACHE_DIR="${REPO_DIR}/.git/claude-review-cache"
mkdir -p "${TEST29_CACHE_DIR}"
cat >"${TEST29_CACHE_DIR}/round-history-${TEST29_ROUND_KEY}" <<'EOF'
VERDICT: FAIL

ISSUE: Some already-addressed finding from a prior round
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Placeholder prior-round content.
EOF

# Prime the adversarial-reviewer cache with a PASS, as if a live call had
# already happened on this exact diff+script-version and passed. Without
# the fix, invoke_agent would serve this cached PASS straight back with no
# live call — the mock below would never run for the adversarial-reviewer
# agent identity, and the marker file would never appear.
TEST29_SCRIPT_SHA="$(shasum -a 256 "${SUBJECT}" | awk '{print $1}' | cut -c1-12)"
TEST29_DIFF="$(cd "${REPO_DIR}" && git diff --cached)"
TEST29_DIFF_HASH="$(printf '%s\n%s\n' "${TEST29_SCRIPT_SHA}" "${TEST29_DIFF}" | shasum -a 256 | awk '{print $1}')"
{
  echo "PASS"
  date -u +%Y-%m-%dT%H:%M:%SZ
} >"${TEST29_CACHE_DIR}/adversarial-${TEST29_DIFF_HASH}"

MOCK29_DIR="${TMPDIR_TEST}/mock29"
mkdir -p "${MOCK29_DIR}"
cat >"${MOCK29_DIR}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
if [[ "\$2" == *adversarial* ]]; then
  echo "VERDICT: PASS

No blocking issues found (live call)."
else
  echo "VERDICT: FAIL

ISSUE: Some already-addressed finding from a prior round
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Placeholder prior-round content."
fi
exit 0
EOF
chmod +x "${MOCK29_DIR}/claude"

TEST29_LOG="${TMPDIR_TEST}/test29-review.log"
rm -f "${TEST29_LOG}"

cd "${REPO_DIR}"
REVIEW_LOG="${TEST29_LOG}" CLAUDE_CLI="${MOCK29_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null
# Note: we can't use a "did adversarial-reviewer's mock run live" marker here --
# the arbiter step (triggered by this same disagreement) always makes its own
# live adversarial-reviewer call via a separate cache (ARBITER_CACHE), so such
# a marker would be touched regardless of whether the parallel-phase cache was
# bypassed. The log line is the only signal that distinguishes the two paths.
test29_log_content="$(cat "${TEST29_LOG}")"
adversarial_not_cached="true"
[[ "${test29_log_content}" == *"VERDICT: PASS (cached)"* ]] && adversarial_not_cached="false"

assert_eq \
  "review log does not report a cached-PASS shortcut for adversarial-reviewer (claude-config#246)" \
  "true" \
  "${adversarial_not_cached}"

# Mock `gh` that records every `gh issue create` invocation instead of
# hitting the API. Placed first on PATH so run-review.sh's
# `command -v gh` / `gh issue create` resolve to it.
make_mock_gh() {
  local mock_dir="$1"
  mkdir -p "${mock_dir}"
  : >"${mock_dir}/gh_calls.txt"
  cat >"${mock_dir}/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "issue" && "\$2" == "create" ]]; then
  printf 'issue-create\n' >>"${mock_dir}/gh_calls.txt"
  # Persist the body so the test can assert on what would be published.
  _prev=""
  for _a in "\$@"; do
    [[ "\${_prev}" == "--body" ]] && printf '%s\n' "\${_a}" >>"${mock_dir}/gh_bodies.txt"
    _prev="\${_a}"
  done
  echo "https://github.com/smartwatermelon/claude-config/issues/9999"
  exit 0
fi
exit 0
EOF
  chmod +x "${mock_dir}/gh"
}

# =========================================================
# TEST 30: arbiter PASS writes the local disagreement log and files NO issue
# (claude-config#332 — a strict reviewer disagreeing with a skeptical one is
# the system working; 5 of 6 historical filings were this healthy case)
# =========================================================
echo ""
echo "=== Test 30: arbiter PASS logs locally, files no GitHub issue (claude-config#332) ==="

setup_repo
stage_small_change

MOCK30_DIR="${TMPDIR_TEST}/mock30"
make_mock_claude_three_way "${MOCK30_DIR}" \
  "VERDICT: FAIL

ISSUE: Missing Linux platform guard
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: SENTINEL_CR_VERBATIM add a runtime OS check." \
  "VERDICT: PASS

No blocking issues found. SENTINEL_AR_VERBATIM macOS-only scope." \
  "VERDICT: PASS

adversarial-reviewer is correct: the header already documents macOS-only scope."

MOCK30_GH="${TMPDIR_TEST}/gh30"
make_mock_gh "${MOCK30_GH}"
TEST30_LOG="${TMPDIR_TEST}/test30-review.log"
TEST30_DIS="${TMPDIR_TEST}/test30-disagreements.log"
rm -f "${TEST30_LOG}" "${TEST30_DIS}"

cd "${REPO_DIR}"
PATH="${MOCK30_GH}:${PATH}" REVIEW_LOG="${TEST30_LOG}" DISAGREEMENT_LOG="${TEST30_DIS}" \
  CLAUDE_CLI="${MOCK30_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

test30_dis="$(cat "${TEST30_DIS}" 2>/dev/null || echo "")"

assert_contains \
  "PASS disagreement is recorded in the local disagreement log" \
  "=== REVIEWER DISAGREEMENT" \
  "${test30_dis}"

assert_contains \
  "local log records the arbiter verdict" \
  "arbiter_verdict: PASS" \
  "${test30_dis}"

assert_contains \
  "local log keeps code-reviewer output verbatim (local-only, never published)" \
  "SENTINEL_CR_VERBATIM" \
  "${test30_dis}"

assert_contains \
  "local log keeps adversarial-reviewer output verbatim" \
  "SENTINEL_AR_VERBATIM" \
  "${test30_dis}"

test30_gh_calls="$(cat "${MOCK30_GH}/gh_calls.txt" 2>/dev/null || echo "")"
assert_eq \
  "arbiter PASS files NO GitHub issue (claude-config#332 defect 3)" \
  "" \
  "${test30_gh_calls}"

# =========================================================
# TEST 31: arbiter FAIL DOES file a GitHub issue, and that issue does NOT
# contain verbatim reviewer output (claude-config#332 defect 2 — cross-org
# source leak)
# =========================================================
echo ""
echo "=== Test 31: arbiter FAIL files no issue; the local log keeps everything ==="

setup_repo
stage_small_change

MOCK31_DIR="${TMPDIR_TEST}/mock31"
make_mock_claude_three_way "${MOCK31_DIR}" \
  "VERDICT: FAIL

ISSUE: Hardcoded credential
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: SENTINEL_CR_VERBATIM remove the hardcoded credential." \
  "VERDICT: PASS

No blocking issues found. SENTINEL_AR_VERBATIM out of scope." \
  "VERDICT: FAIL

ISSUE: Hardcoded credential
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: SENTINEL_ARBITER_REASONING code-reviewer is correct."

MOCK31_GH="${TMPDIR_TEST}/gh31"
make_mock_gh "${MOCK31_GH}"
TEST31_LOG="${TMPDIR_TEST}/test31-review.log"
TEST31_DIS="${TMPDIR_TEST}/test31-disagreements.log"
rm -f "${TEST31_LOG}" "${TEST31_DIS}"

cd "${REPO_DIR}"
PATH="${MOCK31_GH}:${PATH}" REVIEW_LOG="${TEST31_LOG}" DISAGREEMENT_LOG="${TEST31_DIS}" \
  CLAUDE_CLI="${MOCK31_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

# An arbiter FAIL used to file one issue into smartwatermelon/claude-config.
# It no longer files anything (claude-config#418): across five real filings
# not one produced work in this repo, and the local log is strictly richer.
test31_calls="$({ grep -c 'issue-create' "${MOCK31_GH}/gh_calls.txt" || true; } 2>/dev/null)"
assert_eq \
  "arbiter FAIL files NO GitHub issue (claude-config#418)" \
  "0" \
  "${test31_calls}"

test31_dis="$(cat "${TEST31_DIS}" 2>/dev/null || echo "")"

assert_contains \
  "local log records an arbiter FAIL disagreement" \
  "arbiter_verdict: FAIL" \
  "${test31_dis}"

assert_contains \
  "local log keeps the arbiter's reasoning" \
  "SENTINEL_ARBITER_REASONING" \
  "${test31_dis}"

# Verbatim reviewer output is the reason filing was risky (cross-org source
# leak, claude-config#332). It stays in the local log, which never leaves the
# machine — so both sentinels MUST be present here.
assert_contains \
  "local log keeps code-reviewer output verbatim" \
  "SENTINEL_CR_VERBATIM" \
  "${test31_dis}"

assert_contains \
  "local log keeps adversarial-reviewer output verbatim" \
  "SENTINEL_AR_VERBATIM" \
  "${test31_dis}"

# =========================================================
# TEST 32: a recurring disagreement on the same branch files nothing and logs
# every time. This used to assert (repo, branch) dedup capping filing at one
# issue; with filing removed (claude-config#418) the dedup key is gone, so the
# property under test is now "repeats never file, and logging is not gated".
# =========================================================
echo ""
echo "=== Test 32: repeated disagreements file nothing and log every time ==="

MOCK32_GH="${TMPDIR_TEST}/gh32"
make_mock_gh "${MOCK32_GH}"
TEST32_LOG="${TMPDIR_TEST}/test32-review.log"
TEST32_DIS="${TMPDIR_TEST}/test32-disagreements.log"
rm -f "${TEST32_LOG}" "${TEST32_DIS}"

# Two runs on the same branch, each producing the same arbiter FAIL.
for _t32_round in 1 2; do
  setup_repo
  stage_small_change
  MOCK32_DIR="${TMPDIR_TEST}/mock32-${_t32_round}"
  make_mock_claude_three_way "${MOCK32_DIR}" \
    "VERDICT: FAIL

ISSUE: Hardcoded credential
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Remove the hardcoded credential." \
    "VERDICT: PASS

No blocking issues found." \
    "VERDICT: FAIL

ISSUE: Hardcoded credential
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: code-reviewer is correct."
  cd "${REPO_DIR}"
  PATH="${MOCK32_GH}:${PATH}" REVIEW_LOG="${TEST32_LOG}" DISAGREEMENT_LOG="${TEST32_DIS}" \
    CLAUDE_CLI="${MOCK32_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
  cd - >/dev/null
done

test32_calls="$({ grep -c 'issue-create' "${MOCK32_GH}/gh_calls.txt" || true; } 2>/dev/null)"
assert_eq \
  "a recurring disagreement files no issue on any run (claude-config#418)" \
  "0" \
  "${test32_calls}"

test32_records="$({ grep -c '=== REVIEWER DISAGREEMENT' "${TEST32_DIS}" || true; } 2>/dev/null)"
assert_eq \
  "every run appends a local disagreement record (logging was never gated)" \
  "2" \
  "${test32_records}"

# The dedup marker existed only to cap filing. With no filing it must never be
# written, or an old log would grow inert bookkeeping lines forever.
test32_markers="$({ grep -c 'filed-issue-for:' "${TEST32_DIS}" || true; } 2>/dev/null)"
assert_eq \
  "no dedup bookkeeping is written now that nothing files" \
  "0" \
  "${test32_markers}"

# =========================================================
# TEST 33: an unwritable disagreement-log path must not fail the run
# (best-effort requirement, claude-config#332)
# =========================================================
echo ""
echo "=== Test 33: unwritable disagreement log does not fail the run ==="

setup_repo
stage_small_change

MOCK33_DIR="${TMPDIR_TEST}/mock33"
make_mock_claude_three_way "${MOCK33_DIR}" \
  "VERDICT: FAIL

ISSUE: Missing Linux platform guard
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Add a runtime OS check." \
  "VERDICT: PASS

No blocking issues found." \
  "VERDICT: PASS

adversarial-reviewer is correct; the finding does not apply."

MOCK33_GH="${TMPDIR_TEST}/gh33"
make_mock_gh "${MOCK33_GH}"
TEST33_LOG="${TMPDIR_TEST}/test33-review.log"
rm -f "${TEST33_LOG}"

exit_t33=0
cd "${REPO_DIR}"
PATH="${MOCK33_GH}:${PATH}" REVIEW_LOG="${TEST33_LOG}" \
  DISAGREEMENT_LOG="/nonexistent-dir-claude-config-332/disagreements.log" \
  CLAUDE_CLI="${MOCK33_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t33=$?
cd - >/dev/null

assert_eq \
  "unwritable disagreement log does not block an otherwise-passing commit (exit 0)" \
  "0" \
  "${exit_t33}"

# =========================================================
# TEST 34: --no-file dry-run prints non-blocking findings instead of filing
#
# Without this flag the only way to read findings before they became issues
# was a PATH stub that broke every gh call, including the reviewer's own
# environment probes. The flag must suppress filing while leaving the rest of
# the run intact. See #415.
# =========================================================
echo ""
echo "=== Test 34: --no-file prints non-blocking findings and files nothing ==="

setup_repo
stage_small_change
cd "${REPO_DIR}"
git add foo.sh
git commit -q -m "stage a change" --no-verify
cd - >/dev/null

MOCK34_DIR="${TMPDIR_TEST}/mock34"
make_mock_claude "${MOCK34_DIR}" 0 "VERDICT: PASS

No blocking issues found.

NON_BLOCKING_ISSUE:
TITLE: Pre-existing quoting weakness
SOURCE: code-reviewer
LOCATION: foo.sh:2
DETAILS: Unquoted expansion on line two.
Second line of details.
END_ISSUE"

MOCK34_GH="${TMPDIR_TEST}/gh34"
make_mock_gh "${MOCK34_GH}"
TEST34_LOG="${TMPDIR_TEST}/test34-review.log"
rm -f "${TEST34_LOG}"

exit_t34=0
cd "${REPO_DIR}"
# REPO_OWNER/REPO_NAME are supplied so this exercises the real filing path
# being suppressed, not the repo-info-unavailable early return (which would
# file nothing regardless and prove nothing about the flag).
stdout_t34=$(git diff main~1 main | PATH="${MOCK34_GH}:${PATH}" \
  REVIEW_LOG="${TEST34_LOG}" CLAUDE_CLI="${MOCK34_DIR}/claude" \
  REPO_OWNER="smartwatermelon" REPO_NAME="claude-config" \
  bash "${SUBJECT}" --mode=codebase --no-file 2>/dev/null) || exit_t34=$?
cd - >/dev/null

assert_eq \
  "--no-file dry-run still exits 0 on a passing review" \
  "0" \
  "${exit_t34}"

assert_contains \
  "--no-file prints the finding to stdout in NON_BLOCKING_ISSUE block format" \
  "TITLE: Pre-existing quoting weakness" \
  "${stdout_t34}"

assert_contains \
  "--no-file printed block is terminated so it can be reparsed" \
  "END_ISSUE" \
  "${stdout_t34}"

assert_eq \
  "--no-file files no GitHub issue (zero gh issue create calls)" \
  "0" \
  "$({ grep -c 'issue-create' "${MOCK34_GH}/gh_calls.txt" || true; } 2>/dev/null)"

# =========================================================
# TEST 35: REVIEW_NO_FILE=1 env var is equivalent to --no-file
# =========================================================
echo ""
echo "=== Test 35: REVIEW_NO_FILE=1 suppresses filing like --no-file ==="

MOCK35_GH="${TMPDIR_TEST}/gh35"
make_mock_gh "${MOCK35_GH}"
TEST35_LOG="${TMPDIR_TEST}/test35-review.log"
rm -f "${TEST35_LOG}"

# Reusing Test 34's diff would be a cache hit, so advance the tree first.
cd "${REPO_DIR}"
echo "echo second change" >>foo.sh
git add foo.sh
git commit -q -m "second change" --no-verify
cd - >/dev/null

MOCK35_DIR="${TMPDIR_TEST}/mock35"
make_mock_claude "${MOCK35_DIR}" 0 "VERDICT: PASS

No blocking issues found.

NON_BLOCKING_ISSUE:
TITLE: Env var path finding
SOURCE: code-reviewer
LOCATION: foo.sh:3
DETAILS: Reached via REVIEW_NO_FILE.
END_ISSUE"

exit_t35=0
cd "${REPO_DIR}"
stdout_t35=$(git diff main~1 main | PATH="${MOCK35_GH}:${PATH}" \
  REVIEW_LOG="${TEST35_LOG}" CLAUDE_CLI="${MOCK35_DIR}/claude" REVIEW_NO_FILE=1 \
  REPO_OWNER="smartwatermelon" REPO_NAME="claude-config" \
  bash "${SUBJECT}" --mode=codebase 2>/dev/null) || exit_t35=$?
cd - >/dev/null

assert_eq \
  "REVIEW_NO_FILE=1 dry-run still exits 0 on a passing review" \
  "0" \
  "${exit_t35}"

assert_contains \
  "REVIEW_NO_FILE=1 prints the finding to stdout" \
  "TITLE: Env var path finding" \
  "${stdout_t35}"

assert_eq \
  "REVIEW_NO_FILE=1 files no GitHub issue" \
  "0" \
  "$({ grep -c 'issue-create' "${MOCK35_GH}/gh_calls.txt" || true; } 2>/dev/null)"

# =========================================================
# TEST 36: default (no flag) still files — the flag must be opt-in
#
# Guards against the dry-run guard being placed so early, or keyed so
# loosely, that it suppresses filing unconditionally.
# =========================================================
echo ""
echo "=== Test 36: without --no-file, findings are still filed ==="

MOCK36_GH="${TMPDIR_TEST}/gh36"
make_mock_gh "${MOCK36_GH}"
TEST36_LOG="${TMPDIR_TEST}/test36-review.log"
rm -f "${TEST36_LOG}"

cd "${REPO_DIR}"
echo "echo third change" >>foo.sh
git add foo.sh
git commit -q -m "third change" --no-verify
cd - >/dev/null

MOCK36_DIR="${TMPDIR_TEST}/mock36"
make_mock_claude "${MOCK36_DIR}" 0 "VERDICT: PASS

No blocking issues found.

NON_BLOCKING_ISSUE:
TITLE: Should be filed
SOURCE: code-reviewer
LOCATION: foo.sh:4
DETAILS: Control case for the dry-run flag.
END_ISSUE"

cd "${REPO_DIR}"
# The fixture repo has no origin remote, so run-review.sh cannot derive
# REPO_OWNER/REPO_NAME and create_nonblocking_issues would bail before
# reaching the filing path. Supply them directly (the script honours a
# preset value) so this control case exercises filing for real.
git diff main~1 main | PATH="${MOCK36_GH}:${PATH}" \
  REVIEW_LOG="${TEST36_LOG}" CLAUDE_CLI="${MOCK36_DIR}/claude" \
  REPO_OWNER="smartwatermelon" REPO_NAME="claude-config" \
  bash "${SUBJECT}" --mode=codebase >/dev/null 2>&1 || true
cd - >/dev/null

assert_eq \
  "without --no-file, gh issue create is still invoked (flag is opt-in)" \
  "1" \
  "$({ grep -c 'issue-create' "${MOCK36_GH}/gh_calls.txt" || true; } 2>/dev/null)"

# =========================================================
# TEST 37: markdown-bolded SEVERITY still blocks the commit
#
# All five severity gates used a bare `grep -q "SEVERITY: BLOCKING"`, which is
# case-sensitive and space-exact. A reviewer emitting `**SEVERITY:** BLOCKING`
# — a likely form from a prose-heavy prompt — slipped the gate, so a real
# blocking defect was committed with exit 0. has_blocking_severity() normalizes
# emphasis, case, and spacing the way parse_verdict already did for verdicts.
# Same fixture shape as Test 13, which pins the plain-text form.
# =========================================================
echo ""
echo "=== Test 37: markdown-bolded SEVERITY blocks commit ==="

setup_repo
stage_small_change

MOCK37_DIR="${TMPDIR_TEST}/mock37"
make_mock_claude_by_agent "${MOCK37_DIR}" \
  "VERDICT: PASS

No blocking issues found." \
  "VERDICT: FAIL

ISSUE: Hardcoded credential
**SEVERITY:** BLOCKING
LOCATION: foo.sh:2
DETAILS: Remove the hardcoded credential."

TEST37_LOG="${TMPDIR_TEST}/test37-review.log"
rm -f "${TEST37_LOG}"

exit_t37=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST37_LOG}" CLAUDE_CLI="${MOCK37_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t37=$?
cd - >/dev/null

assert_eq \
  "markdown-bolded SEVERITY: BLOCKING blocks commit (exit 1)" \
  "1" \
  "${exit_t37}"

# =========================================================
# TEST 38: lowercase/double-spaced SEVERITY still blocks the commit
#
# The other two variants from the falsification table: casing and an extra
# space after the colon. Both passed the old literal grep.
# =========================================================
echo ""
echo "=== Test 38: lowercase and double-spaced SEVERITY block commit ==="

setup_repo
stage_small_change

MOCK38_DIR="${TMPDIR_TEST}/mock38"
make_mock_claude_by_agent "${MOCK38_DIR}" \
  "VERDICT: PASS

No blocking issues found." \
  "VERDICT: FAIL

ISSUE: Hardcoded credential
Severity:  Blocking
LOCATION: foo.sh:2
DETAILS: Remove the hardcoded credential."

TEST38_LOG="${TMPDIR_TEST}/test38-review.log"
rm -f "${TEST38_LOG}"

exit_t38=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST38_LOG}" CLAUDE_CLI="${MOCK38_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t38=$?
cd - >/dev/null

assert_eq \
  "lowercase + double-spaced SEVERITY blocks commit (exit 1)" \
  "1" \
  "${exit_t38}"

# =========================================================
# TEST 39: a WARNING-only FAIL is still non-blocking after the loosening
#
# The must-NOT-match half of the corpus, end to end: loosening the matcher
# must not turn every FAIL into a block. Guards the direction Test 12 pins,
# against a future pattern change that drops the BLOCKING keyword requirement.
# =========================================================
echo ""
echo "=== Test 39: WARNING-only FAIL stays non-blocking after loosening ==="

setup_repo
stage_small_change

MOCK39_DIR="${TMPDIR_TEST}/mock39"
make_mock_claude_by_agent "${MOCK39_DIR}" \
  "VERDICT: PASS

No blocking issues found." \
  "VERDICT: FAIL

ISSUE: Unpin needs rationale
**SEVERITY:** WARNING
LOCATION: settings.json:1
DETAILS: Document why the pin was removed."

TEST39_LOG="${TMPDIR_TEST}/test39-review.log"
rm -f "${TEST39_LOG}"

exit_t39=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST39_LOG}" CLAUDE_CLI="${MOCK39_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t39=$?
cd - >/dev/null

assert_eq \
  "markdown-bolded WARNING does not block commit (exit 0)" \
  "0" \
  "${exit_t39}"

# =========================================================
# TESTS 40-46: structured output is the decision channel (claude-config#443)
#
# The reviewer's blocking/non-blocking call is a boolean, returned in
# `.structured_output.blocking` under --output-format json --json-schema.
# The prose is still produced and still consumed (DETAILS, issue filing,
# arbiter input, logs) — structured output ADDS a decision channel.
#
# The trap these tests exist to pin: `jq -e '.structured_output.blocking'`
# exits 1 for blocking=false, for the key being absent, AND for null. That
# collapses "the reviewer said it is fine" into "the reviewer never answered",
# which is a silent fail-open on the exact gate the pipeline exists to be.
# Test 42 is the one that catches it.
# =========================================================
echo ""
echo "=== Test 40: structured blocking=true blocks the commit ==="

setup_repo
stage_small_change

MOCK40_DIR="${TMPDIR_TEST}/mock40"
# Prose deliberately carries NO "SEVERITY: BLOCKING" line. has_blocking_severity
# would therefore pass this. Only the structured boolean can block it, so a
# rejection here proves the structured channel is genuinely wired and load-
# bearing rather than shadowed by the prose matcher.
# Both reviewers agree, so the arbiter never engages and this test measures
# only the gate. (An adversarial PASS against a code-reviewer block routes
# through arbitration instead, which is a different code path — Test 48.)
make_mock_claude_by_agent "${MOCK40_DIR}" \
  "VERDICT: FAIL

ISSUE: Unchecked index
LOCATION: foo.sh:2
DETAILS: The loop can read past the end." \
  "VERDICT: FAIL

ISSUE: Unchecked index
LOCATION: foo.sh:2
DETAILS: The loop can read past the end." \
  '{"verdict":"FAIL","blocking":true,"findings":[]}' \
  '{"verdict":"FAIL","blocking":true,"findings":[]}'

TEST40_LOG="${TMPDIR_TEST}/test40-review.log"
rm -f "${TEST40_LOG}"

exit_t40=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST40_LOG}" CLAUDE_CLI="${MOCK40_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t40=$?
cd - >/dev/null

assert_eq \
  "structured blocking=true blocks even with no SEVERITY line in the prose" \
  "1" \
  "${exit_t40}"

# =========================================================
echo ""
echo "=== Test 41: structured blocking=false passes the commit ==="

setup_repo
stage_small_change

MOCK41_DIR="${TMPDIR_TEST}/mock41"
# The mirror of Test 40. The prose DOES say SEVERITY: BLOCKING — inside a
# sentence disclaiming it — so has_blocking_severity's deliberate substring
# match would block. The reviewer answered blocking=false, and a reviewer that
# answered is not second-guessed by a grep over its own explanation. That is
# the substring false-positive class #443 names, fixed rather than tolerated.
make_mock_claude_by_agent "${MOCK41_DIR}" \
  "VERDICT: FAIL

ISSUE: Style nit
LOCATION: foo.sh:2
DETAILS: To be clear this is not a SEVERITY: BLOCKING issue, only a nit." \
  "VERDICT: PASS

No blocking issues found." \
  '{"verdict":"FAIL","blocking":false,"findings":[]}' \
  '{"verdict":"PASS","blocking":false,"findings":[]}'

TEST41_LOG="${TMPDIR_TEST}/test41-review.log"
rm -f "${TEST41_LOG}"

exit_t41=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST41_LOG}" CLAUDE_CLI="${MOCK41_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t41=$?
cd - >/dev/null

assert_eq \
  "structured blocking=false passes despite a disclaimed SEVERITY string" \
  "0" \
  "${exit_t41}"

# =========================================================
# TEST 42: THE FAIL-OPEN TEST.
#
# The single most important test in this group. The envelope is well-formed
# and `.result` is present, but there is NO `.structured_output` key at all —
# an older CLI, a truncated response, a model that returned prose instead of
# a tool call. The reviewer did NOT answer the boolean.
#
# A naive `jq -e '.structured_output.blocking'` exits 1 here, exactly as it
# does for a legitimate blocking=false, and the commit sails through. It must
# not. Absent structured output means NO USABLE ANSWER, and the gate must fall
# back to the prose matcher — which here finds SEVERITY: BLOCKING and blocks.
# =========================================================
echo ""
echo "=== Test 42: missing .structured_output does NOT silently pass ==="

setup_repo
stage_small_change

MOCK42_DIR="${TMPDIR_TEST}/mock42"
# Both reviewers return an envelope with NO structured_output key, and both
# agree on the finding, so the arbiter never engages and the assertion is
# purely about the missing-key branch.
make_mock_claude_by_agent "${MOCK42_DIR}" \
  "VERDICT: FAIL

ISSUE: Command injection via unquoted expansion
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: The variable is expanded into a shell command unquoted." \
  "VERDICT: FAIL

ISSUE: Command injection via unquoted expansion
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: The variable is expanded into a shell command unquoted." \
  "none" \
  "none"

TEST42_LOG="${TMPDIR_TEST}/test42-review.log"
rm -f "${TEST42_LOG}"

exit_t42=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST42_LOG}" CLAUDE_CLI="${MOCK42_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t42=$?
cd - >/dev/null

assert_eq \
  "FAIL-OPEN GUARD: absent structured_output falls back to prose and still blocks" \
  "1" \
  "${exit_t42}"

# =========================================================
# TEST 43: blocking:null is rejected, not trusted.
#
# null is not a boolean. It is a malformed answer, not a "no". It must land in
# the same no-usable-answer branch as an absent key.
# =========================================================
echo ""
echo "=== Test 43: blocking:null is rejected, not read as false ==="

setup_repo
stage_small_change

MOCK43_DIR="${TMPDIR_TEST}/mock43"
# Both reviewers return blocking:null, and both agree on the finding, so the
# arbiter never engages and the assertion is purely about the null branch.
make_mock_claude_by_agent "${MOCK43_DIR}" \
  "VERDICT: FAIL

ISSUE: Unsafe eval of reviewer-supplied text
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Input reaches eval without validation." \
  "VERDICT: FAIL

ISSUE: Unsafe eval of reviewer-supplied text
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Input reaches eval without validation." \
  '{"verdict":"FAIL","blocking":null,"findings":[]}' \
  '{"verdict":"FAIL","blocking":null,"findings":[]}'

TEST43_LOG="${TMPDIR_TEST}/test43-review.log"
rm -f "${TEST43_LOG}"

exit_t43=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST43_LOG}" CLAUDE_CLI="${MOCK43_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t43=$?
cd - >/dev/null

assert_eq \
  "blocking:null is not a boolean — falls back to prose and blocks" \
  "1" \
  "${exit_t43}"

# =========================================================
# TEST 44: the STRING "false" is rejected, not trusted.
#
# The mirror hazard. In jq the string "false" is TRUTHY, so a naive truthiness
# read turns a type slip into a hard block on everything. Requiring a real
# JSON boolean rejects it as no-usable-answer instead, and the prose decides.
# Here the prose is WARNING-only, so the correct outcome is a PASS — proving
# the string was neither trusted as false NOR mistaken for true.
# =========================================================
echo ""
echo "=== Test 44: string \"false\" is rejected as a non-boolean ==="

setup_repo
stage_small_change

MOCK44_DIR="${TMPDIR_TEST}/mock44"
make_mock_claude_by_agent "${MOCK44_DIR}" \
  "VERDICT: FAIL

ISSUE: Missing rationale comment
SEVERITY: WARNING
LOCATION: foo.sh:2
DETAILS: Explain why this line is here." \
  "VERDICT: PASS

No blocking issues found." \
  '{"verdict":"FAIL","blocking":"false","findings":[]}' \
  '{"verdict":"PASS","blocking":false,"findings":[]}'

TEST44_LOG="${TMPDIR_TEST}/test44-review.log"
rm -f "${TEST44_LOG}"

exit_t44=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST44_LOG}" CLAUDE_CLI="${MOCK44_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t44=$?
cd - >/dev/null

assert_eq \
  "string \"false\" is not trusted as a boolean; WARNING-only prose passes" \
  "0" \
  "${exit_t44}"

# =========================================================
# TEST 45: a timeout stays NON-blocking (issues #172, #199).
#
# `timeout` killing the CLI yields exit 124 and zero bytes — not a JSON
# envelope, not prose. invoke_agent turns that into a synthetic
# "VERDICT: FAIL (timeout)" carrying no structured decision and no SEVERITY
# line. The strict extractor must not convert an infrastructure failure into
# a hard block: an unreachable reviewer is not a blocking finding.
# =========================================================
echo ""
echo "=== Test 45: timeout (exit 124, zero bytes) stays non-blocking ==="

setup_repo
stage_small_change

MOCK45_DIR="${TMPDIR_TEST}/mock45"
mkdir -p "${MOCK45_DIR}"
cat >"${MOCK45_DIR}/claude" <<'MOCK45EOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
# Exactly what `timeout` produces when it kills the CLI: no stdout, exit 124.
exit 124
MOCK45EOF
chmod +x "${MOCK45_DIR}/claude"

TEST45_LOG="${TMPDIR_TEST}/test45-review.log"
rm -f "${TEST45_LOG}"

exit_t45=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST45_LOG}" CLAUDE_CLI="${MOCK45_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t45=$?
cd - >/dev/null

assert_eq \
  "timeout with zero bytes does not become a hard block (issue #172)" \
  "0" \
  "${exit_t45}"

# =========================================================
# TEST 46: a non-JSON response degrades to the prose path.
#
# An older CLI that does not understand --json-schema returns bare prose. The
# script must not discard it as unparseable; it must review on the prose, with
# has_blocking_severity() as the gate — which is why #442's matcher is kept
# rather than reverted. Here the prose is BLOCKING, so the commit is rejected.
# =========================================================
echo ""
echo "=== Test 46: non-JSON (older CLI) degrades to the prose gate ==="

setup_repo
stage_small_change

MOCK46_DIR="${TMPDIR_TEST}/mock46"
make_mock_claude "${MOCK46_DIR}" 0 "VERDICT: FAIL

ISSUE: Secret written to a world-readable path
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: The token lands in a file with mode 0644." "raw"

TEST46_LOG="${TMPDIR_TEST}/test46-review.log"
rm -f "${TEST46_LOG}"

exit_t46=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST46_LOG}" CLAUDE_CLI="${MOCK46_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t46=$?
cd - >/dev/null

assert_eq \
  "bare prose from an older CLI still reaches has_blocking_severity and blocks" \
  "1" \
  "${exit_t46}"

# =========================================================
# TEST 47: the sentinel never reaches the human-facing log.
#
# The structured decision travels to the gates as a leading marker line on the
# prose, because every caller captures invoke_agent by command substitution.
# That is machinery. It must be stripped before the output reaches a terminal,
# the review log, issue filing, or another agent's prompt.
# =========================================================
echo ""
echo "=== Test 47: structured sentinel is stripped from the review log ==="

setup_repo
stage_small_change

MOCK47_DIR="${TMPDIR_TEST}/mock47"
make_mock_claude_by_agent "${MOCK47_DIR}" \
  "VERDICT: PASS

No blocking issues found." \
  "VERDICT: PASS

No blocking issues found."

TEST47_LOG="${TMPDIR_TEST}/test47-review.log"
rm -f "${TEST47_LOG}"

cd "${REPO_DIR}"
REVIEW_LOG="${TEST47_LOG}" CLAUDE_CLI="${MOCK47_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

log47="$(cat "${TEST47_LOG}" 2>/dev/null || echo "")"

assert_not_contains \
  "review log carries no __REVIEW_BLOCKING__ marker" \
  "__REVIEW_BLOCKING__" \
  "${log47}"

assert_contains \
  "review log still carries the reviewer's prose" \
  "No blocking issues found." \
  "${log47}"

# =========================================================
# TEST 48: the real CLI's tool-call shape — .result is the SERIALIZED object.
#
# Caught by a pre-push dry-run against the live CLI, not by any mock. Under
# --json-schema the model is constrained to a TOOL CALL, so it emits no prose
# at all: `.result` holds the serialized structured object, and there is no
# VERDICT line anywhere. parse_verdict then returns "" and the whole run hard-
# blocks as "Could not parse verdict" — a total outage of the review gate, on
# every commit, from a change whose mocks were all green.
#
# The fix is to RENDER the VERDICT/ISSUE/SEVERITY/LOCATION/DETAILS block out of
# .structured_output when .result carries no prose. This pins that, using the
# exact response shape measured from the live CLI.
# =========================================================
echo ""
echo "=== Test 48: serialized-object .result (real CLI tool-call shape) ==="

setup_repo
stage_small_change

MOCK48_DIR="${TMPDIR_TEST}/mock48"
mkdir -p "${MOCK48_DIR}"
# Measured shape: result is the tojson of the same object in structured_output.
cat >"${MOCK48_DIR}/envelope.json" <<'MOCK48JSON'
{"type":"result","subtype":"success","is_error":false,"stop_reason":"tool_use",
 "result":"{\"verdict\":\"FAIL\",\"blocking\":true,\"findings\":[{\"severity\":\"BLOCKING\",\"location\":\"foo.sh:2\",\"issue\":\"Unquoted expansion reaches a shell command.\"}]}",
 "structured_output":{"verdict":"FAIL","blocking":true,"findings":[{"severity":"BLOCKING","location":"foo.sh:2","issue":"Unquoted expansion reaches a shell command."}]}}
MOCK48JSON
cat >"${MOCK48_DIR}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
cat "${MOCK48_DIR}/envelope.json"
exit 0
EOF
chmod +x "${MOCK48_DIR}/claude"

TEST48_LOG="${TMPDIR_TEST}/test48-review.log"
rm -f "${TEST48_LOG}"

exit_t48=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST48_LOG}" CLAUDE_CLI="${MOCK48_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t48=$?
cd - >/dev/null

log48="$(cat "${TEST48_LOG}" 2>/dev/null || echo "")"

assert_eq \
  "serialized-object .result blocks (not 'unparseable')" \
  "1" \
  "${exit_t48}"

assert_not_contains \
  "serialized-object .result does not log an unparseable verdict" \
  "unparseable" \
  "${log48}"

assert_contains \
  "prose is rendered from structured_output for downstream consumers" \
  "SEVERITY: BLOCKING" \
  "${log48}"

assert_contains \
  "rendered prose carries the finding's location" \
  "LOCATION: foo.sh:2" \
  "${log48}"

assert_not_contains \
  "rendered log is prose, not a raw JSON blob" \
  '{"verdict"' \
  "${log48}"

# =========================================================
# TESTS 49-54: the FIX_NOW tier (claude-config#443 phase 2, design item 2).
#
# FIX_NOW is PRINTED AT COMMIT TIME AND NOTHING ELSE. The three properties that
# define it, each pinned below because each is a way the tier could rot into
# the next issue firehose:
#   - it never blocks (49, 50)
#   - it is never filed (49)
#   - it is capped at 5, with a count beyond that (51)
# Plus the DETAILS regression fix (53) and the design-mandated pin on the
# user-requested redundant-comment filter (52, 54).
#
# These use explicit structured overrides rather than derived ones: the point
# is the exact severity token, so it must not be inferred from prose.
# =========================================================
echo ""
echo "=== Test 49: a FIX_NOW-only commit exits 0 and files nothing ==="

setup_repo
stage_small_change

MOCK49_DIR="${TMPDIR_TEST}/mock49"
make_mock_claude_by_agent "${MOCK49_DIR}" \
  "VERDICT: PASS

No blocking issues found." \
  "VERDICT: PASS

No blocking issues found." \
  '{"verdict":"PASS","blocking":false,"findings":[{"severity":"FIX_NOW","location":"foo.sh:2","issue":"quote the expansion"},{"severity":"FIX_NOW","location":"foo.sh:3","issue":"remove the unused local"}]}' \
  '{"verdict":"PASS","blocking":false,"findings":[]}'

TEST49_LOG="${TMPDIR_TEST}/test49-review.log"
rm -f "${TEST49_LOG}"

# A stub `gh` on PATH that records every invocation. If any FIX_NOW path ever
# reaches issue filing, this file becomes non-empty and the test fails. A
# filing call is the failure mode the design names explicitly.
GH_STUB_DIR="${TMPDIR_TEST}/ghstub49"
mkdir -p "${GH_STUB_DIR}"
GH_CALLS="${TMPDIR_TEST}/gh-calls-49.txt"
: >"${GH_CALLS}"
cat >"${GH_STUB_DIR}/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${GH_CALLS}"
exit 0
EOF
chmod +x "${GH_STUB_DIR}/gh"

exit_t49=0
t49_stderr="${TMPDIR_TEST}/test49-stderr.txt"
cd "${REPO_DIR}"
PATH="${GH_STUB_DIR}:${PATH}" REVIEW_LOG="${TEST49_LOG}" CLAUDE_CLI="${MOCK49_DIR}/claude" \
  bash "${SUBJECT}" < <(git diff --cached || true) 2>"${t49_stderr}" || exit_t49=$?
cd - >/dev/null

t49_err="$(cat "${t49_stderr}" 2>/dev/null || echo "")"

assert_eq \
  "FIX_NOW-only commit exits 0 (the tier must never block)" \
  "0" \
  "${exit_t49}"

assert_contains \
  "FIX_NOW entries are printed to the author" \
  "foo.sh:2 — quote the expansion" \
  "${t49_err}"

assert_contains \
  "FIX_NOW block is labelled as neither blocking nor filed" \
  "not blocking, not filed" \
  "${t49_err}"

assert_eq \
  "FIX_NOW files NOTHING: no gh invocation at all" \
  "" \
  "$({ grep -c 'issue create' "${GH_CALLS}" 2>/dev/null || true; } | { tr -d ' ' || true; } | { sed 's/^0$//' || true; })"

assert_not_contains \
  "a FIX_NOW finding never renders a SEVERITY line into the prose block" \
  "SEVERITY: FIX_NOW" \
  "$(cat "${TEST49_LOG}" 2>/dev/null || true)"

# =========================================================
# TEST 50: FIX_NOW alongside a real BLOCKING finding still blocks.
#
# The tier must not dilute the gate: mixing a mechanical fix into a blocking
# response must not turn the block into a pass.
# =========================================================
echo ""
echo "=== Test 50: FIX_NOW does not dilute a real BLOCKING finding ==="

setup_repo
stage_small_change

MOCK50_DIR="${TMPDIR_TEST}/mock50"
make_mock_claude_by_agent "${MOCK50_DIR}" \
  "VERDICT: FAIL

ISSUE: Command injection
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Unquoted expansion reaches a shell command." \
  "VERDICT: FAIL

ISSUE: Command injection
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Unquoted expansion reaches a shell command." \
  '{"verdict":"FAIL","blocking":true,"findings":[{"severity":"BLOCKING","location":"foo.sh:2","issue":"Command injection","details":"Unquoted expansion reaches a shell command."},{"severity":"FIX_NOW","location":"foo.sh:9","issue":"drop the redundant comment"}]}' \
  '{"verdict":"FAIL","blocking":true,"findings":[{"severity":"BLOCKING","location":"foo.sh:2","issue":"Command injection","details":"Unquoted expansion reaches a shell command."}]}'

TEST50_LOG="${TMPDIR_TEST}/test50-review.log"
rm -f "${TEST50_LOG}"

exit_t50=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST50_LOG}" CLAUDE_CLI="${MOCK50_DIR}/claude" \
  bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t50=$?
cd - >/dev/null

assert_eq \
  "a BLOCKING finding still blocks when a FIX_NOW rides along" \
  "1" \
  "${exit_t50}"

# =========================================================
# TEST 51: the cap. More than FIX_NOW_MAX entries prints a COUNT, not a wall.
# =========================================================
echo ""
echo "=== Test 51: more than 5 FIX_NOW entries print a count, not a wall ==="

setup_repo
stage_small_change

MOCK51_DIR="${TMPDIR_TEST}/mock51"
make_mock_claude_by_agent "${MOCK51_DIR}" \
  "VERDICT: PASS

No blocking issues found." \
  "VERDICT: PASS

No blocking issues found." \
  '{"verdict":"PASS","blocking":false,"findings":[{"severity":"FIX_NOW","location":"foo.sh:1","issue":"fix one"},{"severity":"FIX_NOW","location":"foo.sh:2","issue":"fix two"},{"severity":"FIX_NOW","location":"foo.sh:3","issue":"fix three"},{"severity":"FIX_NOW","location":"foo.sh:4","issue":"fix four"},{"severity":"FIX_NOW","location":"foo.sh:5","issue":"fix five"},{"severity":"FIX_NOW","location":"foo.sh:6","issue":"fix six"},{"severity":"FIX_NOW","location":"foo.sh:7","issue":"fix seven"}]}' \
  '{"verdict":"PASS","blocking":false,"findings":[]}'

TEST51_LOG="${TMPDIR_TEST}/test51-review.log"
rm -f "${TEST51_LOG}"

exit_t51=0
t51_stderr="${TMPDIR_TEST}/test51-stderr.txt"
cd "${REPO_DIR}"
REVIEW_LOG="${TEST51_LOG}" CLAUDE_CLI="${MOCK51_DIR}/claude" \
  bash "${SUBJECT}" < <(git diff --cached || true) 2>"${t51_stderr}" || exit_t51=$?
cd - >/dev/null

t51_err="$(cat "${t51_stderr}" 2>/dev/null || echo "")"

assert_eq \
  "an over-cap FIX_NOW batch still exits 0" \
  "0" \
  "${exit_t51}"

assert_contains \
  "over the cap, a count is printed" \
  "7 mechanical fixes suggested" \
  "${t51_err}"

assert_not_contains \
  "over the cap, individual entries are NOT listed" \
  "foo.sh:7 — fix seven" \
  "${t51_err}"

# =========================================================
# TEST 52: THE DESIGN-MANDATED PIN on the redundant-comment filter.
#
# Item 5 of the commit prompt ("flag comments that only restate what the code
# already says") exists by DIRECT USER REQUEST, not reviewer drift. The design
# requires pinning it with a test so a later noise-reduction pass cannot
# quietly delete it.
#
# Two halves, both required:
#   (a) the prompt still instructs the reviewer to flag such comments, and
#       routes them to FIX_NOW rather than BLOCKING;
#   (b) a diff whose comment restates its line produces a FIX_NOW entry,
#       exit 0, and no filing call.
# =========================================================
echo ""
echo "=== Test 52: the redundant-comment filter survives and routes to FIX_NOW ==="

# Scope the assertion to EACH prompt independently. A whole-file grep is NOT a
# pin here: the identical line appears in both the commit prompt and the
# chunked per-file prompt, so deleting it from one still matches the other.
# The first version of this test did exactly that and survived a sabotage run
# that removed the filter from the commit prompt. Counting the sites is what
# makes the pin real.
subject_src="$(cat "${SUBJECT}")"

filter_sites=$(grep -c "flag comments that only restate what the code already says" "${SUBJECT}" | tr -d ' ')
routed_sites=$(grep -c "Report these as SEVERITY: FIX_NOW, never as BLOCKING." "${SUBJECT}" | tr -d ' ')

# Both the commit prompt (single-pass) and the chunked per-file prompt carry
# it, because either can be the one that reviews a given commit.
assert_eq \
  "PIN: the redundant-comment filter is present in BOTH the commit and chunked prompts" \
  "2" \
  "${filter_sites}"

assert_eq \
  "PIN: both copies route the filter explicitly to FIX_NOW" \
  "2" \
  "${routed_sites}"

# And it must never be routed to BLOCKING: a redundant comment stopping a
# commit is the failure mode that made this filter look like noise.
assert_not_contains \
  "PIN: the filter is never routed to BLOCKING" \
  "restate what the code already says. Report these as SEVERITY: BLOCKING" \
  "${subject_src}"

# =========================================================
# TEST 53: a diff whose comment restates its line — the live-shaped half of
# the design-mandated pin. FIX_NOW entry, exit 0, no filing call.
# =========================================================
echo ""
echo "=== Test 53: a redundant comment yields FIX_NOW, exit 0, no filing ==="

setup_repo
cd "${REPO_DIR}"
# The canonical case: a comment that says exactly what its line already says.
printf '%s\n' '# increment the counter' "counter=\$((counter + 1))" >>foo.sh
git add foo.sh
cd - >/dev/null

MOCK53_DIR="${TMPDIR_TEST}/mock53"
make_mock_claude_by_agent "${MOCK53_DIR}" \
  "VERDICT: PASS

No blocking issues found." \
  "VERDICT: PASS

No blocking issues found." \
  '{"verdict":"PASS","blocking":false,"findings":[{"severity":"FIX_NOW","location":"foo.sh:2","issue":"delete the comment restating the increment"}]}' \
  '{"verdict":"PASS","blocking":false,"findings":[]}'

TEST53_LOG="${TMPDIR_TEST}/test53-review.log"
rm -f "${TEST53_LOG}"

GH_STUB53_DIR="${TMPDIR_TEST}/ghstub53"
mkdir -p "${GH_STUB53_DIR}"
GH_CALLS53="${TMPDIR_TEST}/gh-calls-53.txt"
: >"${GH_CALLS53}"
cat >"${GH_STUB53_DIR}/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${GH_CALLS53}"
exit 0
EOF
chmod +x "${GH_STUB53_DIR}/gh"

exit_t53=0
t53_stderr="${TMPDIR_TEST}/test53-stderr.txt"
cd "${REPO_DIR}"
PATH="${GH_STUB53_DIR}:${PATH}" REVIEW_LOG="${TEST53_LOG}" CLAUDE_CLI="${MOCK53_DIR}/claude" \
  bash "${SUBJECT}" < <(git diff --cached || true) 2>"${t53_stderr}" || exit_t53=$?
cd - >/dev/null

t53_err="$(cat "${t53_stderr}" 2>/dev/null || echo "")"

assert_eq \
  "PIN: a redundant-comment finding does not block the commit" \
  "0" \
  "${exit_t53}"

assert_contains \
  "PIN: a redundant-comment finding is printed as a FIX_NOW entry" \
  "delete the comment restating the increment" \
  "${t53_err}"

assert_eq \
  "PIN: a redundant-comment finding is never filed" \
  "" \
  "$({ grep -c 'issue create' "${GH_CALLS53}" 2>/dev/null || true; } | { tr -d ' ' || true; } | { sed 's/^0$//' || true; })"

# =========================================================
# TEST 54: DETAILS renders from `details`, not as a repeat of ISSUE.
#
# The live regression measured after #444 merged: the phase-1 finding was
# {severity, location, issue} with no `details`, so every rendered finding read
#   ISSUE:   Hardcoded AWS secret access key committed to source
#   DETAILS: Hardcoded AWS secret access key committed to source
# Under the prose contract DETAILS carried the explanation AND the fix.
# =========================================================
echo ""
echo "=== Test 54: DETAILS renders distinctly from ISSUE ==="

setup_repo
stage_small_change

MOCK54_DIR="${TMPDIR_TEST}/mock54"
mkdir -p "${MOCK54_DIR}"
# The real CLI's tool-call shape: .result is the SERIALIZED object, no prose,
# so the VERDICT block is rendered out of .structured_output (cf. Test 48).
cat >"${MOCK54_DIR}/envelope.json" <<'MOCK54JSON'
{"type":"result","subtype":"success","is_error":false,
 "result":"{\"verdict\":\"FAIL\",\"blocking\":true,\"findings\":[{\"severity\":\"BLOCKING\",\"location\":\"foo.sh:3\",\"issue\":\"Hardcoded AWS secret access key committed to source\",\"details\":\"Move the key to an environment variable and rotate the exposed credential.\"}]}",
 "structured_output":{"verdict":"FAIL","blocking":true,"findings":[{"severity":"BLOCKING","location":"foo.sh:3","issue":"Hardcoded AWS secret access key committed to source","details":"Move the key to an environment variable and rotate the exposed credential."}]}}
MOCK54JSON
cat >"${MOCK54_DIR}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
cat "${MOCK54_DIR}/envelope.json"
exit 0
EOF
chmod +x "${MOCK54_DIR}/claude"

TEST54_LOG="${TMPDIR_TEST}/test54-review.log"
rm -f "${TEST54_LOG}"

exit_t54=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST54_LOG}" CLAUDE_CLI="${MOCK54_DIR}/claude" \
  bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t54=$?
cd - >/dev/null

log54="$(cat "${TEST54_LOG}" 2>/dev/null || echo "")"

assert_contains \
  "DETAILS carries the explanation and fix, not a repeat of ISSUE" \
  "DETAILS: Move the key to an environment variable and rotate the exposed credential." \
  "${log54}"

assert_not_contains \
  "DETAILS is no longer a verbatim repeat of ISSUE" \
  "DETAILS: Hardcoded AWS secret access key committed to source" \
  "${log54}"

assert_eq \
  "the blocking finding still blocks with details present" \
  "1" \
  "${exit_t54}"

# =========================================================
# TEST 55: the renderer EXCLUDES FIX_NOW from the prose block.
#
# Test 49 asserts this, but its mock puts prose in `.result`, and the renderer
# is skipped whenever `.result` already carries a VERDICT line. So the code
# under assertion never ran: deleting the exclusion from the renderer left the
# whole suite green.
#
# This test drives the REAL CLI shape (`.result` = serialized object, no
# prose), which forces the renderer to run. A FIX_NOW finding must not appear
# in the rendered VERDICT/ISSUE/SEVERITY block. That block is what
# has_blocking_severity() reads and what lib-review-issues.sh files from, so a
# leak here would turn every mechanical suggestion into a GitHub issue -- the
# exact firehose the FIX_NOW tier exists to prevent.
# =========================================================
echo ""
echo "=== Test 55: renderer excludes FIX_NOW from the prose block ==="

setup_repo
stage_small_change

MOCK55_DIR="${TMPDIR_TEST}/mock55"
make_mock_claude_structured_only "${MOCK55_DIR}" \
  '{"verdict":"PASS","blocking":false,"findings":[{"severity":"FIX_NOW","location":"foo.sh:2","issue":"quote the expansion","details":"add quotes"},{"severity":"WARNING","location":"foo.sh:5","issue":"minor nit","details":"n/a"}]}' \
  '{"verdict":"PASS","blocking":false,"findings":[]}'

GH_STUB55="${TMPDIR_TEST}/ghstub55"
mkdir -p "${GH_STUB55}"
GH_CALLS55="${TMPDIR_TEST}/gh-calls-55.txt"
: >"${GH_CALLS55}"
cat >"${GH_STUB55}/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${GH_CALLS55}"
exit 0
EOF
chmod +x "${GH_STUB55}/gh"

TEST55_LOG="${TMPDIR_TEST}/test55-review.log"
rm -f "${TEST55_LOG}"
exit_t55=0
cd "${REPO_DIR}"
PATH="${GH_STUB55}:${PATH}" REVIEW_LOG="${TEST55_LOG}" CLAUDE_CLI="${MOCK55_DIR}/claude" \
  bash "${SUBJECT}" < <(git diff --cached || true) >/dev/null 2>&1 || exit_t55=$?
cd - >/dev/null

log55="$(cat "${TEST55_LOG}" 2>/dev/null || echo "")"

# The control: prove the renderer actually ran for this mock. Without this a
# clean result could mean "excluded correctly" OR "rendered nothing at all",
# and those are not the same outcome.
assert_contains \
  "control: the renderer ran and emitted the non-FIX_NOW finding" \
  "SEVERITY: WARNING" \
  "${log55}"

assert_not_contains \
  "renderer never emits SEVERITY: FIX_NOW into the prose block" \
  "SEVERITY: FIX_NOW" \
  "${log55}"

assert_eq \
  "a FIX_NOW-only-plus-warning review still exits 0" \
  "0" \
  "${exit_t55}"

# Assign through a local first: a `grep | tr | sed` pipeline inside the
# assertion masks each stage's exit status (SC2312).
gh55_calls=0
if [[ -s "${GH_CALLS55}" ]]; then
  gh55_calls=$(grep -c 'issue create' "${GH_CALLS55}" || true)
fi

assert_eq \
  "renderer path files nothing" \
  "0" \
  "${gh55_calls}"

echo "=== Test 56: a non-boolean blocking field does not discard the verdict (#450) ==="

# Regression for smartwatermelon/claude-config#450. When the reviewer honors the
# schema's verdict but not its blocking boolean, and .result carries narration
# rather than a VERDICT block, normalize_agent_response used to print .result
# alone and drop .structured_output.verdict. The gate then saw bare prose,
# parse_verdict returned "", and a clean PASS hard-blocked the commit with
# "Could not parse code-reviewer verdict".

setup_repo
stage_small_change

MOCK56_DIR="${TMPDIR_TEST}/mock56"
make_mock_claude_nonboolean_blocking "${MOCK56_DIR}" \
  '{"verdict":"PASS","blocking":"false","findings":[]}' \
  'I reviewed the diff. The changes are clean and correct.' \
  '{"verdict":"PASS","blocking":false,"findings":[]}'

TEST56_LOG="${TMPDIR_TEST}/test56-review.log"
rm -f "${TEST56_LOG}"
exit_t56=0
t56_stderr="${TMPDIR_TEST}/test56-stderr.txt"
cd "${REPO_DIR}"
REVIEW_LOG="${TEST56_LOG}" CLAUDE_CLI="${MOCK56_DIR}/claude" \
  bash "${SUBJECT}" < <(git diff --cached || true) >/dev/null 2>"${t56_stderr}" || exit_t56=$?
cd - >/dev/null

t56_err="$(cat "${t56_stderr}" 2>/dev/null || echo "")"

assert_eq \
  "#450: a PASS with a non-boolean blocking field exits 0" \
  "0" \
  "${exit_t56}"

assert_not_contains \
  "#450: the gate does not report the verdict as unparseable" \
  "Could not parse code-reviewer verdict" \
  "${t56_err}"

assert_contains \
  "control: the code-reviewer mock was invoked" \
  "completed in" \
  "${t56_err}"

echo "=== Test 57: a non-boolean blocking field still fails closed on BLOCKING prose (#450) ==="

# The other half of #450's fix: recovering the verdict must NOT hand the gate a
# structured decision the reviewer never made. With no boolean, output_blocks()
# must still fall back to has_blocking_severity() over the prose.
#
# The adversarial reviewer FAILs here too, deliberately. A PASS from it would
# put the run on the disagreement/arbitration path, and this test would then be
# measuring the arbiter rather than the fallback it names.

setup_repo
stage_small_change

MOCK57_DIR="${TMPDIR_TEST}/mock57"
make_mock_claude_nonboolean_blocking "${MOCK57_DIR}" \
  '{"verdict":"FAIL","blocking":"true","findings":[]}' \
  'ISSUE: a real defect
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: this breaks under set -e' \
  '{"verdict":"FAIL","blocking":true,"findings":[{"severity":"BLOCKING","location":"foo.sh:2","issue":"a real defect","details":"this breaks under set -e"}]}'

TEST57_LOG="${TMPDIR_TEST}/test57-review.log"
rm -f "${TEST57_LOG}"
exit_t57=0
t57_stderr="${TMPDIR_TEST}/test57-stderr.txt"
cd "${REPO_DIR}"
REVIEW_LOG="${TEST57_LOG}" CLAUDE_CLI="${MOCK57_DIR}/claude" \
  bash "${SUBJECT}" < <(git diff --cached || true) >/dev/null 2>"${t57_stderr}" || exit_t57=$?
cd - >/dev/null

t57_err="$(cat "${t57_stderr}" 2>/dev/null || echo "")"

# Assign through a local first: the suite has no assert_ne, and comparing a
# derived "blocked/passed" word reads better in the output than a raw code.
t57_blocked="passed"
if [[ "${exit_t57}" -ne 0 ]]; then
  t57_blocked="blocked"
fi

assert_eq \
  "#450: a FAIL with BLOCKING prose and no boolean still blocks" \
  "blocked" \
  "${t57_blocked}"

# Assert the REASON, not just the exit code. Without this the test passes on
# the unfixed code too -- which blocks this input, but for the wrong reason
# ("unparseable verdict") -- and so cannot tell "the fail-closed fallback
# worked" from "the verdict was never recovered at all".
assert_not_contains \
  "#450: ...and blocks because of the finding, not an unparseable verdict" \
  "Could not parse code-reviewer verdict" \
  "${t57_err}"

echo "=== Test 58: a serialized-object .result with FAIL+BLOCKING must not fail open (#450) ==="

# The hole the first attempt at #450's fix opened. `.result` here is the
# SERIALIZED OBJECT -- the normal shape under --json-schema per
# normalize_agent_response's own header -- and only the `blocking` field's TYPE
# is wrong. Prepending a `VERDICT: FAIL` line onto that JSON left
# has_blocking_severity() with `"severity":"BLOCKING"` to match, which its
# pattern cannot do (the quote sits between the colon and the keyword). The
# gate saw FAIL with no blocking finding and exited 0 -- a silent pass on a
# review that said BLOCKING, where the pre-#450 code hard-blocked.

setup_repo
stage_small_change

MOCK58_DIR="${TMPDIR_TEST}/mock58"
MOCK58_SO='{"verdict":"FAIL","blocking":"true","findings":[{"severity":"BLOCKING","location":"foo.sh:2","issue":"a real defect","details":"this breaks under set -e"}]}'
# Assign through a local first: a command substitution inside the argument list
# masks jq's exit status (SC2312).
MOCK58_PROSE=$(jq -nr --argjson so "${MOCK58_SO}" '$so|tojson')
make_mock_claude_nonboolean_blocking "${MOCK58_DIR}" \
  "${MOCK58_SO}" \
  "${MOCK58_PROSE}" \
  "${MOCK58_SO}"

TEST58_LOG="${TMPDIR_TEST}/test58-review.log"
rm -f "${TEST58_LOG}"
exit_t58=0
t58_stderr="${TMPDIR_TEST}/test58-stderr.txt"
cd "${REPO_DIR}"
REVIEW_LOG="${TEST58_LOG}" CLAUDE_CLI="${MOCK58_DIR}/claude" \
  bash "${SUBJECT}" < <(git diff --cached || true) >/dev/null 2>"${t58_stderr}" || exit_t58=$?
cd - >/dev/null

t58_err="$(cat "${t58_stderr}" 2>/dev/null || echo "")"

t58_blocked="passed"
if [[ "${exit_t58}" -ne 0 ]]; then
  t58_blocked="blocked"
fi

assert_eq \
  "#450: a serialized-object FAIL+BLOCKING with a string boolean still blocks" \
  "blocked" \
  "${t58_blocked}"

assert_not_contains \
  "#450: ...and does so on the finding, not an unparseable verdict" \
  "Could not parse code-reviewer verdict" \
  "${t58_err}"

t58_log="$(cat "${TEST58_LOG}" 2>/dev/null || echo "")"

assert_contains \
  "control: the renderer emitted a matchable SEVERITY: BLOCKING line" \
  "SEVERITY: BLOCKING" \
  "${t58_log}"

# =========================================================
# Summary
# =========================================================
echo ""
echo "======================================="
echo "Results: ${PASS} passed, ${FAIL} failed (of $((PASS + FAIL)) assertions)"
echo "======================================="

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
