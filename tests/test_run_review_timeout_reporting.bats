#!/usr/bin/env bats
# Tests for how hooks/run-review.sh reports a reviewer that timed out or
# errored on the whole-diff commit path and the full-diff pre-push path.
#
# claude-config#590: a code-reviewer timeout printed "VERDICT: FAIL (timeout)"
# and "BLOCKING", then "Review passed (code-reviewer + adversarial-reviewer)",
# and logged "code-reviewer: FAIL ... exit_code: 0". The commit went through
# having been reviewed by one reviewer at most, and every surface said it
# passed. It fired on two real commits on 2026-09-24/25.
#
# These tests pin the REPORTING, not the exit code. Transient failures are
# non-blocking by the policy #444 stated ("an unreachable reviewer is not a
# blocking finding"); the chunked path blocks the same timeout (#451). Which
# one is right is the open question on #590. Until it is answered, a reviewer
# that did not run is reported as INCOMPLETE, never as a pass or as warnings.
#
# The mock exits 124 with no output, which is exactly what `timeout` returns
# when it kills the CLI. One case uses a real `timeout` kill as well, so the
# mock is not the only evidence.
#
# Run: bats tests/test_run_review_timeout_reporting.bats

# Resolve the script under test relative to THIS test file, not via
# ${HOME}/.claude/hooks, so a worktree tests its own copy.
SCRIPT="${BATS_TEST_DIRNAME}/../hooks/run-review.sh"

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  export TMPDIR_TEST
  git -C "${TMPDIR_TEST}" init -q
  git -C "${TMPDIR_TEST}" checkout -q -b test-branch
  git -C "${TMPDIR_TEST}" config user.email "test@test.com"
  git -C "${TMPDIR_TEST}" config user.name "Test"
  printf '#!/usr/bin/env bash\n' >"${TMPDIR_TEST}/foo.sh"
  git -C "${TMPDIR_TEST}" add foo.sh
  GIT_CONFIG_GLOBAL=/dev/null git -C "${TMPDIR_TEST}" commit -q -m "initial commit message"

  export EXPECTED_LOG="${TMPDIR_TEST}/.git/last-review-result.log"

  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR

  # Fake HOME, so whether adversarial-reviewer is "installed" is decided here
  # and the real ~/.claude is never written.
  FAKE_HOME="${MOCK_DIR}/home"
  export FAKE_HOME
  mkdir -p "${FAKE_HOME}/.claude/plugins/marketplaces/test/agents"
  touch "${FAKE_HOME}/.claude/plugins/marketplaces/test/agents/adversarial-reviewer.md"

  # Mock claude CLI. PASS by default. ${MOCK_DIR}/timeout-<agent> makes that
  # agent exit 124 with no output; ${MOCK_DIR}/sleep-<agent> makes it sleep
  # past a real `timeout`; ${MOCK_DIR}/fail-<agent> makes it return a
  # BLOCKING FAIL whose DETAILS quote a synthetic timeout verdict.
  cat >"${MOCK_DIR}/claude" <<EOF
#!/usr/bin/env bash
agent=""
prev=""
for a in "\$@"; do
  if [[ "\$a" == "--version" ]]; then
    echo "mock-claude 0.0.1"
    exit 0
  fi
  [[ "\$prev" == "--agent" ]] && agent="\$a"
  prev="\$a"
done
# The code reviewer runs under its plugin-qualified id
# (comprehensive-review:comprehensive-review-code-reviewer); key it short.
[[ "\${agent}" == *code-reviewer ]] && agent=code-reviewer
cat >/dev/null
[[ -f "${MOCK_DIR}/timeout-\${agent}" ]] && exit 124
[[ -f "${MOCK_DIR}/sleep-\${agent}" ]] && exec sleep 10
if [[ -f "${MOCK_DIR}/fail-\${agent}" ]]; then
  # Bare prose (the no-envelope fallback), so the quoted synthetic verdict
  # sits at the start of its own line, where is_transient_verdict() looks.
  printf '%s\n' "VERDICT: FAIL" "ISSUE: real defect" "SEVERITY: BLOCKING" \
    "LOCATION: foo.sh:2" "DETAILS: invoke_agent prints this on a kill:" \
    "VERDICT: FAIL (timeout)"
