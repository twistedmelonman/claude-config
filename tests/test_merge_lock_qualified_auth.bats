#!/usr/bin/env bats
# Tests for repo-qualified batch authorization: OWNER/REPO#N tokens in the
# authorize list, so one human command can authorize PRs across many repos.
# Run: bats tests/test_merge_lock_qualified_auth.bats

SCRIPT="${BATS_TEST_DIRNAME}/../hooks/merge-lock.sh"

setup() {
  # The real gh is an exported shell function, and it shadows the PATH stub
  # below unless both it and BASH_ENV are cleared. Without this, every call
  # fails on the wrapper's identity check instead of reaching the stub
  # (claude-config#514, #477).
  unset BASH_ENV
  unset CDPATH
  unset -f gh 2>/dev/null || true
  export -n gh 2>/dev/null || true

  TMP_HOME="$(mktemp -d)"
  readonly TMP_HOME
  export HOME="${TMP_HOME}"

  # cwd resolution must stay offline; acme/widgets is the "current repo" so
  # bare numbers in a mixed list have a default to resolve against.
  mkdir -p "${TMP_HOME}/bin"
  printf '#!/usr/bin/env bash\necho acme/widgets\n' >"${TMP_HOME}/bin/gh"
  chmod +x "${TMP_HOME}/bin/gh"
  export PATH="${TMP_HOME}/bin:${PATH}"
}

teardown() {
  rm -rf "${TMP_HOME}"
}

# Lock path for an explicit repo slug.
qualified_lock() {
  echo "${TMP_HOME}/.claude/merge-locks/$1/pr-$2.lock"
}

# Lock path in the cwd-resolved repo.
default_lock() {
  echo "${TMP_HOME}/.claude/merge-locks/acme/widgets/pr-$1.lock"
}

@test "a single qualified token writes the lock under its own repo" {
  run bash "${SCRIPT}" auth "octo/tools#42" "wave 3"
  [ "${status}" -eq 0 ]
  [ -f "$(qualified_lock octo/tools 42)" ]
  grep -q "^REPO=octo/tools$" "$(qualified_lock octo/tools 42)"
  grep -q "^PR_NUMBER=42$" "$(qualified_lock octo/tools 42)"
}

@test "qualified tokens across repos each land in their own repo directory" {
  run bash "${SCRIPT}" auth "octo/tools#42,acme/widgets#7,other/thing#1" "wave 3"
  [ "${status}" -eq 0 ]
  [ -f "$(qualified_lock octo/tools 42)" ]
  [ -f "$(qualified_lock acme/widgets 7)" ]
  [ -f "$(qualified_lock other/thing 1)" ]
}

@test "a qualified token does not leak its repo into a later bare number" {
  # The bare 9 must resolve to the cwd repo, not to octo/tools.
  run bash "${SCRIPT}" auth "octo/tools#42,9" "wave 3"
  [ "${status}" -eq 0 ]
  [ -f "$(qualified_lock octo/tools 42)" ]
  [ -f "$(default_lock 9)" ]
  [ ! -f "$(qualified_lock octo/tools 9)" ]
}

@test "bare numbers still honor an explicit --repo alongside qualified tokens" {
  run bash "${SCRIPT}" auth "octo/tools#42,9" "wave 3" --repo flag/repo
  [ "${status}" -eq 0 ]
  [ -f "$(qualified_lock octo/tools 42)" ]
  [ -f "$(qualified_lock flag/repo 9)" ]
}

@test "all locks in a cross-repo batch share one timestamp" {
  run bash "${SCRIPT}" auth "octo/tools#42,acme/widgets#7" "wave 3"
  [ "${status}" -eq 0 ]
  ts_a=$(grep "^TIMESTAMP=" "$(qualified_lock octo/tools 42)" | cut -d= -f2)
  ts_b=$(grep "^TIMESTAMP=" "$(qualified_lock acme/widgets 7)" | cut -d= -f2)
  [ "${ts_a}" = "${ts_b}" ]
}

@test "whitespace around qualified tokens is tolerated" {
  run bash "${SCRIPT}" auth " octo/tools#42 , acme/widgets#7 " "wave 3"
  [ "${status}" -eq 0 ]
  [ -f "$(qualified_lock octo/tools 42)" ]
  [ -f "$(qualified_lock acme/widgets 7)" ]
}

