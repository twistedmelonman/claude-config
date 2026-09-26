#!/usr/bin/env bash

# Re-exec under bash if invoked as "sh install.sh"
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@" || {
    echo "Error: bash is required but not found in PATH" >&2
    exit 1
  }
fi

set -euo pipefail
unset CDPATH

# ~/Developer/claude-config/install.sh
# Idempotent symlink installer for Claude Code configuration.
# Creates per-file symlinks from this repo into ~/.claude/.
# Safe to re-run at any time — checks before acting.

# ── Formatting helpers ───────────────────────────────────
_info() { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
_ok() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
_warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
_err() { printf '\033[1;31m[ERR]\033[0m   %s\n' "$*" >&2; }
_skip() {
  printf '\033[0;90m[SKIP]\033[0m  %s\n' "$*"
  skipped+=("$*")
}
_dry() { printf '\033[1;35m[DRY]\033[0m   %s\n' "$*"; }

# ── Tracking arrays ─────────────────────────────────────
installed=()
skipped=()
failures=()
# Dry-run counterpart to installed[]: the DRY_RUN early-return paths never
# reach the installed+=() at the end of _ensure_symlink, so without this the
# --sync --dry-run summary reported zero pending work and printed "deployed
# tree already matches repo" even with items queued up (claude-config#344).
would_install=()

# ── Constants ────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${HOME}/.claude"
BACKUP_DIR="${DEPLOY_DIR}/backups/symlink-migration"

# ── Parse arguments ─────────────────────────────────────
DRY_RUN=false
REPAIR_ONLY=false
SYNC_ONLY=false
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=true ;;
    --repair) REPAIR_ONLY=true ;;
    --sync) SYNC_ONLY=true ;;
    --help)
      echo "Usage: install.sh [--dry-run] [--repair] [--sync] [--help]"
      echo ""
      echo "  --dry-run  Show what would be done without making changes"
      echo "  --repair   Repair broken symlinks only (no new installs)"
      echo "  --sync     Repair broken symlinks AND install newly-added files"
      echo "  --help     Show this help message"
      exit 0
      ;;
    *)
      _err "Unknown argument: ${arg}"
      echo "Usage: install.sh [--dry-run] [--repair] [--sync] [--help]"
      exit 1
      ;;
  esac
done

if [[ "${REPAIR_ONLY}" == true && "${SYNC_ONLY}" == true ]]; then
  _err "--repair and --sync are mutually exclusive (--sync already repairs)"
  exit 1
fi

if [[ "${DRY_RUN}" == true ]]; then
  _info "Dry-run mode — no changes will be made"
fi

# ============================================================================
# 1. PRE-FLIGHT CHECKS
# ============================================================================

detected_os="$(uname -s)" || true
if [[ "${detected_os}" != "Darwin" ]]; then
  _err "This script is designed for macOS (Darwin). Detected: ${detected_os}"
  exit 1
fi

if [[ ! -d "${REPO_DIR}/.git" ]]; then
  _err "Not a git repository: ${REPO_DIR}"
  _err "This script must be run from the claude-config repo root."
  exit 1
fi

if [[ ! -f "${REPO_DIR}/settings.json" ]]; then
  _err "Canary file missing: ${REPO_DIR}/settings.json"
  exit 1
fi

if [[ ! -f "${REPO_DIR}/CLAUDE.md" ]]; then
  _err "Canary file missing: ${REPO_DIR}/CLAUDE.md"
  exit 1
fi

if [[ ! -f "${REPO_DIR}/hooks/run-review.sh" ]]; then
  _err "Canary file missing: ${REPO_DIR}/hooks/run-review.sh"
  exit 1
fi

if [[ "${EUID}" -eq 0 ]]; then
  _err "Do not run this script as root."
  exit 1
fi

_ok "Pre-flight checks passed (macOS, git repo at ${REPO_DIR}, non-root)"

# ============================================================================
# 2. SUBMODULE ROOTS
# ============================================================================

_SUBMODULE_ROOTS=()
while IFS= read -r sm; do
  [[ -n "${sm}" ]] && _SUBMODULE_ROOTS+=("${sm}")
done < <(git -C "${REPO_DIR}" submodule --quiet foreach "echo \$sm_path" 2>/dev/null || true)

