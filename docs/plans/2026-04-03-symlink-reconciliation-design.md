# Symlink Reconciliation: claude-config → ~/.claude

**Date:** 2026-04-03
**Status:** Design

## Problem

`~/Developer/claude-config` and `~/.claude` are independent git clones of the same repo. Edits made in one don't appear in the other. The dotfiles repo solved this same problem by making the repo canonical and symlinking tracked files to the deploy location.

## Design

### Mapping

```
~/Developer/claude-config/<file>  →  ~/.claude/<file>   (symlink)
```

Only git-tracked files are symlinked. Runtime directories (`projects/`, `sessions/`, `tasks/`, `todos/`, `telemetry/`, `memory/`, `cache/`, `debug/`, `file-history/`, `shell-snapshots/`, `merge-locks/`, `paste-cache/`, `logs/`, `channels/`, `backups/`) are untouched — they live only in `~/.claude` and are already in `.gitignore`.

### Excluded from symlinking

Repo-meta files that should not appear in `~/.claude`:

- `.github/*`
- `.gitignore`
- `.gitmodules`
- `.gitattributes`
- `.editorconfig`
- `.flake8`
- `.pre-commit-config.yaml`
- `README.md`, `*/README.md`
- `install.sh`
- `Makefile` (if added later)
- `docs/plans/*`
- `LICENSE*`
- Test files: `*.bats`, `*.test.*`, `*.spec.*`, `test-*.sh`

### Submodules

Submodule directories are symlinked as **directory-level symlinks**, not per-file. The submodule repos live in `~/Developer/claude-config/.git/modules/` and the symlinked directories reference them correctly.

Current submodules:

- `plugins/marketplaces/superpowers-marketplace`

### Pre-flight: Reconcile local modifications

Before removing `~/.claude/.git`:

1. Diff `~/.claude` against `~/Developer/claude-config` for tracked files
2. Apply any local-only changes to `~/Developer/claude-config` (known: `hooks/run-review.sh` line 424 change, submodule state)
3. Commit reconciliation to a branch in `~/Developer/claude-config`

### install.sh

Modeled on `~/Developer/dotfiles/install.sh`. Key functions:

#### `_ensure_symlink(target, link)`

- If symlink exists pointing to correct target → skip
- If regular file exists → back up to `~/.claude/backups/symlink-migration/` with timestamp, then create symlink
- If symlink exists pointing elsewhere → remove and recreate
- If nothing exists → create parent dir if needed, create symlink

#### `_is_excluded(file)`

- Returns 0 if file matches exclusion list above

#### `_is_submodule_path(file)`

- Returns 0 if file is inside a submodule directory
- Submodule roots get directory-level symlinks instead of per-file

#### Main flow

```
1. Pre-flight checks (macOS, repo exists, critical files present, not root)
2. Parse flags: --dry-run, --repair
3. Discover files via `git ls-files` in ~/Developer/claude-config
4. For each tracked file:
   a. Skip if excluded
   b. Skip if inside submodule (handled separately)
   c. _ensure_symlink ~/Developer/claude-config/<file> ~/.claude/<file>
5. For each submodule root:
   a. _ensure_symlink (directory) ~/Developer/claude-config/<submod> ~/.claude/<submod>
6. Smoke tests:
   a. Verify all symlinks resolve
   b. Verify settings.json is linked
   c. Verify hooks/ scripts are linked and executable
```

#### `--repair` mode

Calls `repair_symlinks()` which:

- Iterates tracked files
- If `~/.claude/<file>` is a regular file where a symlink should be (atomic write artifact):
  - Compares content; if different, copies content back to repo
  - Removes regular file, creates symlink
- Reports count of repairs

#### `--dry-run` mode

Prints what would be done without making changes.

### Removing ~/.claude/.git

After install.sh successfully creates all symlinks:

1. Verify all symlinks resolve correctly
2. `rm -rf ~/.claude/.git ~/.claude/.gitignore ~/.claude/.gitmodules ~/.claude/.pre-commit-config.yaml ~/.claude/.flake8`
3. Remove any other repo-meta files that were tracked but excluded from symlinking

This is a one-time manual step, not part of install.sh (too destructive for automation).

### Active state management: update-tools.sh + audit

`~/.claude` is actively managed by multiple actors (user, Claude Code, Anthropic upgrades, plugins). New files can appear that the user wants to track but doesn't know about. An audit mechanism detects drift.

#### scripts/update-tools.sh

Previously existed in commit `c85caaa` (lost during rebase). Resurrected and extended. Called automatically by `_claude_update()` in the user's shell `updates` command.

Responsibilities:

1. **Symlink repair** — run `install.sh --repair`
2. **Submodule updates** — `git -C $REPO_DIR submodule update --remote`
3. **Audit** — categorize all files in `~/.claude` into three buckets:
   - **Symlinked** — tracked file, correctly linked. OK.
   - **Known runtime** — files/dirs expected from Claude Code. Ignored.
   - **Unknown** — neither symlinked nor known-runtime. Reported for human decision.

#### Known-runtime list

Maintained in `install.sh` as a bash array. Includes:

- Runtime dirs: `projects/`, `sessions/`, `tasks/`, `todos/`, `telemetry/`, `memory/`, `cache/`, `debug/`, `file-history/`, `shell-snapshots/`, `merge-locks/`, `paste-cache/`, `logs/`, `channels/`, `backups/`, `agents-local/`
- Runtime files: `.claude.json`, `mcp.json`, `mcp-needs-auth-cache.json`, `stats-cache.json`, `blocked-commands.log`, `last-review-result.log`, `settings.local.json`, `*.jsonl`, `installed_plugins.json`, `known_marketplaces.json`
- Grows over time as new Claude Code managed paths are discovered

#### Trigger

Runs when user invokes `updates` from their shell. `_claude_update()` in `~/.config/bash/functions.sh` checks for `~/.claude/scripts/update-tools.sh` and calls it. Output goes to the existing `_update_log` mechanism. Non-blocking — reports unknown files but doesn't fail.

### Symlink repair hook (future)

Like dotfiles, add a pre-commit hook integration in `~/Developer/claude-config` that calls repair logic. This catches atomic writes from editors/tools that replace symlinks with regular files.

## Files to create

1. `install.sh` — Main install/repair script (~200-300 lines)
2. `scripts/update-tools.sh` — Audit + repair + submodule update (~80-100 lines)
3. Update `.gitignore` — Add `docs/plans/` if not already present

## Execution order

1. Reconcile local modifications from `~/.claude` into `~/Developer/claude-config` on a branch
2. Create `install.sh`
3. Create `scripts/update-tools.sh`
4. Test with `--dry-run`
5. Run for real — create symlinks, verify
6. Manually remove `~/.claude/.git` and repo-meta files
7. Verify everything works (Claude Code sessions, hooks, settings)

## Success criteria

- `install.sh` is idempotent — safe to run repeatedly
- `install.sh --dry-run` shows planned actions without side effects
- `install.sh --repair` fixes broken symlinks
- All git-tracked files (minus exclusions) are symlinked from repo to `~/.claude`
- Submodule directories are directory-level symlinks
- Runtime state in `~/.claude` is completely untouched
- Existing backup mechanism preserves files replaced by symlinks
- `update-tools.sh` repairs symlinks, updates submodules, and reports unknown files
- `_claude_update()` successfully calls `update-tools.sh` via the symlink