# --- Whole-batch rejection ---------------------------------------------------
# A typo must authorize nothing. Partial authorization from a malformed list is
# the failure mode these tests exist to prevent.

@test "a malformed token rejects the whole batch" {
  run bash "${SCRIPT}" auth "octo/tools#42,notarepo#7" "wave 3"
  [ "${status}" -ne 0 ]
  [ ! -f "$(qualified_lock octo/tools 42)" ]
}

@test "a non-numeric PR in a qualified token rejects the whole batch" {
  run bash "${SCRIPT}" auth "octo/tools#42,acme/widgets#abc" "wave 3"
  [ "${status}" -ne 0 ]
  [ ! -f "$(qualified_lock octo/tools 42)" ]
}

@test "a qualified token with PR 0 rejects the whole batch" {
  run bash "${SCRIPT}" auth "octo/tools#42,acme/widgets#0" "wave 3"
  [ "${status}" -ne 0 ]
  [ ! -f "$(qualified_lock octo/tools 42)" ]
}

@test "an empty PR after the hash rejects the whole batch" {
  run bash "${SCRIPT}" auth "octo/tools#42,acme/widgets#" "wave 3"
  [ "${status}" -ne 0 ]
  [ ! -f "$(qualified_lock octo/tools 42)" ]
}

@test "an empty repo before the hash rejects the whole batch" {
  run bash "${SCRIPT}" auth "octo/tools#42,#7" "wave 3"
  [ "${status}" -ne 0 ]
  [ ! -f "$(qualified_lock octo/tools 42)" ]
}

@test "a three-segment repo slug rejects the whole batch" {
  run bash "${SCRIPT}" auth "octo/tools/extra#42" "wave 3"
  [ "${status}" -ne 0 ]
}

@test "more than one hash in a token rejects the whole batch" {
  run bash "${SCRIPT}" auth "octo/tools#4#2" "wave 3"
  [ "${status}" -ne 0 ]
}

# --- Path traversal ----------------------------------------------------------
# Lock paths are built from the repo slug, so a traversing slug must never
# escape the merge-locks directory.

@test "a traversing repo slug is rejected and writes no lock outside the tree" {
  run bash "${SCRIPT}" auth "../../etc#1" "wave 3"
  [ "${status}" -ne 0 ]
  [ ! -f "${TMP_HOME}/.claude/etc/pr-1.lock" ]
  [ ! -f "${TMP_HOME}/etc/pr-1.lock" ]
}

@test "a dot-dot owner segment is rejected" {
  run bash "${SCRIPT}" auth "../widgets#1" "wave 3"
  [ "${status}" -ne 0 ]
}

@test "a dot-dot name segment is rejected" {
  run bash "${SCRIPT}" auth "acme/..#1" "wave 3"
  [ "${status}" -ne 0 ]
}

@test "a slash-bearing name segment is rejected" {
  run bash "${SCRIPT}" auth "acme/wid/gets#1" "wave 3"
  [ "${status}" -ne 0 ]
}

# --- Backward compatibility --------------------------------------------------

@test "the bare-number batch form is unchanged" {
  run bash "${SCRIPT}" auth 100,204,553 "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(default_lock 100)" ]
  [ -f "$(default_lock 204)" ]
  [ -f "$(default_lock 553)" ]
}

@test "a qualified batch still requires a reason" {
  run bash "${SCRIPT}" auth "octo/tools#42,acme/widgets#7"
  [ "${status}" -ne 0 ]
  [ ! -f "$(qualified_lock octo/tools 42)" ]
}

@test "check still reads a lock written by a qualified token" {
  run bash "${SCRIPT}" auth "octo/tools#42" "wave 3"
  [ "${status}" -eq 0 ]
  run bash "${SCRIPT}" check 42 --repo octo/tools
  [ "${status}" -eq 0 ]
}

@test "a qualified lock does not satisfy the same PR number in another repo" {
  run bash "${SCRIPT}" auth "octo/tools#42" "wave 3"
  [ "${status}" -eq 0 ]
  run bash "${SCRIPT}" check 42 --repo acme/widgets
  [ "${status}" -ne 0 ]
}