else
  jq -n '{type:"result",subtype:"success",is_error:false,
          result:"VERDICT: PASS\nNo blocking issues found.",
          structured_output:{verdict:"PASS",blocking:false,findings:[]}}'
fi
EOF
  chmod +x "${MOCK_DIR}/claude"
  export CLAUDE_CLI="${MOCK_DIR}/claude"
}

teardown() {
  rm -rf "${TMPDIR_TEST}" "${MOCK_DIR}"
}

_stage_change() {
  printf 'echo hello\n' >>"${TMPDIR_TEST}/foo.sh"
  git -C "${TMPDIR_TEST}" add foo.sh
}

# Commit mode: run-review.sh reads the staged index of its working directory,
# so it runs from inside the temp repo, in a subshell.
_run_review() {
  local diff
  diff=$(git -C "${TMPDIR_TEST}" diff --cached)
  (
    cd "${TMPDIR_TEST}" || return 1
    printf '%s\n' "${diff}" \
      | HOME="${FAKE_HOME}" REVIEW_LOG="${EXPECTED_LOG}" CLAUDE_CLI="${CLAUDE_CLI}" \
        GIT_CONFIG_GLOBAL=/dev/null bash "${SCRIPT}" "$@"
  )
}

# Full-diff (pre-push) mode: the branch diff arrives on stdin.
_run_full_diff() {
  _stage_change
  GIT_CONFIG_GLOBAL=/dev/null git -C "${TMPDIR_TEST}" commit -q -m "branch change"
  local diff
  diff=$(git -C "${TMPDIR_TEST}" diff HEAD~1 HEAD)
  (
    cd "${TMPDIR_TEST}" || return 1
    printf '%s\n' "${diff}" \
      | HOME="${FAKE_HOME}" REVIEW_LOG="${EXPECTED_LOG}" CLAUDE_CLI="${CLAUDE_CLI}" \
        GIT_CONFIG_GLOBAL=/dev/null bash "${SCRIPT}" --mode=full-diff
  )
}

# --- whole-diff commit path: code-reviewer did not complete ---------------

@test "#590: code-reviewer timeout + adversarial PASS is never reported as passed" {
  _stage_change
  touch "${MOCK_DIR}/timeout-code-reviewer"

  run _run_review
  # Exit code unchanged: transient failures are non-blocking (#444).
  [ "$status" -eq 0 ]
  [[ "$output" != *"Review passed"* ]]
  [[ "$output" == *"Review INCOMPLETE"* ]]
  [[ "$output" == *"code-reviewer did NOT complete (timeout)"* ]]
  # invoke_agent no longer claims a block the caller does not enforce.
  [[ "$output" != *"BLOCKING: Review timeout"* ]]
  grep -qx 'code-reviewer: INCOMPLETE (timeout)' "${EXPECTED_LOG}"
  ! grep -q '^code-reviewer: FAIL' "${EXPECTED_LOG}"
  grep -q '^review: INCOMPLETE' "${EXPECTED_LOG}"
  grep -qx 'adversarial-reviewer: PASS' "${EXPECTED_LOG}"
}

@test "#590: a real timeout kill (review.timeout=1) is reported the same way" {
  _stage_change
  git -C "${TMPDIR_TEST}" config review.timeout 1
  touch "${MOCK_DIR}/sleep-code-reviewer"

  run _run_review
  [ "$status" -eq 0 ]
  [[ "$output" != *"Review passed"* ]]
  grep -qx 'code-reviewer: INCOMPLETE (timeout)' "${EXPECTED_LOG}"
}

