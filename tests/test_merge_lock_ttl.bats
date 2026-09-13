#!/usr/bin/env bats
# Tests for per-lock TTL via --ttl (issue #501).
# Run: bats tests/test_merge_lock_ttl.bats
#
# The motivating failure: a sequential wave is authorized once but merged one
# PR at a time. With a fixed 30-minute window the seventh PR expires because
# the first six were slow, interrupting the human to re-authorize work they
# already approved.

SCRIPT="${BATS_TEST_DIRNAME}/../hooks/merge-lock.sh"

setup() {
  # The real gh is an exported shell function, and it shadows the PATH stub
  # below unless both it and BASH_ENV are cleared. Without this, every call
  # fails on the wrapper's identity check instead of reaching the stub.
  unset BASH_ENV
  unset CDPATH
  unset -f gh 2>/dev/null || true
  export -n gh 2>/dev/null || true

  TMP_HOME="$(mktemp -d)"
  readonly TMP_HOME
  export HOME="${TMP_HOME}"

  mkdir -p "${TMP_HOME}/bin"
  printf '#!/usr/bin/env bash\necho acme/widgets\n' >"${TMP_HOME}/bin/gh"
  chmod +x "${TMP_HOME}/bin/gh"
  export PATH="${TMP_HOME}/bin:${PATH}"
}

teardown() {
  rm -rf "${TMP_HOME}"
}

lock_file() {
  echo "${TMP_HOME}/.claude/merge-locks/acme/widgets/pr-$1.lock"
}

# Backdate a lock so expiry can be tested without waiting.
age_lock() {
  local pr="$1" seconds="$2"
  local f
  f="$(lock_file "${pr}")"
  local ts
  ts=$(grep "^TIMESTAMP=" "${f}" | cut -d= -f2)
  local backdated=$((ts - seconds))
  sed -i '' "s/^TIMESTAMP=.*/TIMESTAMP=${backdated}/" "${f}"
}

# --- defaults ----------------------------------------------------------------

@test "a lock without --ttl records the 30-minute default" {
  run bash "${SCRIPT}" auth 100 "ok"
  [ "${status}" -eq 0 ]
  grep -q "^TTL_SECONDS=1800$" "$(lock_file 100)"
}

@test "the default window still expires at 30 minutes" {
  bash "${SCRIPT}" auth 100 "ok"
  age_lock 100 1900
  run bash "${SCRIPT}" check 100
  [ "${status}" -ne 0 ]
}

@test "the default window is still valid just under 30 minutes" {
  bash "${SCRIPT}" auth 100 "ok"
  age_lock 100 1700
  run bash "${SCRIPT}" check 100
  [ "${status}" -eq 0 ]
}

# --- --ttl grants a longer window -------------------------------------------

@test "--ttl records the requested lifetime in seconds" {
  run bash "${SCRIPT}" auth 100 "ok" --ttl 180
  [ "${status}" -eq 0 ]
  grep -q "^TTL_SECONDS=10800$" "$(lock_file 100)"
}

@test "--ttl=N is accepted as well as --ttl N" {
  run bash "${SCRIPT}" auth 100 "ok" --ttl=180
  [ "${status}" -eq 0 ]
  grep -q "^TTL_SECONDS=10800$" "$(lock_file 100)"
}

@test "a lock survives past 30 minutes when --ttl allows it" {
  # The reported failure: the seventh PR in a sequential wave should not
  # expire because the first six took longer than half an hour.
  bash "${SCRIPT}" auth 100 "ok" --ttl 180
  age_lock 100 3600
  run bash "${SCRIPT}" check 100
  [ "${status}" -eq 0 ]
}

@test "a longer lock still expires at its own limit" {
  bash "${SCRIPT}" auth 100 "ok" --ttl 60
  age_lock 100 3700
  run bash "${SCRIPT}" check 100
  [ "${status}" -ne 0 ]
}

@test "--ttl applies to every lock in a batch" {
  run bash "${SCRIPT}" auth 100,204,553 "ok" --ttl 240
  [ "${status}" -eq 0 ]
  grep -q "^TTL_SECONDS=14400$" "$(lock_file 100)"
  grep -q "^TTL_SECONDS=14400$" "$(lock_file 204)"
  grep -q "^TTL_SECONDS=14400$" "$(lock_file 553)"
}

@test "the whole batch survives a long run" {
  bash "${SCRIPT}" auth 100,204,553 "wave" --ttl 240
  age_lock 100 7200
  age_lock 204 7200
  age_lock 553 7200
  run bash "${SCRIPT}" check 100
  [ "${status}" -eq 0 ]
  run bash "${SCRIPT}" check 553
  [ "${status}" -eq 0 ]
}

