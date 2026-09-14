#!/usr/bin/env bats
# Tests that run-review.sh refuses to run outside a git repository instead of
# falling back to a literal ".git" path (claude-config#519).
#
# Root cause: `GIT_DIR_PATH="$(git rev-parse --git-dir 2>/dev/null || echo ".git")"`
# left GIT_DIR_PATH as the relative string ".git" when the cwd was not a repo.
# REVIEW_LOG, DISAGREEMENT_LOG and CACHE_DIR all derive from it, so the first
# write created a real .git/ DIRECTORY holding hook artifacts but no git
# metadata. Observed at ~/Developer/beacon-biosignals, a plain folder holding
# several independent checkouts.
#
# Run: bats tests/test_run_review_no_repo.bats

# Resolve the script under test relative to THIS test file, not via
# ${HOME}/.claude/hooks — that path is a symlink to the main working
# directory, so in a git worktree it would silently exercise main's copy
# instead of the branch under test.
SCRIPT="${BATS_TEST_DIRNAME}/../hooks/run-review.sh"

setup() {
  NOTAREPO="$(mktemp -d)"
  export NOTAREPO

  # mktemp -d can land under a path that is itself inside a repo; walk up and
  # confirm, so a false pass is impossible if TMPDIR ever moves.
  if git -C "${NOTAREPO}" rev-parse --git-dir >/dev/null 2>&1; then
    skip "temp dir is inside a git repo; cannot test the no-repo path"
  fi
}

teardown() {
  rm -rf "${NOTAREPO}"
}

# Helper: feed a well-formed diff on stdin from outside any repo. The diff is
# non-empty so an early "no staged changes" exit cannot be mistaken for the
# behavior under test.
#
# stderr is folded into stdout explicitly. Bats 1.14 already merges it into
# ${output}, but that is a default the suite should not depend on: the refusal
# message under test is written to stderr, so if a future bats separates the
# streams the message assertion would pass vacuously rather than fail loudly.
run_outside_repo() {
  cd "${NOTAREPO}" || exit
  printf 'diff --git a/foo.js b/foo.js\nindex 0000000..1234567 100644\n--- a/foo.js\n+++ b/foo.js\n@@ -0,0 +1 @@\n+const x = 1;\n' \
    | bash "${SCRIPT}" 2>&1
}

@test "exits non-zero when not inside a git repository" {
  run run_outside_repo
  [ "${status}" -ne 0 ]
}

@test "does not create a .git directory outside a repository" {
  run run_outside_repo
  [ ! -e "${NOTAREPO}/.git" ]
}

@test "does not create review artifacts outside a repository" {
  run run_outside_repo
  [ ! -e "${NOTAREPO}/.git/last-review-result.log" ]
  [ ! -e "${NOTAREPO}/.git/claude-review-cache" ]
  [ ! -e "${NOTAREPO}/.git/reviewer-disagreements.log" ]
}

@test "explains why it refused, naming the directory" {
  run run_outside_repo
  [[ "${output}" == *"not inside a git repository"* ]]
  [[ "${output}" == *"${NOTAREPO}"* ]]
}
