#!/usr/bin/env bats
# Tests for install.sh's ~/.local/bin/claude-incognito PATH link.
#
# install.sh links ${HOME}/.local/bin/claude-incognito to the DEPLOYED copy at
# ${HOME}/.claude/scripts/claude-incognito.sh (the same shape as
# ~/.local/bin/merge-lock -> ~/.claude/hooks/merge-lock.sh).
#
# This uses its own fixture rather than extending
# test_install_sync_dry_run.bats: that fixture deliberately has no
# scripts/claude-incognito.sh, and its "nothing pending" case pre-creates
# links only under .claude/, so adding the script there would make the
# ~/.local/bin link count as pending work.
#
# Isolation: install.sh derives REPO_DIR from ${BASH_SOURCE[0]} and DEPLOY_DIR
# from ${HOME}, so a throwaway repo plus a throwaway HOME is sufficient.
#
# Run: bats ~/Developer/claude-config/tests/test_install_claude_incognito_link.bats

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  FAKE_REPO="${TMPDIR_TEST}/repo"
  FAKE_HOME="${TMPDIR_TEST}/home"
  mkdir -p "${FAKE_REPO}" "${FAKE_HOME}"

  git -C "${FAKE_REPO}" init -q
  git -C "${FAKE_REPO}" config user.email "test@test.com"
  git -C "${FAKE_REPO}" config user.name "Test"

  # Canary files install.sh requires, plus a stub claude-incognito.sh.
  cp "${BATS_TEST_DIRNAME}/../install.sh" "${FAKE_REPO}/install.sh"
  printf '{}\n' >"${FAKE_REPO}/settings.json"
  printf '# test\n' >"${FAKE_REPO}/CLAUDE.md"
  mkdir -p "${FAKE_REPO}/hooks" "${FAKE_REPO}/scripts"
  printf '#!/usr/bin/env bash\n' >"${FAKE_REPO}/hooks/run-review.sh"
  printf '#!/usr/bin/env bash\n' >"${FAKE_REPO}/scripts/claude-incognito.sh"
  # Non-dry-run smoke tests fail on a non-executable hook, so both are +x.
  chmod +x "${FAKE_REPO}/hooks/run-review.sh" "${FAKE_REPO}/scripts/claude-incognito.sh"
  git -C "${FAKE_REPO}" add install.sh settings.json CLAUDE.md \
    hooks/run-review.sh scripts/claude-incognito.sh
  GIT_CONFIG_GLOBAL=/dev/null git -C "${FAKE_REPO}" commit -q -m "initial"

  LINK="${FAKE_HOME}/.local/bin/claude-incognito"
  WANT="${FAKE_HOME}/.claude/scripts/claude-incognito.sh"
}

teardown() {
  rm -rf "${TMPDIR_TEST}"
}

run_install() {
  HOME="${FAKE_HOME}" bash "${FAKE_REPO}/install.sh" "$@" 2>&1
}

@test "--sync creates ~/.local/bin/claude-incognito pointing into ~/.claude" {
  run run_install --sync
  [[ "${status}" -eq 0 ]]
  [[ -L "${LINK}" ]]
  [[ "$(readlink "${LINK}")" == "${WANT}" ]]
  # The chain resolves: ~/.local/bin -> ~/.claude/scripts -> repo.
  [[ -x "${LINK}" ]]
}

@test "rerun is idempotent: link skipped, not reinstalled" {
  run run_install --sync
  [[ "${status}" -eq 0 ]]
  run run_install --sync
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == *"Symlink already correct: ${LINK}"* ]]
  [[ "${output}" == *"already matches repo"* ]]
}

@test "dry run creates nothing and reports the link as pending" {
  run run_install --sync --dry-run
  [[ "${status}" -eq 0 ]]
  [[ ! -e "${FAKE_HOME}/.local" ]]
  [[ "${output}" == *"symlink:${LINK}"* ]]
}

@test "dry run after install reports nothing pending" {
  run run_install --sync
  [[ "${status}" -eq 0 ]]
  run run_install --sync --dry-run
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == *"already matches repo"* ]]
}

@test "full (non-sync) install also creates the link" {
  run run_install
  [[ "${status}" -eq 0 ]]
  [[ "$(readlink "${LINK}")" == "${WANT}" ]]
}

@test "missing script is skipped, not a failure" {
  git -C "${FAKE_REPO}" rm -q scripts/claude-incognito.sh
  GIT_CONFIG_GLOBAL=/dev/null git -C "${FAKE_REPO}" commit -q -m "drop"
  run run_install --sync
  [[ "${status}" -eq 0 ]]
  [[ ! -e "${LINK}" ]]
  [[ ! -L "${LINK}" ]]
}

@test "present but untracked script is skipped (link would dangle)" {
  git -C "${FAKE_REPO}" rm -q --cached scripts/claude-incognito.sh
  GIT_CONFIG_GLOBAL=/dev/null git -C "${FAKE_REPO}" commit -q -m "untrack"
  [[ -f "${FAKE_REPO}/scripts/claude-incognito.sh" ]]
  run run_install --sync
  [[ "${status}" -eq 0 ]]
  [[ ! -L "${LINK}" ]]
}