@test "#590: code-reviewer timeout with no adversarial-reviewer says nothing reviewed" {
  rm -rf "${FAKE_HOME}/.claude/plugins"
  _stage_change
  touch "${MOCK_DIR}/timeout-code-reviewer"

  run _run_review
  [ "$status" -eq 0 ]
  [[ "$output" != *"Review passed"* ]]
  [[ "$output" == *"was NOT reviewed"* ]]
  grep -qx 'code-reviewer: INCOMPLETE (timeout)' "${EXPECTED_LOG}"
}

@test "#590: both reviewers timing out says nothing reviewed" {
  _stage_change
  touch "${MOCK_DIR}/timeout-code-reviewer" "${MOCK_DIR}/timeout-adversarial-reviewer"

  run _run_review
  [ "$status" -eq 0 ]
  [[ "$output" != *"Review passed"* ]]
  [[ "$output" == *"was NOT reviewed"* ]]
  grep -qx 'code-reviewer: INCOMPLETE (timeout)' "${EXPECTED_LOG}"
  grep -qx 'adversarial-reviewer: skipped (timeout or agent error)' "${EXPECTED_LOG}"
}

# --- whole-diff commit path: adversarial-reviewer did not complete ---------

@test "#590: adversarial timeout does not claim both reviewers passed" {
  _stage_change
  touch "${MOCK_DIR}/timeout-adversarial-reviewer"

  run _run_review
  [ "$status" -eq 0 ]
  [[ "$output" != *"code-reviewer + adversarial-reviewer"* ]]
  [[ "$output" == *"code-reviewer only"* ]]
  grep -qx 'code-reviewer: PASS' "${EXPECTED_LOG}"
  # Same log wording as the chunked path (#588).
  grep -qx 'adversarial-reviewer: skipped (timeout or agent error)' "${EXPECTED_LOG}"
}

# --- the relabel must never weaken a real block -----------------------------

@test "#590: a real BLOCKING code-reviewer finding that quotes a timeout verdict still blocks" {
  _stage_change
  # Both fail: with adversarial PASS the arbiter (also mocked PASS) would rule.
  touch "${MOCK_DIR}/fail-code-reviewer" "${MOCK_DIR}/fail-adversarial-reviewer"

  run _run_review
  [ "$status" -ne 0 ]
  [[ "$output" != *"INCOMPLETE"* ]]
  grep -qx 'code-reviewer: FAIL' "${EXPECTED_LOG}"
}

@test "#590: a real BLOCKING adversarial finding that quotes a timeout verdict still blocks" {
  # origin/main tested for the synthetic string BEFORE the severity gate, so
  # this finding was waved through as "timed out or errored".
  _stage_change
  touch "${MOCK_DIR}/fail-adversarial-reviewer"

  run _run_review
  [ "$status" -ne 0 ]
  [[ "$output" == *"adversarial-reviewer found issues"* ]]
  grep -qx 'adversarial-reviewer: FAIL' "${EXPECTED_LOG}"
}

# --- full-diff pre-push path -------------------------------------------------

@test "#590: full-diff timeout is logged INCOMPLETE, not 'warnings only'" {
  touch "${MOCK_DIR}/timeout-adversarial-reviewer"

  run _run_full_diff
  [ "$status" -eq 0 ]
  [[ "$output" != *"found warnings"* ]]
  [[ "$output" == *"Full-diff review INCOMPLETE"* ]]
  grep -qx 'full-diff: INCOMPLETE (timeout)' "${EXPECTED_LOG}"
  ! grep -q 'full-diff: FAIL (warnings only)' "${EXPECTED_LOG}"
}

@test "#590: full-diff agent error is logged INCOMPLETE (agent error)" {
  cat >"${MOCK_DIR}/claude" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == "--version" ]] && { echo mock; exit 0; }; done
cat >/dev/null
exit 1
EOF

  run _run_full_diff
  [ "$status" -eq 0 ]
  grep -qx 'full-diff: INCOMPLETE (agent error)' "${EXPECTED_LOG}"
}
