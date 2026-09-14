#!/usr/bin/env bats
# Tests for scripts/normalize-iterm-home.sh, the git clean filter that strips
# the per-machine home directory out of settings.json's iTerm2 cc-status hook
# paths.
#
# Why this exists: the filter originally matched only backslash-escaped forward
# slashes, because iTerm2 writes settings.json via NSJSONSerialization, which
# escapes them. But Claude Code's own settings writer emits bare slashes, so
# every time Claude Code rewrote the file -- enabling a plugin, changing a
# model -- the filter silently no-opped and this machine's absolute home
# directory reached the index. filter.iterm-home.required does not catch that:
# the script exits 0 either way, it just has nothing to do.
#
# install.sh's smoke test missed it for the same reason the filter did: it fed
# only the escaped sample, so it stayed green while the filter was blind to
# half its input.
#
# Run: bats tests/test_normalize_iterm_home.bats

setup() {
  FILTER="${BATS_TEST_DIRNAME}/../scripts/normalize-iterm-home.sh"
}

@test "escaped slashes (iTerm2 / NSJSONSerialization) are normalized" {
  # Written to a file rather than piped through a nested bash -c, so the
  # backslashes reach the filter as literal bytes instead of being eaten by a
  # second round of shell quoting.
  printf '%s\n' '"command" : "\/Users\/probeuser\/.config\/iterm2\/cc-status"' \
    >"${BATS_TEST_TMPDIR}/escaped.txt"
  run "${FILTER}" <"${BATS_TEST_TMPDIR}/escaped.txt"
  [ "${status}" -eq 0 ]
  [ "${output}" = '"command" : "~\/.config\/iterm2\/cc-status"' ]
}

@test "bare slashes (Claude Code settings writer) are normalized" {
  run bash -c "printf '%s\n' '\"command\": \"/Users/probeuser/.config/iterm2/cc-status\"' | '${FILTER}'"
  [ "${status}" -eq 0 ]
  [ "${output}" = '"command": "~/.config/iterm2/cc-status"' ]
}

@test "a path already in ~/ form passes through unchanged" {
  run bash -c "printf '%s\n' '\"command\": \"~/.config/iterm2/cc-status\"' | '${FILTER}'"
  [ "${status}" -eq 0 ]
  [ "${output}" = '"command": "~/.config/iterm2/cc-status"' ]
}

@test "is idempotent: filtering twice matches filtering once" {
  run bash -c "printf '%s\n' '\"command\": \"/Users/probeuser/.config/iterm2/cc-status\"' | '${FILTER}' | '${FILTER}'"
  [ "${status}" -eq 0 ]
  [ "${output}" = '"command": "~/.config/iterm2/cc-status"' ]
}

@test "sibling paths under .config/iterm2 are untouched" {
  run bash -c "printf '%s\n' '\"command\": \"/Users/probeuser/.config/iterm2/other-tool\"' | '${FILTER}'"
  [ "${status}" -eq 0 ]
  [ "${output}" = '"command": "/Users/probeuser/.config/iterm2/other-tool"' ]
}

@test "unrelated /Users paths are untouched" {
  run bash -c "printf '%s\n' '\"command\": \"/Users/probeuser/bin/something\"' | '${FILTER}'"
  [ "${status}" -eq 0 ]
  [ "${output}" = '"command": "/Users/probeuser/bin/something"' ]
}

@test "the username segment cannot span a path component" {
  # A longer path that merely ends in the cc-status tail must not collapse to
  # "~/", which would discard the intervening components.
  run bash -c "printf '%s\n' '\"command\": \"/Users/probeuser/nested/deeper/.config/iterm2/cc-status\"' | '${FILTER}'"
  [ "${status}" -eq 0 ]
  [ "${output}" = '"command": "/Users/probeuser/nested/deeper/.config/iterm2/cc-status"' ]
}

@test "input with no cc-status entry passes through byte-identical" {
  run bash -c "printf '%s\n' '{\"model\": \"opus\", \"env\": {\"A\": \"1\"}}' | '${FILTER}'"
  [ "${status}" -eq 0 ]
  [ "${output}" = '{"model": "opus", "env": {"A": "1"}}' ]
}

@test "every cc-status entry in a multi-hook file is normalized" {
  run bash -c "printf '%s\n%s\n%s\n' \
    '\"command\": \"/Users/probeuser/.config/iterm2/cc-status\"' \
    '\"command\": \"/Users/probeuser/.config/iterm2/cc-status\"' \
    '\"command\": \"/Users/probeuser/.config/iterm2/cc-status\"' | '${FILTER}'"
  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${output}" | grep -c 'Users/probeuser')" -eq 0 ]
}
