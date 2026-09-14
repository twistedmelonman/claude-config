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

@test "input with no cc-status entry is canonicalized but semantically unchanged" {
  # Byte-identical passthrough was the old contract, before this filter
  # canonicalized formatting. Now the bytes are expected to change; what must
  # not change is the parsed content.
  printf '%s\n' '{"model": "opus", "env": {"A": "1"}}' >"${BATS_TEST_TMPDIR}/plain.json"
  run "${FILTER}" <"${BATS_TEST_TMPDIR}/plain.json"
  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${output}" | jq -S -c .)" = '{"env":{"A":"1"},"model":"opus"}' ]
}

@test "canonicalizes key order, so writer style produces no diff" {
  a="$(printf '{"b":2,"a":1}' | "${FILTER}")"
  b="$(printf '{"a":1,"b":2}' | "${FILTER}")"
  [ "${a}" = "${b}" ]
}

@test "canonicalization survives the two real writer styles" {
  # iTerm2 style (sorted, " : ", escaped slashes) and Claude Code style
  # (insertion order, ": ", bare slashes) must land on identical bytes.
  printf '%s\n' '{"z" : "\/tmp\/x", "a" : 1}' >"${BATS_TEST_TMPDIR}/iterm.json"
  printf '%s\n' '{"a": 1, "z": "/tmp/x"}' >"${BATS_TEST_TMPDIR}/cc.json"
  a="$("${FILTER}" <"${BATS_TEST_TMPDIR}/iterm.json")"
  b="$("${FILTER}" <"${BATS_TEST_TMPDIR}/cc.json")"
  [ "${a}" = "${b}" ]
}

@test "canonical output ends with exactly one newline" {
  run bash -c "printf '{\"a\":1}' | '${FILTER}' | xxd | tail -1"
  [[ "${output}" == *"0a"* ]]
}

@test "invalid JSON passes through unchanged rather than staging an empty file" {
  printf '%s' '{"a": 1, BROKEN' >"${BATS_TEST_TMPDIR}/bad.json"
  run "${FILTER}" <"${BATS_TEST_TMPDIR}/bad.json"
  [ "${status}" -eq 0 ]
  [ "${output}" = '{"a": 1, BROKEN' ]
}

@test "path rewriting still works when jq is unavailable" {
  # jq missing must not disable the #507 guarantee.
  run env PATH="/usr/bin:/bin" bash -c "printf '%s\n' '\"command\": \"/Users/probeuser/.config/iterm2/cc-status\"' | '${FILTER}'"
  [ "${status}" -eq 0 ]
  [ "${output}" = '"command": "~/.config/iterm2/cc-status"' ]
}

@test "canonicalization and path rewriting compose" {
  printf '%s\n' '{"z":1,"cmd":"/Users/probeuser/.config/iterm2/cc-status"}' \
    >"${BATS_TEST_TMPDIR}/both.json"
  run "${FILTER}" <"${BATS_TEST_TMPDIR}/both.json"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *'"cmd": "~/.config/iterm2/cc-status"'* ]]
  # jq -S sorts: "cmd" must precede "z"
  [[ "$(printf '%s\n' "${output}" | grep -n '"cmd"' | cut -d: -f1)" -lt \
     "$(printf '%s\n' "${output}" | grep -n '"z"' | cut -d: -f1)" ]]
}

@test "every cc-status entry in a multi-hook file is normalized" {
  run bash -c "printf '%s\n%s\n%s\n' \
    '\"command\": \"/Users/probeuser/.config/iterm2/cc-status\"' \
    '\"command\": \"/Users/probeuser/.config/iterm2/cc-status\"' \
    '\"command\": \"/Users/probeuser/.config/iterm2/cc-status\"' | '${FILTER}'"
  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${output}" | grep -c 'Users/probeuser')" -eq 0 ]
}
