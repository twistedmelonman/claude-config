# Symlink Reconciliation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `~/Developer/claude-config` the canonical source for Claude Code configuration, with per-file symlinks into `~/.claude`.

**Architecture:** `install.sh` discovers tracked files via `git ls-files`, creates symlinks from repo to `~/.claude`, excludes repo-meta and test files. `scripts/update-tools.sh` provides ongoing repair + audit. Modeled on `~/Developer/dotfiles/install.sh`.

**Tech Stack:** Bash 5.x, git, standard POSIX tools

---

## Task 1: Create branch and reconcile local modifications

**Files:**

- Modify: `hooks/run-review.sh:424`
- Modify: `.gitignore` (add `sessions/`)

**Step 1: Create feature branch**

```bash
git -C ~/Developer/claude-config checkout -b claude/feat-symlink-reconciliation
```

**Step 2: Apply the run-review.sh fix from ~/.claude**

In `hooks/run-review.sh`, line 424, change:

```bash
if [[ ${DIFF_LINES} -gt ${REVIEW_SKIP_THRESHOLD} ]]; then
```

to:

```bash
if [[ "${REVIEW_MODE}" != "full-diff" && "${REVIEW_MODE}" != "codebase" ]] && [[ ${DIFF_LINES} -gt ${REVIEW_SKIP_THRESHOLD} ]]; then
```

**Step 3: Apply .gitignore change from ~/.claude**

Add `sessions/` to the end of `.gitignore`.

**Step 4: Update submodule pointer**

```bash
git -C ~/Developer/claude-config/plugins/marketplaces/superpowers-marketplace fetch origin
git -C ~/Developer/claude-config/plugins/marketplaces/superpowers-marketplace checkout 8560ad09fb77947975294ce5d600840dce225a42
```

**Step 5: Commit reconciliation**

```bash
git -C ~/Developer/claude-config add hooks/run-review.sh .gitignore plugins/marketplaces/superpowers-marketplace
git -C ~/Developer/claude-config commit -m "chore: reconcile local ~/.claude modifications

- hooks/run-review.sh: skip threshold bypass for full-diff/codebase modes
- .gitignore: add sessions/
- submodule: update superpowers-marketplace to latest"
```

---

## Task 2: Create install.sh

**Files:**

- Create: `install.sh`

**Step 1: Write install.sh**

The script must include these sections in order:

1. **Shebang + strict mode**: `#!/usr/bin/env bash` + `set -euo pipefail`
2. **Constants**: `REPO_DIR`, `DEPLOY_DIR="${HOME}/.claude"`, `BACKUP_DIR="${DEPLOY_DIR}/backups/symlink-migration"`
3. **Formatting helpers**: `_info`, `_ok`, `_warn`, `_err`, `_skip`, `_dry` — copy pattern from `~/Developer/dotfiles/install.sh` lines 9-19
4. **Tracking arrays**: `installed=()`, `skipped=()`, `failures=()`, `manual=()`
5. **Flag parsing**: `--dry-run` sets `DRY_RUN=true`, `--repair` enters repair-only mode
6. **Pre-flight checks**:
   - Verify macOS (`uname -s` == Darwin)
   - Verify `REPO_DIR` is a git repo
   - Verify critical files exist (`settings.json`, `CLAUDE.md`, `hooks/run-review.sh`)
   - Verify not running as root
7. **`_ensure_symlink(target, link)`** — same logic as dotfiles:
   - Symlink exists + correct target → skip
   - Symlink exists + wrong target → remove + recreate
   - Regular file exists → back up to `BACKUP_DIR` + create symlink
   - Nothing exists → `mkdir -p` parent + create symlink
8. **`_is_excluded(file)`** — returns 0 for:
   - `.github/*`, `.gitignore`, `.gitmodules`, `.gitattributes`, `.editorconfig`
   - `.flake8`, `.pre-commit-config.yaml`
   - `README.md`, `*/README.md`
   - `install.sh`, `Makefile`
   - `docs/plans/*`
   - `LICENSE*`
   - `*.bats`, `*.test.*`, `*.spec.*`, `test-*.sh`
   - `scripts/tests/*`, `hooks/tests/*`
