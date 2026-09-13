#!/usr/bin/env bats
# Tests for the PreToolUse hook that keeps merge authorization human-only.
# Run: bats tests/test_hook_block_merge_lock_authorize.bats
#
# The extension-less spelling cases exist because ~/.local/bin/merge-lock is a
# symlink to the script, and it is the form a human actually types. A regex
# anchored on "merge-lock.sh" left that name unguarded (found while building
# mobile authorization, issue #509).

HOOK="${BATS_TEST_DIRNAME}/../scripts/hook-block-merge-lock-authorize.sh"

setup() {
  TMP_HOME="$(mktemp -d)"
  readonly TMP_HOME
  export HOME="${TMP_HOME}"
}

teardown() {
  rm -rf "${TMP_HOME}"
}

# Feed a command to the hook the way the harness does. Exit 2 means blocked.
run_hook() {
  printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)" |
    bash "${HOOK}"
}

# --- blocked: authorize ------------------------------------------------------

@test "blocks merge-lock.sh authorize" {
  run run_hook 'merge-lock.sh authorize 42 "ok"'
  [ "${status}" -eq 2 ]
}

@test "blocks the auth abbreviation" {
  run run_hook 'merge-lock.sh auth 42 "ok"'
  [ "${status}" -eq 2 ]
}

@test "blocks the extension-less merge-lock authorize" {
  run run_hook 'merge-lock authorize 42 "ok"'
  [ "${status}" -eq 2 ]
}

@test "blocks the extension-less merge-lock auth" {
  run run_hook 'merge-lock auth 42 "ok"'
  [ "${status}" -eq 2 ]
}

@test "blocks an absolute path to the script" {
  run run_hook "${HOME}/.claude/hooks/merge-lock.sh authorize 42 \"ok\""
  [ "${status}" -eq 2 ]
}

@test "blocks authorize buried later in a compound command" {
  run run_hook 'cd /tmp && merge-lock auth 42 "ok"'
  [ "${status}" -eq 2 ]
}

# --- blocked: enroll ---------------------------------------------------------

@test "blocks enroll, which would let the agent trust its own key" {
  run run_hook 'merge-lock.sh enroll /tmp/evil.pub phone'
  [ "${status}" -eq 2 ]
}

@test "blocks the extension-less enroll" {
  run run_hook 'merge-lock enroll /tmp/evil.pub phone'
  [ "${status}" -eq 2 ]
}

# --- allowed -----------------------------------------------------------------

@test "allows redeem, whose security comes from the signature" {
  run run_hook 'merge-lock.sh redeem SOMETOKEN'
  [ "${status}" -eq 0 ]
}

@test "allows the extension-less redeem" {
  run run_hook 'merge-lock redeem SOMETOKEN'
  [ "${status}" -eq 0 ]
}

@test "allows check" {
  run run_hook 'merge-lock.sh check 42'
  [ "${status}" -eq 0 ]
}

@test "allows status" {
  run run_hook 'merge-lock.sh status 42'
  [ "${status}" -eq 0 ]
}

@test "allows list" {
  run run_hook 'merge-lock.sh list'
  [ "${status}" -eq 0 ]
}

@test "allows signers" {
  run run_hook 'merge-lock.sh signers'
  [ "${status}" -eq 0 ]
}

@test "allows an unrelated command that merely mentions the word" {
  run run_hook 'grep -n authorize scripts/merge-lock-sign.sh'
  [ "${status}" -eq 0 ]
}

# --- logging -----------------------------------------------------------------

@test "a blocked command is recorded in the blocked-commands log" {
  mkdir -p "${HOME}/.claude"
  run run_hook 'merge-lock auth 42 "ok"'
  [ "${status}" -eq 2 ]
  grep -q "BLOCKED MERGE-LOCK AUTHORIZE" "${HOME}/.claude/blocked-commands.log"
}
