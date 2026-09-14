#!/usr/bin/env bats
# Tests for ~/.local/bin/gh binary wrapper
#
# Verifies the _GH_REVIEW_DONE guard prevents double review when this binary
# wrapper is called from the gh() bash function, which already ran the review.
#
# Root cause of double review on dotfiles PR #4:
#   1. gh() bash function (functions.sh) intercepts "gh pr merge" → runs review
#   2. gh() calls "command gh" which resolves to ~/.local/bin/gh (a bash script)
#   3. That script also intercepts "pr merge" → runs review AGAIN
#
# Fix: gh() sets _GH_REVIEW_DONE=1 before calling "command gh"; this script
# checks it and skips the review when the review has already been done.
#
# Run: bats ~/.claude/tests/test_gh_binary_wrapper.bats

GH_WRAPPER="${HOME}/.local/bin/gh"

setup() {
  # GH_TOKEN must be unset for the whole test file. The wrapper refuses to run
  # whenever GH_TOKEN is set and it cannot resolve that token to a login
  # (the GH_TOKEN identity gate); resolution calls a real `gh api user`, which the
  # PATH stub below answers with a bare `exit 0`. No login comes back, so the
  # refusal fires before any test reaches the _GH_REVIEW_DONE logic it means
  # to exercise. The wrapper prescribes this remedy directly: "If it is a test
  # stub, unset GH_TOKEN for the test so this check is skipped."
  #
  # Note the tests here run the wrapper via `env HOME=...`, which inherits the
  # caller's environment -- so clearing GH_TOKEN in setup() is what reaches the
  # subprocess. See the matching comment in test_gh_wrapper.bats.
  unset GH_TOKEN

  # The wrapper's review-script location is an exported override
  # (_gh_wrapper_review_script). If the developer's interactive shell exported
  # it -- and sourcing gh-wrapper.sh does exactly that -- bats inherits the
  # value, and it wins over the sandboxed HOME below. The mock hook would then
  # be ignored in favour of the real one, which fails for reasons unrelated to
  # anything under test. Unset it so HOME is genuinely the only input.
  # See smartwatermelon/dotfiles#222 and #360.
  unset _gh_wrapper_review_script

  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  export PATH="${MOCK_DIR}:${PATH}"

  # Mock "real" gh binary — _find_real_gh() in the wrapper will find this
  # (it's not ~/.local/bin/gh, so it passes the realpath check)
  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  # Mock HOME with a review script that records its calls
  MOCK_HOME="${MOCK_DIR}/home"
  export MOCK_HOME
  mkdir -p "${MOCK_HOME}/.claude/hooks"

  # review_called is created only if the review script runs.
  # Tests asserting review bypass will check it does NOT exist.
  cat >"${MOCK_HOME}/.claude/hooks/pre-merge-review.sh" <<EOF
#!/usr/bin/env bash
echo "called" >"${MOCK_DIR}/review_called"
exit 0
EOF
  chmod +x "${MOCK_HOME}/.claude/hooks/pre-merge-review.sh"
}

teardown() {
  rm -rf "${MOCK_DIR}"
}

@test "gh pr merge skips review when _GH_REVIEW_DONE=1" {
  # Regression guard for double-review bug:
  # When the gh() bash function already ran the review and then calls "command gh",
  # this binary wrapper must NOT run the review a second time.
  run env HOME="${MOCK_HOME}" _GH_REVIEW_DONE=1 "${GH_WRAPPER}" pr merge 53 --squash

  [[ ! -f "${MOCK_DIR}/review_called" ]]
}

@test "gh pr merge calls review when _GH_REVIEW_DONE is unset" {
  # Normal path: binary wrapper called directly (not via gh() function).
  # Review must still run when no guard is set.
  run env HOME="${MOCK_HOME}" "${GH_WRAPPER}" pr merge 53 --squash

  [[ -f "${MOCK_DIR}/review_called" ]]
}

@test "gh status never calls review" {
  # Non-pr-merge commands must never trigger the review, with or without guard.
  run env HOME="${MOCK_HOME}" "${GH_WRAPPER}" status

  [[ ! -f "${MOCK_DIR}/review_called" ]]
}

# ── Global-flag bypass tests ─────────────────────────────────────────────────
# Regression for: gh -R owner/repo pr merge bypasses the $1=='pr' check.

@test "gh -R owner/repo pr merge calls review when _GH_REVIEW_DONE is unset" {
  run env HOME="${MOCK_HOME}" "${GH_WRAPPER}" -R owner/repo pr merge 53 --squash

  [[ -f "${MOCK_DIR}/review_called" ]]
}

@test "gh -R owner/repo pr merge skips review when _GH_REVIEW_DONE=1" {
  # When gh() bash function already ran the review, binary wrapper must not run again.
  run env HOME="${MOCK_HOME}" _GH_REVIEW_DONE=1 "${GH_WRAPPER}" -R owner/repo pr merge 53 --squash

  [[ ! -f "${MOCK_DIR}/review_called" ]]
}