9. **`_is_submodule(file)`** — checks if file path starts with a known submodule root. Get submodule roots dynamically: `git -C "${REPO_DIR}" submodule --quiet foreach 'echo $sm_path'`
10. **`repair_symlinks()`** — iterate tracked files, find regular files where symlinks should be, copy content back to repo if different, restore symlink. Return count of repairs.
11. **Repair-only mode**: if `--repair`, call `repair_symlinks`, exit.
12. **Main symlink loop**:

    ```
    while IFS= read -r file; do
      skip if _is_excluded
      skip if _is_submodule (handled next)
      _ensure_symlink "${REPO_DIR}/${file}" "${DEPLOY_DIR}/${file}"
    done < <(git -C "${REPO_DIR}" ls-files)
    ```

13. **Submodule symlinks**: for each submodule root, create a directory-level symlink:

    ```
    while IFS= read -r sm_path; do
      _ensure_symlink "${REPO_DIR}/${sm_path}" "${DEPLOY_DIR}/${sm_path}"
    done < <(git -C "${REPO_DIR}" submodule --quiet foreach 'echo $sm_path')
    ```

14. **Smoke tests**:
    - Verify `settings.json` is a symlink
    - Verify `CLAUDE.md` is a symlink
    - Verify all hook scripts are symlinks and executable
    - Verify all symlinks resolve (no broken links) — same pattern as dotfiles lines 382-411
15. **Summary**: counts of installed/skipped/failures, same pattern as dotfiles lines 417-466

**Step 2: Make executable**

```bash
chmod +x ~/Developer/claude-config/install.sh
```

**Step 3: Test dry-run**

```bash
~/Developer/claude-config/install.sh --dry-run
```

Expected: all files listed with "Would symlink" messages, no changes made.

**Step 4: Commit**

```bash
git -C ~/Developer/claude-config add install.sh
git -C ~/Developer/claude-config commit -m "feat: add install.sh for symlink management

Idempotent bootstrap script that symlinks tracked files from
~/Developer/claude-config to ~/.claude. Supports --dry-run and --repair."
```

---

## Task 3: Create scripts/update-tools.sh

**Files:**

- Create: `scripts/update-tools.sh`

**Step 1: Write update-tools.sh**

Called by `_claude_update()` in the user's shell. Sections:

1. **Shebang + strict mode**: `#!/usr/bin/env bash` + `set -euo pipefail`
2. **Constants**: `REPO_DIR="${HOME}/Developer/claude-config"`, `DEPLOY_DIR="${HOME}/.claude"`
3. **Formatting helpers**: same `_info`, `_ok`, `_warn` pattern
4. **Section 1 — Symlink repair**:

   ```bash
   _info "Repairing symlinks..."
   repair_output=$("${REPO_DIR}/install.sh" --repair 2>&1)
   repair_result=$?
   echo "${repair_output}"
   ```

5. **Section 2 — Submodule updates**:

   ```bash
   _info "Updating submodules..."
   git -C "${REPO_DIR}" submodule update --remote --merge 2>&1
   ```

6. **Section 3 — Audit**:
   - **Known-runtime patterns** — a bash array of glob patterns for files/dirs Claude Code manages:

     ```bash
     _KNOWN_RUNTIME=(
       "projects" "sessions" "tasks" "todos" "telemetry" "memory"
       "cache" "debug" "file-history" "shell-snapshots" "merge-locks"
       "paste-cache" "logs" "channels" "backups" "agents-local"
       "pending-issues" "plans"
       ".claude.json" "mcp.json" "mcp-needs-auth-cache.json"
       "stats-cache.json" "blocked-commands.log" "last-review-result.log"
       "settings.local.json" "*.jsonl" "installed_plugins.json"
       "known_marketplaces.json" ".credentials.json"
       "plugins/installed_plugins.json" "plugins/known_marketplaces.json"
       "plugins/blocklist.json" "plugins/.claude" "plugins/data"
       "plugins/cache" # plugin cache dirs managed by Claude Code
     )
     ```

   - **`_is_known_runtime(path)`** — check if `path` (relative to `~/.claude`) matches any known-runtime pattern. Match directory entries by checking if the top-level component is in the list. Match file entries by basename or full relative path.
   - **Audit loop**: iterate files/dirs in `~/.claude` (depth 1), classify each as symlinked, known-runtime, or unknown.
   - **Report unknowns**: print a warning for each unknown file/dir. Exit 0 regardless (non-blocking).

**Step 2: Make executable**

```bash
chmod +x ~/Developer/claude-config/scripts/update-tools.sh
```

