#!/usr/bin/env bats
# Tests for the stale-symlink prune step in install.sh.
#
# Why this exists: install.sh creates one symlink per tracked file and never
# removed any. When a file (or a whole skill) was deleted from the repo, its
# ~/.claude link stayed behind pointing at nothing, on every machine that had
# ever run install.sh. The prune step removes links that point into REPO_DIR at
# a target that no longer exists, then removes directories the prune emptied.
#
# Links that point anywhere else (plugin caches, claude.ai-synced skills,
# debug/latest) are not install.sh's to manage and must be left alone, even
# when dangling.
#
# Same isolation as test_install_sync_dry_run.bats: a throwaway repo and a
# throwaway HOME, so the developer's real ~/.claude is never touched.
#
# Run: bats ~/.claude/tests/test_install_prune_stale_links.bats

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  export TMPDIR_TEST

  FAKE_REPO="${TMPDIR_TEST}/repo"
  FAKE_HOME="${TMPDIR_TEST}/home"
  DEPLOY="${FAKE_HOME}/.claude"
  export FAKE_REPO FAKE_HOME DEPLOY
  mkdir -p "${FAKE_REPO}" "${DEPLOY}"

  git -C "${FAKE_REPO}" init -q
  git -C "${FAKE_REPO}" config user.email "test@test.com"
  git -C "${FAKE_REPO}" config user.name "Test"

  cp "${BATS_TEST_DIRNAME}/../install.sh" "${FAKE_REPO}/install.sh"
  printf '{}\n' >"${FAKE_REPO}/settings.json"
  printf '# test\n' >"${FAKE_REPO}/CLAUDE.md"
  mkdir -p "${FAKE_REPO}/hooks"
  printf '#!/usr/bin/env bash\n' >"${FAKE_REPO}/hooks/run-review.sh"
  # Non-dry runs smoke-test hooks for the executable bit; a failure there
  # would mask the prune results as a non-zero exit.
  chmod +x "${FAKE_REPO}/hooks/run-review.sh"
  git -C "${FAKE_REPO}" add install.sh settings.json CLAUDE.md hooks/run-review.sh
  GIT_CONFIG_GLOBAL=/dev/null git -C "${FAKE_REPO}" commit -q -m "initial"

  # A skill that was deleted from the repo: its deployed directory holds only
  # a link into the repo whose target is gone.
  mkdir -p "${DEPLOY}/skills/removed-skill"
  ln -s "${FAKE_REPO}/skills/removed-skill/SKILL.md" "${DEPLOY}/skills/removed-skill/SKILL.md"

  # A deleted script whose directory also holds a user file, so the directory
  # must survive the prune.
  mkdir -p "${DEPLOY}/scripts"
  ln -s "${FAKE_REPO}/scripts/removed.sh" "${DEPLOY}/scripts/removed.sh"
  printf 'keep\n' >"${DEPLOY}/scripts/user-file.txt"

  # A dangling link that does NOT point into the repo.
  mkdir -p "${DEPLOY}/debug"
  ln -s "${TMPDIR_TEST}/elsewhere/missing" "${DEPLOY}/debug/latest"
}

teardown() {
  rm -rf "${TMPDIR_TEST}"
}

run_install() {
  HOME="${FAKE_HOME}" bash "${FAKE_REPO}/install.sh" "$@" 2>&1
}

@test "sync removes a dangling link that points into the repo" {
  run run_install --sync
  [ "${status}" -eq 0 ]
  [[ ! -L "${DEPLOY}/scripts/removed.sh" ]]
  [[ ! -L "${DEPLOY}/skills/removed-skill/SKILL.md" ]]
}

@test "full install also removes a dangling repo link" {
  run run_install
  [[ ! -L "${DEPLOY}/scripts/removed.sh" ]]
}

@test "repair also removes a dangling repo link" {
  # update-tools.sh (the nightly `updates` path) only ever calls --repair.
  run run_install --repair
  [ "${status}" -eq 0 ]
  [[ ! -L "${DEPLOY}/scripts/removed.sh" ]]
  [[ ! -d "${DEPLOY}/skills/removed-skill" ]]
}

@test "sync keeps a dangling link that points outside the repo" {
  run run_install --sync
  [ "${status}" -eq 0 ]
  [[ -L "${DEPLOY}/debug/latest" ]]
}

@test "sync keeps healthy links to tracked files" {
  run run_install --sync
  [ "${status}" -eq 0 ]
  [[ -L "${DEPLOY}/settings.json" && -e "${DEPLOY}/settings.json" ]]
}

@test "sync removes a directory the prune emptied" {
  run run_install --sync
  [ "${status}" -eq 0 ]
  [[ ! -d "${DEPLOY}/skills/removed-skill" ]]
}

@test "sync keeps a directory that still holds other files" {
  run run_install --sync
  [ "${status}" -eq 0 ]
  [[ -f "${DEPLOY}/scripts/user-file.txt" ]]
}

@test "sync reports each pruned link" {
  run run_install --sync
  [[ "${output}" == *"pruned:${DEPLOY}/scripts/removed.sh"* ]]
}

@test "dry run lists stale links but removes nothing" {
  run run_install --sync --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Would remove stale symlink: ${DEPLOY}/scripts/removed.sh"* ]]
  [[ "${output}" == *"prune:${DEPLOY}/scripts/removed.sh"* ]]
  [[ -L "${DEPLOY}/scripts/removed.sh" ]]
  [[ -d "${DEPLOY}/skills/removed-skill" ]]
}

# --- #439: --repair must not call a broken tree "healthy" ---------------------
#
# --repair printed "All symlinks healthy — nothing to repair" while a tracked
# file had no link at all (a missing hook link silently disables that hook),
# and it printed it before the prune step had looked for stale links.

@test "#439: repair names a tracked file with no link and does not say healthy" {
  # Fresh DEPLOY: no tracked file has a link yet.
  run run_install --repair
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"All symlinks healthy"* ]]
  [[ "${output}" == *"Missing symlink: ${DEPLOY}/hooks/run-review.sh"* ]]
  [[ "${output}" == *"NOT healthy"* ]]
  # --repair still creates no links; --sync does.
  [[ ! -e "${DEPLOY}/hooks/run-review.sh" ]]
}

@test "#439: repair does not say healthy when it pruned a stale link" {
  run run_install --sync
  [ "${status}" -eq 0 ]
  ln -s "${FAKE_REPO}/scripts/gone.sh" "${DEPLOY}/scripts/gone.sh"

  run run_install --repair
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"All symlinks healthy"* ]]
  [[ "${output}" == *"1 stale link(s) pruned"* ]]
  [[ ! -L "${DEPLOY}/scripts/gone.sh" ]]
}

@test "#439: repair says healthy only when every tracked file is linked and nothing is stale" {
  run run_install --sync
  [ "${status}" -eq 0 ]

  run run_install --repair
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"All symlinks healthy"* ]]
  [[ "${output}" != *"Missing symlink"* ]]
}