if [[ ${#_SUBMODULE_ROOTS[@]} -gt 0 ]]; then
  _info "Found ${#_SUBMODULE_ROOTS[@]} submodule(s): ${_SUBMODULE_ROOTS[*]}"
fi

# Cache tracked file list (avoids repeated git ls-files + fixes SC2312)
_TRACKED_FILES=()
while IFS= read -r _tf; do
  _TRACKED_FILES+=("${_tf}")
done < <(git -C "${REPO_DIR}" ls-files || true)

# ============================================================================
# 3. HELPER FUNCTIONS
# ============================================================================

_is_excluded() {
  case "$1" in
    # CI / GitHub metadata
    .github/*) return 0 ;;
    # Git files
    .gitignore) return 0 ;;
    .gitmodules) return 0 ;;
    .gitattributes) return 0 ;;
    # Repo management
    .editorconfig) return 0 ;;
    .flake8) return 0 ;;
    .pre-commit-config.yaml) return 0 ;;
    # Documentation
    README.md) return 0 ;;
    */README.md) return 0 ;;
    # This script
    install.sh) return 0 ;;
    # Plans
    docs/plans/*) return 0 ;;
    # Licensing
    LICENSE*) return 0 ;;
    # Test files
    *.bats) return 0 ;;
    test-*.sh) return 0 ;;
    tests/*) return 0 ;;
    scripts/tests/*) return 0 ;;
    hooks/tests/*) return 0 ;;
    *) return 1 ;;
  esac
}

_is_submodule_path() {
  local file="$1"
  for sm_path in "${_SUBMODULE_ROOTS[@]+"${_SUBMODULE_ROOTS[@]}"}"; do
    case "${file}" in
      "${sm_path}"/*) return 0 ;;
      *) ;;
    esac
  done
  return 1
}

_ensure_symlink() {
  local target="$1" link="$2"

  if [[ -L "${link}" ]]; then
    local current
    current="$(readlink "${link}")"
    if [[ "${current}" == "${target}" ]]; then
      _skip "Symlink already correct: ${link}"
      return
    fi
    _warn "Symlink ${link} points to ${current}, replacing"
    if [[ "${DRY_RUN}" == true ]]; then
      _dry "Would replace symlink: ${link} -> ${target}"
      would_install+=("symlink:${link}")
      return
    fi
    rm "${link}"
  fi

  if [[ "${DRY_RUN}" == true ]]; then
    if [[ -e "${link}" ]]; then
      _dry "Would back up and replace: ${link}"
    else
      _dry "Would symlink: ${link} -> ${target}"
    fi
    would_install+=("symlink:${link}")
    return
  fi

  # Back up existing regular file
  if [[ -e "${link}" ]]; then
    mkdir -p "${BACKUP_DIR}"
    local backup_name
    backup_name="${link#"${DEPLOY_DIR}/"}"
    backup_name="${backup_name//\//_}.$(date +%Y%m%d%H%M%S)"
    mv "${link}" "${BACKUP_DIR}/${backup_name}"
    _warn "Backed up ${link} to ${BACKUP_DIR}/${backup_name}"
  fi

  mkdir -p "$(dirname "${link}")"
  ln -s "${target}" "${link}"
  _ok "Created symlink: ${link} -> ${target}"
  installed+=("symlink:${link}")
}

# ============================================================================
# 4. REPAIR MODE
# ============================================================================

# Counts read by the --repair health verdict below (#439). --repair used to say
# "All symlinks healthy" while a tracked file had no link at all, and before
# the prune step had even looked for stale ones.
REPAIR_COUNT=0
MISSING_COUNT=0
PRUNE_COUNT=0
WRONG_TARGET_COUNT=0
NOEXEC_COUNT=0

# A deployed hook that is absent, dangling or not executable is SKIPPED, not
# failed: hook-block-all.sh runs each sub-hook only `if [[ -x "${hook}" ]]`.
# These are the tracked paths that guard applies to (the dispatcher's
# sub-hooks live in scripts/, the git/review hooks in hooks/).
_is_hook_path() {
  case "$1" in
    hooks/*.sh | scripts/hook-*) return 0 ;;
    *) return 1 ;;
  esac
}

repair_symlinks() {
  local repair_count=0

  _info "Repair mode — checking for broken symlinks..."

  for file in "${_TRACKED_FILES[@]}"; do
    _is_excluded "${file}" && continue
    _is_submodule_path "${file}" && continue

    local link="${DEPLOY_DIR}/${file}"
    local target="${REPO_DIR}/${file}"

    # A tracked file with no link at all. --repair does not create links
    # (--sync does), but it must not call this state healthy: a missing hook
    # link silently disables that hook (hook-block-all.sh skips a hook that
    # is not executable). --sync creates these in its main loop, so only
    # --repair reports them.
    if [[ ! -e "${link}" && ! -L "${link}" ]]; then
      if ${REPAIR_ONLY}; then
        _warn "Missing symlink: ${link} (tracked file has no link; run install.sh --sync)"
        ((MISSING_COUNT += 1))
      fi
      continue
    fi

    # A dangling link at a TRACKED path whose target is outside REPO_DIR: an
    # old clone location, a deleted worktree, another spelling of the repo
    # path. prune_stale_symlinks skips it (its prefix test only owns links
    # into REPO_DIR), so before #439 --repair saw a link, not a regular file,
    # and called it healthy while the hook it stood for was skipped. The old
    # target is gone, so relinking loses nothing.
    local current=""
    if [[ -L "${link}" ]]; then
      current="$(readlink "${link}")" || current=""
    fi

    if [[ -L "${link}" && ! -e "${link}" ]]; then
      if [[ "${DRY_RUN}" == true ]]; then
        _dry "Would relink dangling symlink: ${link} -> ${target} (was ${current})"
        would_install+=("repair:${link}")
        ((repair_count += 1))
        continue
      fi
      _warn "Dangling symlink: ${link} -> ${current}, relinking"
      rm "${link}"
      ln -s "${target}" "${link}"
      _ok "Repaired: ${link} -> ${target}"
      ((repair_count += 1))
      current="${target}"
    fi

    # A link that resolves, but not to this repo's copy (compared as the same
    # string _ensure_symlink compares). It works, so --repair, which runs
    # unattended from update-tools.sh, does not replace it: it could be a
    # deliberate local override. It is still not "healthy"; --sync replaces
    # it, as _ensure_symlink always has.
    if [[ -L "${link}" && "${current}" != "${target}" ]]; then
      if ${REPAIR_ONLY}; then
        _warn "Symlink points somewhere other than this repo: ${link} -> ${current} (run install.sh --sync to relink)"
        ((WRONG_TARGET_COUNT += 1))
      fi
    fi

    # A hook whose deployed path resolves but is not executable is skipped by
    # hook-block-all.sh without a word. Report it; do not chmod here, because
    # the mode is tracked in git and the fix belongs in the repo. --repair
    # only: --sync reports it later, from the smoke test (hooks/*.sh) and the
    # symlink health check (scripts/hook-*), which also make --sync fail.
    if ${REPAIR_ONLY} && _is_hook_path "${file}" &&
      [[ -e "${link}" && ! -d "${link}" && ! -x "${link}" ]]; then
      _warn "Hook not executable, so it never runs: ${link}"
      ((NOEXEC_COUNT += 1))
    fi

    # Only repair files that exist as regular files where symlinks should be
    if [[ -f "${link}" && ! -L "${link}" ]]; then
      if [[ "${DRY_RUN}" == true ]]; then
        _dry "Would repair: ${link} -> ${target}"
        # Repairs are pending work too — the non-dry path rewrites the link,
        # so the dry-run summary must count them or it under-reports.
        would_install+=("repair:${link}")
        ((repair_count += 1))
        continue
      fi
      # Compare content — if deploy copy has edits, preserve them and stage
      if ! diff -q "${link}" "${target}" &>/dev/null; then
        _warn "Content differs — copying ${link} back to repo and staging"
        cp "${link}" "${target}"
        git -C "${REPO_DIR}" add "${file}" || _warn "git add failed for ${file} — stage manually"
      fi
      rm "${link}"
      ln -s "${target}" "${link}"
      _ok "Repaired: ${link} -> ${target}"
      ((repair_count += 1))
    fi
  done

  REPAIR_COUNT="${repair_count}"
  if [[ "${repair_count}" -gt 0 ]]; then
    _ok "Repaired ${repair_count} symlink(s)"
  fi
}

# ============================================================================
# 4b. PRUNE STALE SYMLINKS
# ============================================================================
# The main loop only ever creates links. When a file (or a whole skill) is
# deleted from the repo, its link stays behind in DEPLOY_DIR pointing at
# nothing, on every machine that ever ran install.sh. Remove those links, then
# remove any directory the prune left empty. Every mode runs this, --repair
# included: update-tools.sh (the `updates` path) only ever calls --repair.
#
# Only links whose target is inside REPO_DIR AND missing are removed. That
# prefix test is what keeps this away from links install.sh does not own
# (plugin caches, claude.ai-synced skills, debug/latest), dangling or not.
# The -prune list only skips large runtime trees for speed; correctness does
# not depend on it.

prune_stale_symlinks() {
  local link target dir
  local prune_dirs=()

  while IFS= read -r -d '' link; do
    target="$(readlink "${link}")" || continue
    [[ "${target}" == "${REPO_DIR}/"* ]] || continue
    [[ -e "${link}" ]] && continue

    if [[ "${DRY_RUN}" == true ]]; then
      _dry "Would remove stale symlink: ${link} -> ${target}"
      would_install+=("prune:${link}")
      ((PRUNE_COUNT += 1))
      continue
    fi
    if rm "${link}"; then
      _ok "Removed stale symlink: ${link} -> ${target}"
      ((PRUNE_COUNT += 1))
      installed+=("pruned:${link}")
      prune_dirs+=("$(dirname "${link}")")
    else
      _err "Failed to remove stale symlink: ${link}"
      failures+=("prune-failed:${link}")
    fi
  done < <(find "${DEPLOY_DIR}" \
    \( -path "${DEPLOY_DIR}/plugins" -o -path "${DEPLOY_DIR}/projects" \
    -o -path "${DEPLOY_DIR}/file-history" -o -path "${DEPLOY_DIR}/backups" \
    -o -path "${DEPLOY_DIR}/shell-snapshots" \) -prune \
    -o -type l -print0 2>/dev/null || true)

  # Walk up from each pruned link's directory, removing directories that are
  # now empty. rmdir refuses a non-empty directory, so user files keep theirs.
  for dir in "${prune_dirs[@]+"${prune_dirs[@]}"}"; do
    while [[ "${dir}" == "${DEPLOY_DIR}/"* ]] && rmdir "${dir}" 2>/dev/null; do
      _ok "Removed empty directory: ${dir}"
      dir="$(dirname "${dir}")"
    done
  done
}

if ${REPAIR_ONLY}; then
  repair_symlinks
  prune_stale_symlinks
  # The verdict comes last, after every check has run, and says "healthy"
  # only when none of them found anything (#439). Exit status stays 0:
  # update-tools.sh runs --repair under set -e, and a missing link is a
  # warning to act on, not a reason to abort the nightly update.
  if [[ ${#failures[@]} -gt 0 ]]; then
    _warn "NOT healthy: ${#failures[@]} step(s) failed (see errors above)"
  elif [[ "${MISSING_COUNT}" -gt 0 || "${WRONG_TARGET_COUNT}" -gt 0 || "${NOEXEC_COUNT}" -gt 0 ]]; then
    if [[ "${MISSING_COUNT}" -gt 0 ]]; then
      _warn "NOT healthy: ${MISSING_COUNT} tracked file(s) have no symlink. --repair does not create links; run install.sh --sync"
    fi
    if [[ "${WRONG_TARGET_COUNT}" -gt 0 ]]; then
      _warn "NOT healthy: ${WRONG_TARGET_COUNT} symlink(s) point somewhere other than this repo; run install.sh --sync"
    fi
    if [[ "${NOEXEC_COUNT}" -gt 0 ]]; then
      _warn "NOT healthy: ${NOEXEC_COUNT} hook(s) not executable, so hook-block-all.sh skips them; chmod +x in the repo and commit"
    fi
    if [[ "${REPAIR_COUNT}" -gt 0 || "${PRUNE_COUNT}" -gt 0 ]]; then
      _info "Also fixed: ${REPAIR_COUNT} repaired, ${PRUNE_COUNT} stale link(s) pruned"
    fi
  elif [[ "${REPAIR_COUNT}" -eq 0 && "${PRUNE_COUNT}" -eq 0 ]]; then
    _ok "All symlinks healthy — nothing to repair"
  elif [[ "${DRY_RUN}" == true ]]; then
    _dry "Repair would fix ${REPAIR_COUNT} link(s) and prune ${PRUNE_COUNT} stale link(s)"
  else
    _ok "Repair complete: ${REPAIR_COUNT} repaired, ${PRUNE_COUNT} stale link(s) pruned"
  fi
  exit 0
fi

# Sync mode runs repair first: repair_symlinks copies edited deploy content
# back to the repo before restoring the link, whereas _ensure_symlink would
# back the file up and overwrite. Repair must win, then the main loop below
# creates symlinks for files that --repair deliberately skips (new files
# have no existing link, so repair's "regular file" test never matches).
if ${SYNC_ONLY}; then
  repair_symlinks
fi

# ============================================================================
# 5. MAIN SYMLINK LOOP
# ============================================================================

_info "Creating config symlinks from repo to ${DEPLOY_DIR}..."

for file in "${_TRACKED_FILES[@]}"; do
  _is_excluded "${file}" && continue
  _is_submodule_path "${file}" && continue

  _ensure_symlink "${REPO_DIR}/${file}" "${DEPLOY_DIR}/${file}"
done

# Runs after the main loop so a file re-added to the repo is relinked first.
prune_stale_symlinks

# ============================================================================
# 6. SUBMODULE SYMLINKS (directory-level)
# ============================================================================

if [[ ${#_SUBMODULE_ROOTS[@]} -gt 0 ]]; then
  _info "Creating submodule directory symlinks..."
  for sm_path in "${_SUBMODULE_ROOTS[@]}"; do
    _ensure_symlink "${REPO_DIR}/${sm_path}" "${DEPLOY_DIR}/${sm_path}"
  done
fi

# ============================================================================
# 7. PATH COMMANDS (~/.local/bin)
# ============================================================================
# Scripts meant to be run by hand get a ~/.local/bin link. The link targets the
# DEPLOYED copy under ${DEPLOY_DIR}, not the repo, matching
# ~/.local/bin/merge-lock -> ~/.claude/hooks/merge-lock.sh.
#
# _ensure_symlink handles dry-run, idempotency, and backup of a pre-existing
# file. An already-correct link takes its _skip path, so it never counts as
# pending work in `--sync --dry-run` (claude-config#344).
#
# The ~/.local/bin link is outside DEPLOY_DIR, so the symlink health check
# below does not cover it.

# Gate on TRACKED, not merely present: section 5 deploys tracked files only, so
# an untracked script would leave this link dangling.
_incognito_tracked=false
for _tf in "${_TRACKED_FILES[@]}"; do
  if [[ "${_tf}" == "scripts/claude-incognito.sh" ]]; then
    _incognito_tracked=true
    break
  fi
done

if ! ${_incognito_tracked}; then
  # Not an error: a checkout without the script (or the bats fixture, which
  # copies only install.sh into a throwaway repo) simply has nothing to link.
  _skip "No tracked claude-incognito script — skipping ~/.local/bin link"
elif [[ ! -x "${REPO_DIR}/scripts/claude-incognito.sh" ]]; then
  _warn "Not executable: ${REPO_DIR}/scripts/claude-incognito.sh"
  failures+=("claude-incognito-not-executable")
else
  _ensure_symlink "${DEPLOY_DIR}/scripts/claude-incognito.sh" \
    "${HOME}/.local/bin/claude-incognito"
fi

# ============================================================================
# 8. GIT CLEAN FILTER (iTerm2 cc-status home directory)
# ============================================================================
# iTerm2 rewrites settings.json's cc-status hook paths to this machine's
# absolute home directory on every launch, which dirties the tracked file
# differently on each host. .gitattributes maps settings.json to this filter,
# but filter.*.clean is LOCAL config -- it does not arrive with a clone, so it
# must be configured per machine here. Without it the filter silently no-ops
# and the drift returns. See scripts/normalize-iterm-home.sh for the full
# rationale.

_filter_script="${REPO_DIR}/scripts/normalize-iterm-home.sh"

# Already-correct config is NOT pending work: recording it in installed[] every
# run would make `--sync --dry-run` permanently claim there are items to create
# and never report "deployed tree already matches repo" (claude-config#344).
_filter_current="$(git -C "${REPO_DIR}" config --get filter.iterm-home.clean 2>/dev/null || true)"
_filter_smudge="$(git -C "${REPO_DIR}" config --get filter.iterm-home.smudge 2>/dev/null || true)"
_filter_required="$(git -C "${REPO_DIR}" config --get filter.iterm-home.required 2>/dev/null || true)"
_filter_ok=false
if [[ "${_filter_current}" == "${_filter_script}" &&
  "${_filter_smudge}" == "cat" &&
  "${_filter_required}" == "true" ]]; then
  _filter_ok=true
fi

if [[ ! -e "${_filter_script}" ]]; then
  # Not an error: a checkout without the filter script simply does not use the
  # iTerm2 normalization. Recording a failure here would make install.sh report
  # issues on any repo that predates it (and on the bats fixture, which copies
  # only install.sh into a throwaway repo).
  _skip "No iTerm2 filter script — skipping git filter setup"
elif [[ ! -x "${_filter_script}" ]]; then
  _warn "Not executable: ${_filter_script}"
  failures+=("filter-script-not-executable")
elif ${_filter_ok}; then
  _skip "git filter.iterm-home already configured"
elif [[ "${DRY_RUN}" == true ]]; then
  # Deliberately NOT added to would_install[]: that array is the deployed-tree
  # symlink tally that --sync reports on, and local git config is neither a
  # symlink nor part of the deployed tree.
  _dry "Would configure git filter.iterm-home in ${REPO_DIR}"
else
  # smudge=cat: the working tree gets the committed content verbatim; iTerm2
  # rewrites it to an absolute path on its next launch.
  #
  # required=true matters more than it looks. Without it a missing or broken
  # filter script makes git print an error, exit 0 anyway, and stage the
  # UNFILTERED content -- silently committing this machine's absolute home
  # directory, which is the exact bug this whole mechanism exists to prevent.
  # With it, git exits 128 and stages nothing.
  if git -C "${REPO_DIR}" config filter.iterm-home.clean "${_filter_script}" &&
    git -C "${REPO_DIR}" config filter.iterm-home.smudge cat &&
    git -C "${REPO_DIR}" config filter.iterm-home.required true; then
    _ok "Configured git filter.iterm-home"
    installed+=("git-filter:iterm-home")
  else
    _err "Failed to configure git filter.iterm-home"
    failures+=("git-filter:iterm-home")
  fi

  # Refresh the index stat entry for settings.json. The cleaned content is a
  # different size than the working-tree file, so git's stat-cache fast path
  # cannot short-circuit and `git status` reports a phantom " M" with no
  # content diff. Re-staging the (unchanged) cleaned content updates the
  # cached stat data and clears it for good.
  #
  # Guarded on the phantom signature: `git status` reports the file modified
  # while `git diff --quiet` (which runs the clean filter) says the content is
  # unchanged. Staging unconditionally would be a surprising side effect, and
  # staging a REAL settings.json edit would hide the user's own pending change
  # behind an already-staged file -- so a genuine edit (diff --quiet exits 1)
  # is deliberately left alone.
  _settings_status=""
  if ! _settings_status="$(git -C "${REPO_DIR}" status --porcelain settings.json 2>/dev/null)"; then
    _settings_status=""
  fi
  if [[ -e "${REPO_DIR}/settings.json" ]] &&
    [[ -n "${_settings_status}" ]] &&
    git -C "${REPO_DIR}" diff --quiet settings.json 2>/dev/null; then
    if git -C "${REPO_DIR}" add settings.json 2>/dev/null; then
      _ok "Cleared phantom index stat entry for settings.json"
    else
      _warn "Could not refresh index stat entry for settings.json"
    fi
  fi
fi

# ============================================================================
# 9. POST-INSTALL SMOKE TESTS
# ============================================================================

_info "Running smoke tests..."

if [[ "${DRY_RUN}" == true ]]; then
  _dry "Would run smoke tests (skipped in dry-run mode)"
else

  # Key files must be symlinks
  for key_file in settings.json CLAUDE.md; do
    link="${DEPLOY_DIR}/${key_file}"
    if [[ -L "${link}" ]]; then
      if [[ -e "${link}" ]]; then
        _ok "Symlink resolves: ${link}"
      else
        _warn "Broken symlink: ${link}"
        failures+=("broken-symlink:${key_file}")
      fi
    elif [[ -e "${link}" ]]; then
      _warn "Not a symlink (expected symlink): ${link}"
      failures+=("not-symlink:${key_file}")
    else
      _warn "Missing: ${link}"
      failures+=("missing:${key_file}")
    fi
  done

  # The iTerm2 clean filter must be wired up AND actually normalize. Checking
  # only that the config key exists would pass even if the script were broken,
  # so this feeds it a known-bad sample and confirms the home directory is
  # stripped (Chesterton's fence: a filter that silently no-ops looks exactly
  # like a working one until settings.json drifts on another machine).
  if [[ ! -x "${_filter_script}" ]]; then
    _skip "No iTerm2 filter script — skipping filter behavior check"
  elif git -C "${REPO_DIR}" config --get filter.iterm-home.clean >/dev/null 2>&1; then
    # Both serializers must be covered: iTerm2 escapes forward slashes, Claude
    # Code's settings writer does not. Probing only the escaped form passes
    # while the filter is blind to everything Claude Code writes.
    _filter_ok=1
    for _filter_case in \
      '"command" : "\/Users\/probeuser\/.config\/iterm2\/cc-status"|"command" : "~\/.config\/iterm2\/cc-status"' \
      '"command": "/Users/probeuser/.config/iterm2/cc-status"|"command": "~/.config/iterm2/cc-status"'; do
      _filter_probe="${_filter_case%%|*}"
      _filter_want="${_filter_case##*|}"
      _filter_got=""
      if ! _filter_got="$(printf '%s\n' "${_filter_probe}" | "${_filter_script}")"; then
        _filter_got="<filter failed>"
      fi
      if [[ "${_filter_got}" != "${_filter_want}" ]]; then
        _filter_ok=0
      fi
    done
    if [[ "${_filter_ok}" -eq 1 ]]; then
      _ok "Git filter normalizes iTerm2 cc-status paths"
    else
      _warn "Git filter did not normalize as expected"
      failures+=("git-filter-behavior")
    fi
  else
    _warn "Git filter filter.iterm-home.clean is not configured"
    failures+=("git-filter-unconfigured")
  fi

  # Hook scripts must be symlinks and executable
  for file in "${_TRACKED_FILES[@]}"; do
    case "${file}" in
      hooks/*.sh)
        _is_excluded "${file}" && continue
        link="${DEPLOY_DIR}/${file}"
        if [[ -L "${link}" ]]; then
          if [[ ! -e "${link}" ]]; then
            _warn "Broken hook symlink: ${link}"
            failures+=("broken-hook:${file}")
          elif [[ ! -x "${link}" ]]; then
            _warn "Hook not executable: ${link}"
            failures+=("not-executable:${file}")
          else
            _ok "Hook symlink OK: ${file}"
          fi
        elif [[ -e "${link}" ]]; then
          _warn "Hook not a symlink: ${link}"
          failures+=("not-symlink:${file}")
        fi
        ;;
      *) ;;
    esac
  done

fi # end dry-run skip for smoke tests

# Full symlink health check — verify all non-excluded deploy paths
if [[ "${DRY_RUN}" == true ]]; then
  _dry "Would verify symlink health for all tracked files"
else
  _info "Checking symlink health..."
  symlink_errors=0
  for file in "${_TRACKED_FILES[@]}"; do
    _is_excluded "${file}" && continue
    _is_submodule_path "${file}" && continue

    link="${DEPLOY_DIR}/${file}"
    if [[ -L "${link}" ]]; then
      if [[ ! -e "${link}" ]]; then
        _warn "Broken symlink: ${link}"
        failures+=("broken-symlink:${link}")
        ((symlink_errors += 1))
      elif [[ "${file}" == scripts/hook-* && ! -x "${link}" ]]; then
        # hook-block-all.sh skips a sub-hook that is not executable (#439).
        # The smoke test above covers hooks/*.sh; this covers the dispatcher's
        # sub-hooks in scripts/.
        _warn "Hook not executable, so it never runs: ${link}"
        failures+=("not-executable:${file}")
        ((symlink_errors += 1))
      fi
    elif [[ -e "${link}" ]]; then
      _warn "Not a symlink (expected symlink): ${link}"
      failures+=("not-symlink:${link}")
      ((symlink_errors += 1))
    else
      _warn "Missing symlink: ${link}"
      failures+=("missing-symlink:${link}")
      ((symlink_errors += 1))
    fi
  done

  if [[ "${symlink_errors}" -eq 0 ]]; then
    _ok "All config symlinks healthy"
  fi
fi

# ── Sync-mode exit ───────────────────────────────────────
# Sections 5-9 reconcile the deployed tree with the repo and verify it.
# Everything below is bootstrap-only (and section 10 is destructive), so
# --sync stops here. Exits non-zero on failures so `allup`'s `|| return $?`
# surfaces a broken deploy instead of silently continuing to `updates`.
if ${SYNC_ONLY}; then
  echo ""
  # Under --dry-run nothing was actually created, so the summary must report
  # from would_install[] instead of installed[] (which is always empty in that
  # mode). Reporting from installed[] made a dry run claim the tree already
  # matched the repo while listing [DRY] lines above it (claude-config#344).
  # This block runs at script scope, so no `local`/nameref: copy the right
  # array into a plain one and pick the matching wording.
  _sync_pending=("${installed[@]}")
  _sync_header="Sync created:"
  _sync_empty="Sync complete — deployed tree already matches repo"
  _sync_prefix="Sync complete — "
  _sync_suffix=" item(s) created"
  if [[ "${DRY_RUN}" == true ]]; then
    _sync_pending=("${would_install[@]}")
    _sync_header="Sync would create:"
    _sync_empty="Dry run complete — deployed tree already matches repo"
    _sync_prefix="Dry run complete — would create "
    _sync_suffix=" item(s)"
  fi
  if [[ ${#_sync_pending[@]} -gt 0 ]]; then
    _info "${_sync_header}"
    for item in "${_sync_pending[@]}"; do
      echo "  + ${item}"
    done
  fi
  if [[ ${#failures[@]} -gt 0 ]]; then
    _warn "Sync completed with ${#failures[@]} issue(s):"
    for item in "${failures[@]}"; do
      echo "  ! ${item}"
    done
    exit 1
  fi
  if [[ ${#_sync_pending[@]} -eq 0 ]]; then
    _ok "${_sync_empty}"
  else
    _ok "${_sync_prefix}${#_sync_pending[@]}${_sync_suffix}"
  fi
  exit 0
fi

# ============================================================================
# 10. CLEAN UP DEPLOY-DIR GIT METADATA
# ============================================================================
# If ~/.claude was previously its own git clone, remove the repo metadata.
# Tracked files are now symlinks — the git repo belongs in ~/Developer/claude-config.

# Only remove files that are git repo artifacts — not user config files.
# .pre-commit-config.yaml, .flake8, .editorconfig are repo-tooling that
# should not exist in the deploy dir, but are harmless if present.
# Safety: if REPO_DIR and DEPLOY_DIR resolve to the same path, skip —
# we'd be deleting our own repo's git data.
_resolved_repo="$(cd "${REPO_DIR}" && pwd -P)"
_resolved_deploy="$(cd "${DEPLOY_DIR}" && pwd -P)"
if [[ "${_resolved_repo}" == "${_resolved_deploy}" ]]; then
  _warn "REPO_DIR and DEPLOY_DIR are the same path — skipping git metadata cleanup"
else

  _GIT_META_FILES=(".git" ".gitignore" ".gitmodules")

  for meta in "${_GIT_META_FILES[@]}"; do
    meta_path="${DEPLOY_DIR}/${meta}"
    # Skip if it's already a symlink (managed by us)
    [[ -L "${meta_path}" ]] && continue
    if [[ -e "${meta_path}" ]]; then
      if [[ "${DRY_RUN}" == true ]]; then
        _dry "Would remove deploy-dir git metadata: ${meta_path}"
      else
        if rm -rf "${meta_path}"; then
          _ok "Removed deploy-dir git metadata: ${meta_path}"
          installed+=("removed:${meta}")
        else
          _err "Failed to remove: ${meta_path}"
          failures+=("rm-failed:${meta}")
        fi
      fi
    fi
  done

fi # end REPO_DIR != DEPLOY_DIR guard

# ============================================================================
# 11. SUMMARY
# ============================================================================

echo ""
echo "═══════════════════════════════════════════════════════"
echo " Claude Config Install Summary"
echo "═══════════════════════════════════════════════════════"

if [[ ${#installed[@]} -gt 0 ]]; then
  _info "Installed/created:"
  for item in "${installed[@]}"; do
    echo "  + ${item}"
  done
fi

if [[ ${#skipped[@]} -gt 0 ]]; then
  echo ""
  _info "Skipped (already present):"
  for item in "${skipped[@]}"; do
    echo "  - ${item}"
  done
fi

if [[ ${#failures[@]} -gt 0 ]]; then
  echo ""
  _warn "Issues found:"
  for item in "${failures[@]}"; do
    echo "  ! ${item}"
  done
fi

echo ""

if [[ ${#failures[@]} -gt 0 ]]; then
  _err "Completed with ${#failures[@]} issue(s). Review warnings above."
  exit 1
fi

_ok "All done — ${#installed[@]} installed, ${#skipped[@]} skipped, 0 failures."