**Step 3: Test manually**

Cannot fully test until symlinks exist, but verify script parses without errors:

```bash
bash -n ~/Developer/claude-config/scripts/update-tools.sh
```

**Step 4: Commit**

```bash
git -C ~/Developer/claude-config add scripts/update-tools.sh
git -C ~/Developer/claude-config commit -m "feat: add update-tools.sh for symlink audit and repair

Called by _claude_update() during 'updates' command. Repairs broken
symlinks, updates submodules, and audits ~/.claude for unknown files."
```

---

## Task 4: Update .gitignore for docs/plans/

**Files:**

- Modify: `.gitignore`

**Step 1: Check current .gitignore**

Verify `docs/plans/` is not already listed.

**Step 2: Add docs/plans/ to .gitignore**

Add `docs/plans/` to the `.gitignore` file. Plans are working documents, not deployed config.

**Step 3: Commit**

```bash
git -C ~/Developer/claude-config add .gitignore
git -C ~/Developer/claude-config commit -m "chore: gitignore docs/plans/"
```

---

## Task 5: Run install.sh for real (create symlinks)

**Step 1: Run dry-run one more time to review**

```bash
~/Developer/claude-config/install.sh --dry-run
```

Verify the output looks correct — all expected files listed, no surprises.

**Step 2: Run install.sh**

```bash
~/Developer/claude-config/install.sh
```

Expected: symlinks created for all tracked non-excluded files. Existing files backed up to `~/.claude/backups/symlink-migration/`.

**Step 3: Verify key symlinks**

```bash
ls -la ~/.claude/settings.json    # should point to ~/Developer/claude-config/settings.json
ls -la ~/.claude/CLAUDE.md        # should point to ~/Developer/claude-config/CLAUDE.md
ls -la ~/.claude/hooks/run-review.sh  # should be symlink + executable
ls -la ~/.claude/scripts/update-tools.sh  # should be symlink + executable
```

**Step 4: Verify Claude Code still works**

Start a new Claude Code session (in a separate terminal) and confirm it loads settings, hooks fire, etc.

---

## Task 6: Remove ~/.claude/.git (manual, one-time)

**This task requires explicit human authorization. Do NOT proceed without it.**

**Step 1: Final verification that all symlinks resolve**

```bash
~/Developer/claude-config/install.sh --repair
```

Should report 0 repairs needed.

**Step 2: Remove git metadata from ~/.claude**

```bash
rm -rf ~/.claude/.git
rm -f ~/.claude/.gitignore ~/.claude/.gitmodules ~/.claude/.pre-commit-config.yaml ~/.claude/.flake8 ~/.claude/.editorconfig
```

**Step 3: Verify ~/.claude is no longer a git repo**

```bash
git -C ~/.claude status 2>&1  # should fail: "not a git repository"
```

**Step 4: Verify symlinks still work**

```bash
cat ~/.claude/settings.json | head -3  # should show content from repo
```

---

## Task 7: Run update-tools.sh and verify audit

**Step 1: Run update-tools.sh**

```bash
~/.claude/scripts/update-tools.sh
```

Expected:

- Symlink repair: 0 repairs
- Submodule update: up to date
- Audit: lists any unknown files in `~/.claude` (these are expected runtime files we may need to add to known-runtime list)

**Step 2: Review audit output**

If unknown files are reported, decide for each:

- Add to known-runtime list in `update-tools.sh` → commit
- Or bring into the repo → `git add`, run `install.sh`

**Step 3: Final commit if needed**

```bash
git -C ~/Developer/claude-config add scripts/update-tools.sh
git -C ~/Developer/claude-config commit -m "chore: expand known-runtime list from initial audit"
```

---

## Task 8: Run tests and push

**Step 1: Run full test suite**

```bash
bats ~/Developer/claude-config/tests/
```

**Step 2: Shellcheck install.sh and update-tools.sh**

```bash
shellcheck ~/Developer/claude-config/install.sh
shellcheck ~/Developer/claude-config/scripts/update-tools.sh
```

**Step 3: Push branch**

```bash
git -C ~/Developer/claude-config push -u origin claude/feat-symlink-reconciliation
```

**Step 4: Create PR**

```bash
gh pr create --repo smartwatermelon/claude-config --title "feat: symlink reconciliation with install.sh" --body "..."
```
