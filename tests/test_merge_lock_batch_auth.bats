#!/usr/bin/env bats
# Tests for merge-lock batch authorization (issue #108).
# Run: bats tests/test_merge_lock_batch_auth.bats

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

  # Locks are keyed on repo + PR; stub gh so cwd resolution is offline.
  mkdir -p "${TMP_HOME}/bin"
  printf '#!/usr/bin/env bash\necho acme/widgets\n' >"${TMP_HOME}/bin/gh"
  chmod +x "${TMP_HOME}/bin/gh"
  export PATH="${TMP_HOME}/bin:${PATH}"
}

teardown() {
  # TMP_HOME is readonly so a test can't reassign it out from under teardown,
  # even if it reassigns HOME mid-test (see #116).
  rm -rf "${TMP_HOME}"
}

lock_file() {
  echo "${TMP_HOME}/.claude/merge-locks/acme/widgets/pr-$1.lock"
}

@test "single PR form still works" {
  run bash "${SCRIPT}" auth 100 "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 100)" ]
  grep -q "^PR_NUMBER=100$" "$(lock_file 100)"
  grep -q "^REASON=ok$" "$(lock_file 100)"
}

@test "comma-separated list writes one lock per PR" {
  run bash "${SCRIPT}" auth 100,204,553 "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 100)" ]
  [ -f "$(lock_file 204)" ]
  [ -f "$(lock_file 553)" ]
}

@test "whitespace inside list is tolerated" {
  run bash "${SCRIPT}" auth "100, 204 ,553" "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 100)" ]
  [ -f "$(lock_file 204)" ]
  [ -f "$(lock_file 553)" ]
}

@test "all PRs share the same timestamp" {
  run bash "${SCRIPT}" auth 100,204,553 "ok"
  [ "${status}" -eq 0 ]
  ts100=$(grep "^TIMESTAMP=" "$(lock_file 100)" | cut -d= -f2)
  ts204=$(grep "^TIMESTAMP=" "$(lock_file 204)" | cut -d= -f2)
  ts553=$(grep "^TIMESTAMP=" "$(lock_file 553)" | cut -d= -f2)
  [ "${ts100}" = "${ts204}" ]
  [ "${ts204}" = "${ts553}" ]
}

@test "list form refuses when reason is missing" {
  run bash "${SCRIPT}" auth 100,204,553
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 100)" ]
  [ ! -f "$(lock_file 204)" ]
}

@test "single PR form also refuses when reason is missing (tightened)" {
  run bash "${SCRIPT}" auth 100
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 100)" ]
}

@test "non-numeric entry rejects entire batch" {
  run bash "${SCRIPT}" auth "100,abc,553" "ok"
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 100)" ]
  [ ! -f "$(lock_file 553)" ]
}

@test "empty element in list rejects entire batch" {
  run bash "${SCRIPT}" auth "100,,553" "ok"
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 100)" ]
  [ ! -f "$(lock_file 553)" ]
}

@test "pr-0 is rejected as an invalid PR number" {
  run bash "${SCRIPT}" auth 0 "ok"
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 0)" ]
}

@test "pr-0 in a batch rejects the entire batch" {
  run bash "${SCRIPT}" auth "100,0,553" "ok"
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 100)" ]
  [ ! -f "$(lock_file 0)" ]
  [ ! -f "$(lock_file 553)" ]
}
