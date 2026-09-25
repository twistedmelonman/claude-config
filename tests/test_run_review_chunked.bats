#!/usr/bin/env bats
# Tests for the chunked (medium-diff) path of hooks/run-review.sh:
# perform_chunked_review, which runs when a commit-mode diff is larger than
# review.maxLines but not larger than review.skipThreshold.
#
# Two false passes lived here:
#
#   claude-config#451 — a file whose diff was larger than review.chunkSize was
#     skipped, and the run still printed "Chunked review passed". On a large
#     diff the big new file is the one most likely to be skipped, so the
#     review read the docs and passed the code unread.
#   claude-config#558 — the chunked path only ever called code-reviewer.
#     adversarial-reviewer never ran, and nothing in the output or the review
#     log said so.
#
# Fixtures are kept tiny by lowering maxLines/chunkSize in the temp repo.
#
# Run: bats tests/test_run_review_chunked.bats

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
  touch "${TMPDIR_TEST}/init.txt"
  git -C "${TMPDIR_TEST}" add init.txt
  GIT_CONFIG_GLOBAL=/dev/null git -C "${TMPDIR_TEST}" commit -q -m "initial commit message"

  # Small thresholds so a ~60-line diff lands in the chunked band.
  git -C "${TMPDIR_TEST}" config review.maxLines 50
  git -C "${TMPDIR_TEST}" config review.chunkSize 30

  export EXPECTED_LOG="${TMPDIR_TEST}/.git/last-review-result.log"

  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR

  # Fake HOME: run-review.sh decides whether adversarial-reviewer is installed
  # by looking under ${HOME}/.claude/plugins/marketplaces, and writes a global
  # log pointer under ${HOME}/.claude. Both must be deterministic and must not
  # touch the real home directory.
  FAKE_HOME="${MOCK_DIR}/home"
  export FAKE_HOME
  mkdir -p "${FAKE_HOME}/.claude/plugins/marketplaces/test/agents"
  touch "${FAKE_HOME}/.claude/plugins/marketplaces/test/agents/adversarial-reviewer.md"

  # Mock claude CLI. Records every --agent it is asked to run, one per line
  # (append-only, so parallel invocations do not clobber each other). Returns
  # PASS unless ${MOCK_DIR}/fail-<agent> exists, in which case that agent
  # returns a BLOCKING FAIL, or ${MOCK_DIR}/error-<agent> exists, in which
  # case the CLI exits 1 with no output (an agent error).
  export AGENT_RECORD="${MOCK_DIR}/agents-invoked"
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
printf '%s\n' "\${agent}" >>"${AGENT_RECORD}"
cat >/dev/null
[[ -f "${MOCK_DIR}/error-\${agent}" ]] && exit 1
if [[ -f "${MOCK_DIR}/fail-\${agent}" ]]; then
  jq -n '{type:"result",subtype:"success",is_error:false,
          result:"VERDICT: FAIL\nISSUE: mock blocking issue\nSEVERITY: BLOCKING\nLOCATION: x:1\nDETAILS: mock",
          structured_output:{verdict:"FAIL",blocking:true,
            findings:[{severity:"BLOCKING",location:"x:1",issue:"mock blocking issue"}]}}'
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

# Write a shell file of N lines into the temp repo.
_write_file() {
  local path="$1" lines="$2" i
  : >"${TMPDIR_TEST}/${path}"
  for ((i = 0; i < lines; i += 1)); do
    printf 'echo "line %d"\n' "${i}" >>"${TMPDIR_TEST}/${path}"
  done
}

# run-review.sh reads the staged index of its own working directory, so it is
# launched from inside the temp repo, in a subshell so the directory change
# cannot leak. GIT_CONFIG_GLOBAL=/dev/null keeps the developer's own review.*
# keys out of the routing decision.
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

# --- #451: a skipped file must never produce a pass --------------------------

@test "#451: a file larger than chunkSize blocks the commit instead of passing unread" {
  _write_file "big.sh" 40   # ~45 diff lines > chunkSize 30
  _write_file "small.sh" 20 # ~25 diff lines, reviewed
  git -C "${TMPDIR_TEST}" add big.sh small.sh

  run _run_review
  [ "$status" -ne 0 ]
  [[ "$output" != *"Chunked review passed"* ]]
  # The unreviewed file is named, with the remedy.
  [[ "$output" == *"big.sh"* ]]
  [[ "$output" == *"review.chunkSize"* ]]
  grep -q 'unreviewed: big.sh' "${EXPECTED_LOG}"
  grep -q 'chunked: INCOMPLETE' "${EXPECTED_LOG}"
}

