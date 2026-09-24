#!/usr/bin/env bats
# Tests for scripts/claude-incognito.sh — a one-shot `claude -p` wrapper that
# leaves no local session trace.
#
# The real claude binary is never run. CLAUDE_BIN points at a stub that
# records its argv (one arg per line), creates the session-env directory the
# real CLI leaves behind, and exits with a configurable code. CLAUDE_CONFIG_DIR
# and HOME point into a throwaway dir so nothing touches the real ~/.claude.
#
# Run: bats ~/Developer/claude-config/tests/test_claude_incognito.bats

# `run --separate-stderr` needs bats >= 1.5.0.
bats_require_minimum_version 1.5.0

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  export TMPDIR_TEST
  export HOME="${TMPDIR_TEST}/home"
  export CLAUDE_CONFIG_DIR="${TMPDIR_TEST}/config"
  mkdir -p "${HOME}" "${CLAUDE_CONFIG_DIR}"

  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/claude-incognito.sh"
  ARGV_FILE="${TMPDIR_TEST}/argv"
  export ARGV_FILE

  # Stub claude: record argv, simulate the session-env dir, exit STUB_EXIT.
  CLAUDE_BIN="${TMPDIR_TEST}/claude-stub"
  export CLAUDE_BIN
  cat >"${CLAUDE_BIN}" <<'STUB'
#!/usr/bin/env bash
: >"${ARGV_FILE}"
for a in "$@"; do printf '%s\n' "${a}" >>"${ARGV_FILE}"; done
sid=""
prev=""
for a in "$@"; do
  if [[ "${prev}" == "--session-id" ]]; then sid="${a}"; fi
  prev="${a}"
done
if [[ -n "${sid}" ]]; then
  mkdir -p "${CLAUDE_CONFIG_DIR}/session-env/${sid}"
  if [[ "${STUB_LEAVE_FILE:-0}" == 1 ]]; then
    touch "${CLAUDE_CONFIG_DIR}/session-env/${sid}/leftover"
  fi
fi
# Simulate an interrupt: signal the wrapper while "claude" is still running.
if [[ "${STUB_KILL_PARENT:-0}" == 1 ]]; then
  kill -TERM "${PPID}"
fi
if [[ "${STUB_READ_STDIN:-0}" == 1 ]]; then
  cat >"${ARGV_FILE}.stdin"
fi
exit "${STUB_EXIT:-0}"
STUB
  chmod +x "${CLAUDE_BIN}"
}

teardown() {
  rm -rf "${TMPDIR_TEST}"
}

# Echo the value that followed --session-id in the recorded argv.
recorded_sid() {
  awk 'prev == "--session-id" { print; exit } { prev = $0 }' "${ARGV_FILE}"
}

@test "--help exits 0 and prints usage without running claude" {
  run bash "${SCRIPT}" --help
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == *"Usage"* ]]
  [[ ! -e "${ARGV_FILE}" ]]
}

@test "-h exits 0 and prints usage" {
  run bash "${SCRIPT}" -h
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == *"Usage"* ]]
}

@test "passes -p, --no-session-persistence, and --session-id <uuid>" {
  run bash "${SCRIPT}" "hello"
  [[ "${status}" -eq 0 ]]
  grep -qx -- "-p" "${ARGV_FILE}"
  grep -qx -- "--no-session-persistence" "${ARGV_FILE}"
  local sid
  sid="$(recorded_sid)"
  [[ "${sid}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

@test "user args pass through verbatim as separate args, spaces intact" {
  run bash "${SCRIPT}" --model sonnet "what is  two plus two?" "second arg"
  [[ "${status}" -eq 0 ]]
  # The last four recorded args are exactly the user's four args, in order.
  local tail4
  tail4="$(tail -n 4 "${ARGV_FILE}")"
  [[ "${tail4}" == $'--model\nsonnet\nwhat is  two plus two?\nsecond arg' ]]
}

@test "empty session-env dir is removed after the run" {
  run bash "${SCRIPT}" "hello"
  [[ "${status}" -eq 0 ]]
  local sid
  sid="$(recorded_sid)"
  [[ -n "${sid}" ]]
  [[ ! -e "${CLAUDE_CONFIG_DIR}/session-env/${sid}" ]]
}

@test "non-empty session-env dir is preserved with a stderr warning" {
  STUB_LEAVE_FILE=1 run --separate-stderr bash "${SCRIPT}" "hello"
  [[ "${status}" -eq 0 ]]
  local sid
  sid="$(recorded_sid)"
  [[ -f "${CLAUDE_CONFIG_DIR}/session-env/${sid}/leftover" ]]
  [[ "${stderr}" == *"${CLAUDE_CONFIG_DIR}/session-env/${sid}"* ]]
}

@test "claude's exit code is propagated" {
  STUB_EXIT=3 run bash "${SCRIPT}" "hello"
  [[ "${status}" -eq 3 ]]
}

@test "cleanup still runs when claude fails" {
  STUB_EXIT=3 run bash "${SCRIPT}" "hello"
  [[ "${status}" -eq 3 ]]
  local sid
  sid="$(recorded_sid)"
  [[ -n "${sid}" ]]
  [[ ! -e "${CLAUDE_CONFIG_DIR}/session-env/${sid}" ]]
}

@test "EXIT trap cleans up when the wrapper is killed mid-run" {
  STUB_KILL_PARENT=1 run bash "${SCRIPT}" "hello"
  # Killed by SIGTERM: 128 + 15.
  [[ "${status}" -eq 143 ]]
  local sid
  sid="$(recorded_sid)"
  [[ -n "${sid}" ]]
  [[ ! -e "${CLAUDE_CONFIG_DIR}/session-env/${sid}" ]]
}

@test "exit code survives a failed cleanup (non-empty dir)" {
  STUB_EXIT=3 STUB_LEAVE_FILE=1 run bash "${SCRIPT}" "hello"
  [[ "${status}" -eq 3 ]]
}

@test "defaults to \$HOME/.claude when CLAUDE_CONFIG_DIR is unset" {
  # The script runs without CLAUDE_CONFIG_DIR; a wrapper hands the stub the
  # default location so it creates session-env where real claude would.
  cat >"${TMPDIR_TEST}/wrap" <<'WRAP'
#!/usr/bin/env bash
CLAUDE_CONFIG_DIR="${HOME}/.claude" exec "${TMPDIR_TEST}/claude-stub" "$@"
WRAP
  chmod +x "${TMPDIR_TEST}/wrap"
  run env -u CLAUDE_CONFIG_DIR CLAUDE_BIN="${TMPDIR_TEST}/wrap" bash "${SCRIPT}" "hello"
  [[ "${status}" -eq 0 ]]
  local sid
  sid="$(recorded_sid)"
  [[ -n "${sid}" ]]
  [[ -d "${HOME}/.claude/session-env" ]]
  [[ ! -e "${HOME}/.claude/session-env/${sid}" ]]
}

@test "no args with piped stdin passes through to claude -p" {
  run bash -c 'printf "hi\n" | STUB_READ_STDIN=1 bash "$1"' _ "${SCRIPT}"
  [[ "${status}" -eq 0 ]]
  # Exactly the four wrapper args: -p, --no-session-persistence, --session-id, <uuid>.
  [[ "$(wc -l <"${ARGV_FILE}" | tr -d ' ')" -eq 4 ]]
  [[ "$(cat "${ARGV_FILE}.stdin")" == "hi" ]]
}