@test "the confirmation message reports the granted window" {
  run bash "${SCRIPT}" auth 100 "ok" --ttl 120
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"120 minutes"* ]]
}

# --- validation --------------------------------------------------------------

@test "--ttl rejects a non-numeric value" {
  run bash "${SCRIPT}" auth 100 "ok" --ttl abc
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 100)" ]
}

@test "--ttl rejects zero" {
  run bash "${SCRIPT}" auth 100 "ok" --ttl 0
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 100)" ]
}

@test "--ttl rejects a negative value" {
  run bash "${SCRIPT}" auth 100 "ok" --ttl -5
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 100)" ]
}

@test "--ttl rejects a value past the 8-hour maximum" {
  # Refuses rather than clamping: silently shortening the window would expire
  # a batch mid-run, which is the failure this flag exists to prevent.
  run bash "${SCRIPT}" auth 100 "ok" --ttl 600
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 100)" ]
}

@test "--ttl accepts exactly the maximum" {
  run bash "${SCRIPT}" auth 100 "ok" --ttl 480
  [ "${status}" -eq 0 ]
  grep -q "^TTL_SECONDS=28800$" "$(lock_file 100)"
}

@test "--ttl with no value is a usage error" {
  run bash "${SCRIPT}" auth 100 "ok" --ttl
  [ "${status}" -ne 0 ]
}

@test "--ttl is not mistaken for the reason argument" {
  run bash "${SCRIPT}" auth 100 "ok" --ttl 120
  [ "${status}" -eq 0 ]
  grep -q "^REASON=ok$" "$(lock_file 100)"
}

@test "--ttl and --repo combine" {
  run bash "${SCRIPT}" auth 100 "ok" --repo acme/gadgets --ttl 120
  [ "${status}" -eq 0 ]
  f="${TMP_HOME}/.claude/merge-locks/acme/gadgets/pr-100.lock"
  [ -f "${f}" ]
  grep -q "^TTL_SECONDS=7200$" "${f}"
}

# --- legacy locks ------------------------------------------------------------

@test "a lock without TTL_SECONDS falls back to 30 minutes" {
  # Locks written before this field existed must keep working, rather than
  # reading as TTL 0 and being purged on the next run.
  bash "${SCRIPT}" auth 100 "ok"
  sed -i '' '/^TTL_SECONDS=/d' "$(lock_file 100)"
  age_lock 100 1700
  run bash "${SCRIPT}" check 100
  [ "${status}" -eq 0 ]
}

@test "a lock without TTL_SECONDS still expires at 30 minutes" {
  bash "${SCRIPT}" auth 100 "ok"
  sed -i '' '/^TTL_SECONDS=/d' "$(lock_file 100)"
  age_lock 100 1900
  run bash "${SCRIPT}" check 100
  [ "${status}" -ne 0 ]
}

@test "a lock with a malformed TTL_SECONDS falls back rather than failing" {
  bash "${SCRIPT}" auth 100 "ok"
  sed -i '' 's/^TTL_SECONDS=.*/TTL_SECONDS=garbage/' "$(lock_file 100)"
  age_lock 100 1700
  run bash "${SCRIPT}" check 100
  [ "${status}" -eq 0 ]
}

# --- purge and status honor the per-lock TTL ---------------------------------

@test "purge keeps a long-TTL lock that a 30-minute rule would remove" {
  bash "${SCRIPT}" auth 100 "ok" --ttl 180
  age_lock 100 3600
  run bash "${SCRIPT}" list
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 100)" ]
}

@test "purge removes a long-TTL lock once its own window elapses" {
  bash "${SCRIPT}" auth 100 "ok" --ttl 60
  age_lock 100 3700
  run bash "${SCRIPT}" list
  [ "${status}" -eq 0 ]
  [ ! -f "$(lock_file 100)" ]
}

@test "status reports remaining time against the lock's own TTL" {
  bash "${SCRIPT}" auth 100 "ok" --ttl 180
  age_lock 100 3600
  run bash "${SCRIPT}" status 100
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"is authorized"* ]]
  # 180 minutes granted, 60 aged off, so ~120 remain. Accept 119 as well:
  # remaining minutes are computed by integer division, so a second elapsing
  # between the authorize and the status call rounds the answer down. The
  # assertion that matters is that it reports against the lock's own 180, not
  # the 30-minute default, which would have expired long since.
  [[ "${output}" == *"120 minutes"* || "${output}" == *"119 minutes"* ]]
}

@test "list shows remaining time" {
  bash "${SCRIPT}" auth 100 "ok" --ttl 120
  run bash "${SCRIPT}" list
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"m left"* ]]
}