@test "#451: raising chunkSize past the largest file lets the same diff pass" {
  _write_file "big.sh" 40
  _write_file "small.sh" 20
  git -C "${TMPDIR_TEST}" add big.sh small.sh
  git -C "${TMPDIR_TEST}" config review.chunkSize 100

  run _run_review
  [ "$status" -eq 0 ]
  [[ "$output" == *"Chunked review passed"* ]]
  ! grep -q 'unreviewed:' "${EXPECTED_LOG}"
}

@test "#451: a per-file agent error blocks and names the file" {
  _write_file "a.sh" 20
  _write_file "b.sh" 20
  _write_file "c.sh" 20
  git -C "${TMPDIR_TEST}" add a.sh b.sh c.sh
  # code-reviewer errors on every file; adversarial passes. Previously the
  # 0/N case blocked (#200) but any partial case passed; now all do.
  cat >"${MOCK_DIR}/claude" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == "--version" ]] && { echo mock; exit 0; }; done
input=\$(cat)
if [[ "\$input" == *"Reviewing file: b.sh"* ]]; then exit 1; fi
jq -n '{type:"result",subtype:"success",is_error:false,
        result:"VERDICT: PASS",structured_output:{verdict:"PASS",blocking:false,findings:[]}}'
EOF

  run _run_review
  [ "$status" -ne 0 ]
  [[ "$output" != *"Chunked review passed"* ]]
  grep -q 'unreviewed: b.sh (agent error or timeout)' "${EXPECTED_LOG}"
  ! grep -q 'unreviewed: a.sh' "${EXPECTED_LOG}"
}

@test "#451: the skipThreshold block message also names review.chunkSize" {
  git -C "${TMPDIR_TEST}" config review.skipThreshold 60
  _write_file "big.sh" 80
  git -C "${TMPDIR_TEST}" add big.sh

  run _run_review
  [ "$status" -ne 0 ]
  [[ "$output" == *"review.skipThreshold"* ]]
  [[ "$output" == *"review.chunkSize"* ]]
}

# --- #558: adversarial-reviewer must run (or say it did not) -----------------

@test "#558: chunked review runs adversarial-reviewer and logs its verdict" {
  _write_file "a.sh" 20
  _write_file "b.sh" 20
  _write_file "c.sh" 20
  git -C "${TMPDIR_TEST}" add a.sh b.sh c.sh

  run _run_review
  [ "$status" -eq 0 ]
  grep -qx 'adversarial-reviewer' "${AGENT_RECORD}"
  # Exactly one adversarial pass over the whole diff, not one per file.
  [ "$(grep -cx 'adversarial-reviewer' "${AGENT_RECORD}")" -eq 1 ]
  grep -q '^adversarial-reviewer: PASS' "${EXPECTED_LOG}"
  grep -q '^code-reviewer: PASS' "${EXPECTED_LOG}"
  [[ "$output" == *"code-reviewer + adversarial-reviewer"* ]]
}

@test "#558: a BLOCKING adversarial finding fails a chunked commit" {
  _write_file "a.sh" 20
  _write_file "b.sh" 20
  _write_file "c.sh" 20
  git -C "${TMPDIR_TEST}" add a.sh b.sh c.sh
  touch "${MOCK_DIR}/fail-adversarial-reviewer"

  run _run_review
  [ "$status" -ne 0 ]
  grep -q '^adversarial-reviewer: FAIL' "${EXPECTED_LOG}"
  [[ "$output" == *"adversarial-reviewer found issues"* ]]
}

@test "#558: when adversarial-reviewer is not installed, the skip is loud" {
  rm -rf "${FAKE_HOME}/.claude/plugins"
  _write_file "a.sh" 20
  _write_file "b.sh" 20
  _write_file "c.sh" 20
  git -C "${TMPDIR_TEST}" add a.sh b.sh c.sh

  run _run_review
  [ "$status" -eq 0 ]
  ! grep -qx 'adversarial-reviewer' "${AGENT_RECORD}"
  grep -q '^adversarial-reviewer: skipped (agent not installed)' "${EXPECTED_LOG}"
  [[ "$output" == *"adversarial-reviewer"*"not"* ]]
}

@test "#558: an adversarial-reviewer error is non-blocking but named in output and log" {
  _write_file "a.sh" 20
  _write_file "b.sh" 20
  _write_file "c.sh" 20
  git -C "${TMPDIR_TEST}" add a.sh b.sh c.sh
  touch "${MOCK_DIR}/error-adversarial-reviewer"

  run _run_review
  [ "$status" -eq 0 ]
  grep -q '^adversarial-reviewer: skipped (timeout or agent error)' "${EXPECTED_LOG}"
  [[ "$output" == *"adversarial-reviewer timed out or errored - it did NOT review this commit"* ]]
  [[ "$output" == *"code-reviewer only"* ]]
}
