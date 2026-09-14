#!/usr/bin/env bats
# Tests for gh() wrapper function in ~/.config/bash/functions.sh
#
# Verifies that help flags bypass the pre-merge review script entirely,
# so `gh pr merge --help` just shows help instead of triggering a 120s
# Claude CLI analysis.
#
# Bug: gh() wrapper matches ALL `gh pr merge ...` invocations, including
#   `gh pr merge --help` and `gh pr merge -h`. This runs pre-merge-review.sh
#   for a help request, which takes ~120 seconds and times out silently.
#
# Run: bats ~/.claude/tests/test_gh_wrapper.bats

FUNCTIONS_SH="${HOME}/.config/bash/functions.sh"

setup() {
  # GH_TOKEN must be unset for the whole test file, not just clipped from one
  # call. The wrapper refuses to run whenever GH_TOKEN is set and it cannot
  # resolve that token to a login (the GH_TOKEN identity gate). Resolution goes
  # through a real `gh api user`, which the PATH stub below answers with a
  # bare `exit 0` -- no login, so the check fails and every test dies on the
  # refusal instead of reaching the behaviour under test. The wrapper itself
  # prescribes this remedy for exactly this case: "If it is a test stub, unset
  # GH_TOKEN for the test so this check is skipped."
  #
  # This is NOT the `env -u GH_TOKEN` false lead from the merge-lock work
  # (#514). There, unsetting the token masked the real cause by breaking the
  # wrapper the gh() function invoked -- the assertions passed vacuously. Here
  # the gate is upstream of every code path these tests exercise, and clearing
  # it lets each test actually reach and assert its behaviour. Verified
  # 2026-09-14 with a healthy, non-expired token.
  #
  # This alone does NOT make this file green: the _load_gh_fn guard below now
  # fails these tests loudly, because the sed extraction they depend on matches
  # nothing. That is #477 Cause 2, tracked separately.
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

  # Mock gh binary that just exits 0 (bypasses real gh calls)
  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  # Build mock HOME structure with a review script that records its calls
  MOCK_HOME="${MOCK_DIR}/home"
  export MOCK_HOME
  mkdir -p "${MOCK_HOME}/.claude/hooks"

  # review_called is created only if the review script runs.
  # Tests that expect review bypass will assert it does NOT exist.
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

# Load gh() from functions.sh into the current shell with MOCK_HOME active.
# Uses eval so the function's ${HOME} references resolve to MOCK_HOME at
# call time (HOME is set before each direct gh invocation in tests below).
_load_gh_fn() {
  export HOME="${MOCK_HOME}"
  local func_def
  func_def=$(sed -n '/^gh()/,/^export -f gh$/p' "${FUNCTIONS_SH}")

  # Fail loudly on a zero-line extraction (#477, suggested fix 3). `eval ""`
  # is a no-op, so an extraction that matches nothing leaves whatever `gh` is
  # already in scope -- the inherited real wrapper -- and the tests below then
  # silently exercise the ambient environment instead of the function they
  # name. That is a false PASS, which is worse than a failure.
  #
  # This range does NOT match today: `gh()` moved to gh-wrapper.sh and is
  # indented there, and functions.sh keeps only an indented fallback stub with
  # no `export -f gh` line. Repointing the extraction is #477's separate fix 2
  # and is deliberately not attempted here; this guard only makes the breakage
  # visible instead of silent.
  if [[ -z "${func_def//[[:space:]]/}" ]]; then
    echo "FATAL: extracted no gh() definition from ${FUNCTIONS_SH}" >&2
    echo "       The sed range no longer matches; see #477 fix 2." >&2
    return 1
  fi

  eval "${func_def}"
}

@test "gh pr merge --help bypasses review script" {
  # Bug reproduction: --help currently triggers pre-merge-review.sh.
  # After fix: gh pr merge --help passes straight to command gh, no review.
  _load_gh_fn

  gh pr merge --help

  [[ ! -f "${MOCK_DIR}/review_called" ]]
}

@test "gh pr merge -h bypasses review script" {
  # Same bug with the short -h flag.
  _load_gh_fn

  gh pr merge -h

  [[ ! -f "${MOCK_DIR}/review_called" ]]
}

@test "gh pr merge 123 --squash calls review script" {
  # Regression: real merge operations must still trigger the review.
  _load_gh_fn

  gh pr merge 123 --squash

  [[ -f "${MOCK_DIR}/review_called" ]]
}

@test "gh status passes through without calling review script" {
  # Non-pr-merge commands must never trigger the review.
  _load_gh_fn

  gh status

  [[ ! -f "${MOCK_DIR}/review_called" ]]
}

# ── Global-flag bypass tests ─────────────────────────────────────────────────
# Regression for: gh -R owner/repo pr merge bypasses the $1=='pr' check.

@test "gh -R owner/repo pr merge 123 calls review script" {
  _load_gh_fn

  gh -R owner/repo pr merge 123 --squash

  [[ -f "${MOCK_DIR}/review_called" ]]
}

@test "gh --repo=owner/repo pr merge 123 calls review script" {
  _load_gh_fn

  gh --repo=owner/repo pr merge 123 --squash

  [[ -f "${MOCK_DIR}/review_called" ]]
}

@test "gh --repo owner/repo pr merge 123 calls review script" {
  _load_gh_fn

  gh --repo owner/repo pr merge 123 --squash

  [[ -f "${MOCK_DIR}/review_called" ]]
}
