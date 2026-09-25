# Global Infrastructure — Andrew Rich

> **Note:** This is auxiliary documentation for `~/.claude/CLAUDE.md`
>
> **When to read:**
>
> - When working on hooks, scripts, or global infrastructure
> - When troubleshooting hook failures or enforcement blocks
> - When extending infrastructure for project-specific needs

---

## Automated Enforcement

Many protocols are enforced by git hooks and scripts:

| Protocol | Automation | Location |
|----------|------------|----------|
| Protocol 1 (No commits to main) | pre-commit hook | `~/.config/git/hooks/pre-commit` |
| Protocol 4 (Code review) | commit-msg hook (calls `run-review.sh`) | `~/.config/git/hooks/commit-msg` |
| Protocol 4 (Full-diff review) | pre-push hook | `~/.config/git/hooks/pre-push` |
| Protocol 6 (No REST/GraphQL merge) | PreToolUse Bash hook | `~/.claude/scripts/hook-block-api-merge.sh` |
| Protocol 6 (No REST/GraphQL merge) | gh() wrapper (sourced by `functions.sh`) | `~/.config/bash/gh-wrapper.sh` |
| Protocol 6 (Off-org PRs forced draft) | gh-wrapper.sh | `~/.config/bash/gh-wrapper.sh` |
| Protocol 6 (Merge-lock is human-only) | PreToolUse Bash + Write/Edit hooks | `~/.claude/scripts/hook-block-merge-lock-authorize.sh`, `hook-block-merge-locks-write.sh` |
| Commit/PR text approval | PreToolUse Bash hook + gh-wrapper.sh | `~/.claude/scripts/hook-block-personify.sh`, `gate-review.sh` |

The pre-commit hook no longer runs AI review. It blocks commits on
main/master, runs the pre-commit framework, and runs `.project-hooks/pre-commit`.
AI review moved to commit-msg so the reviewer can see the commit message.

`build-commons.sh`, `deploy-commons.sh`, and `audit-branches.sh` were listed
here previously. They no longer exist in claude-config or dotfiles.

**Key Point**: If hooks block an operation, it means a protocol was violated. `--no-verify` is BLOCKED by Claude Code hooks. Emergency override (human only): Human must run commit manually.

**When a hook blocks your commit**: Go back and rework the code — do not ask the human to override. See CODE-REVIEW.md § "When Reviews Find Issues — Rework, Don't Override" for the full escalation ladder. Only after 3+ genuine rework attempts with no viable path forward should you present the findings and ask if the human wants to override.

---

## Claude Code Tool Hooks

Configured in `settings.json` under `hooks`. The status-line `cc-status`
entries are omitted here.

| Event / matcher | Script |
|-----------------|--------|
| PreToolUse `Bash` | `~/.claude/scripts/hook-block-all.sh` (chain below) |
| PreToolUse `Write`, `Edit` | `hook-block-merge-locks-write.sh`: blocks writes into `merge-locks/`, `gate-review/`, and personify's `checks/` and `stamps/` |
| PreToolUse `EnterWorktree` | `hook-block-enter-worktree.sh` |
| PostToolUse `Bash\|Read` | `hook-redact-secret-output.py`: redacts env secret values, gitleaks findings, vendor prefixes gitleaks lacks, and the whole stdout of credential-printing commands (`op read`, `security -w`, ...) |
| Stop, SubagentStop | `hook-budget-guard.sh` |

`hook-block-all.sh` runs these in order and stops at the first block:

1. `hook-block-secret-leak.sh` (first on purpose: the others log the full command when they block)
2. `hook-block-gate-dir-write.sh` (Bash-path writes into `merge-locks/`, `gate-review/`, and personify's `checks/` and `stamps/`)
3. `hook-block-no-verify.sh`
4. `hook-block-short-no-verify.sh`
5. `hook-block-main-commit.sh`
6. `hook-block-personify.sh` (visual approval gate, below)
7. `hook-check-commit-message.py`
8. `hook-block-merge-lock-authorize.sh`
9. `hook-block-api-merge.sh`
10. `hook-block-git-worktree.sh`

### Visual Approval Gate

Commit messages and PR/issue bodies need Andrew's visual approval.

- `scripts/gate-review.sh stage <name> <file>` queues text. `open` shows the
  batch in BBEdit and waits. Approval is changing `# STATUS: PENDING` to
  `APPROVED` and saving. `check <file>` exits 0 if the file matches any approval.
- `check` compares a content hash. A match is not consumed, so an identical
  repeat (for example a retry after a failed push) passes. Approvals expire
  30 minutes after they are written (`GATE_REVIEW_APPROVAL_TTL`, seconds),
  the same window as a merge-lock; `check` and `stage` delete expired ones.
- Text must come from a file at an absolute path: `git commit -F` or
  `gh ... --body-file`. Inline `-m`/`--body`, relative paths, and `~`/`$VAR`
  paths are blocked. PR and issue titles are not gated.
- Gated surfaces: `git commit`; `gh pr create|comment|edit|review` and
  `gh issue create|comment|edit` when they carry a body flag; `gh api` when
  it sends a `body` field or a GraphQL mutation with a `body:` argument. The
  one verifiable `gh api` form is `-F body=@/absolute/path`. Not gated:
  `gh api --input <json>`, `git tag -m`, `git notes`, `gh release --notes`.
- `hook-check-commit-message.py` reads the summary from the file named by
  `git commit -F <absolute path>` as well as from `-m`, so commits made
  through the gate still get the conventional-commits pre-flight.
- Enforced by `hook-block-personify.sh` for the Bash tool, and by
  `gh-wrapper.sh` (`_gh_wrapper_approval_gate`) for manual `gh` calls.
- `stage` also refuses a file with no `~/.config/personify/checks/<sha256 of
  raw bytes>.json` check record. Run `pangram_check.py < <file>` on that
  exact file first; PASS, FAIL, and SKIPPED records are all accepted. The
  refusal prints the full command, with the `installPath` of
  `personify@personify` from `~/.claude/plugins/installed_plugins.json`. Use
  that path, not a directory picked from the plugin cache: the cache keeps
  every past version, and an old one can lack features (2.0.1 has no
  Keychain key lookup).
- `open` shows one Pangram line per item in the header, read from that
  item's check record.

### Merge-Lock Subcommands

`merge-lock authorize`, its alias `auth`, and `tui` (a bulk picker) all grant
locks. All three are human-only. `hook-block-merge-lock-authorize.sh` blocks
them for agents. `pre-merge-review.sh` checks for a valid lock before a merge.

---

## Protocol 6 — Enforcement Details

### Blocked Merge Paths

The following are blocked by `hook-block-api-merge.sh` and the `gh()` wrapper:

```
✗ gh api repos/.../pulls/NNN/merge --method PUT  (REST endpoint)
✗ gh api graphql -f query=mutation{mergePullRequest...}  (GraphQL inline)
✗ gh api graphql --input <file>  (file-backed mutation; closed 2026-04-18)
✗ gh api graphql --input=<file>  (equals form)
✗ gh api graphql --input -       (stdin)
✗ gh api graphql -F input=@<file>  (-F equivalent)
✗ gh api graphql --field input=@<file>  (--field long form of -F)
✗ gh -R owner/repo pr merge NNN  (global flag prefix)
```

**Only allowed**: `gh pr merge <number>` (routes through pre-merge-review.sh)

### File-Backed GraphQL Mutation Bypass (blocked 2026-04-18)

Previously the `--input <file>` variant of `gh api graphql` could not be inspected at command-line scan time because the mutation body lived in a file or on stdin. That gap is now closed: the hook blocks all `--input` forms (file, `=<path>`, stdin `-`, and `-F input=@file`) with a clear message. The git commit/log/show/diff exemption at the top of the hook allows documentation and commit messages to legitimately reference the pattern without false-positive.

### Global Flag Prefix Bypass (blocked 2026-02-25)

Placing a global flag like `-R owner/repo` before the subcommand (`gh -R owner/repo pr merge NNN`) caused the shell wrapper's positional `$1=='pr'` check to be skipped. Blocked at three layers: the hook regex (anchored to command position), the `gh()` bash wrapper (now parses past known global flags), and `~/.local/bin/gh`.

### Silent `gh pr merge` Failures

Likely a token scope issue. Report to the human. Do not attempt workarounds. Ask the human to investigate and merge manually.

### Historical Context

This enforcement exists because of two incidents on 2026-02-24:

- PR #813: `gh pr merge` failed → REST API used as workaround → pattern learned
- v1.11.0: that pattern reused → 9-second unauthorized production merge → required revert

---

## Off-Org Draft-PR Enforcement (gh-wrapper.sh)

`gh pr create` targeting a repo whose owner is not `smartwatermelon`, `nightowlstudiollc`, or `twistedmelonman` is force-created as a draft by `~/.config/bash/gh-wrapper.sh` (symlinked as `~/.local/bin/gh`, and sourced as a bash function via `functions.sh`). This is a mechanical check on the resolved repo owner — not an AI judgement call, and there is no flag or environment variable to opt out. Owner is resolved the same way identity auto-switch resolves it: an explicit `-R`/`--repo` target takes precedence over cwd's `origin` remote.

`twistedmelonman` is the personal account after the 2026-09 org migration (the old personal login `smartwatermelon` was freed up and re-created as the org). All three are in-org for this check; the authoritative list is the `case` in `gh-wrapper.sh`'s draft-forcing block.

**Why**: an automated agent should not be able to open a fully "submitted" PR against a repo outside the orgs this environment is scoped to. The human operator remains free to promote the PR out of draft afterward, at their discretion, via the GitHub UI — the wrapper only governs creation time, not later state. See `smartwatermelon/dotfiles#174` (design) and `#175` (implementation).

**If an agent hits this**: a draft PR on an off-org repo is expected behavior, not a bug. Do not attempt to work around it in any way. Surface it to the user as a draft PR and stop there.

### Known Gaps

- `gh-wrapper.sh` reaches the Bash tool two ways: `settings.json` sets `BASH_ENV` to `~/.config/bash/functions.sh`, which sources it, and it is installed as `~/.local/bin/gh`. It also exports `sugh`, which runs the real `gh` binary and skips ALL wrapper checks (merge guard, draft forcing, approval gate, identity switch). The "no flag to opt out" statement above applies to `gh`, not `sugh`.
- Full bypass list: `docs/2026-09-23-personify-and-gating-overview.md` in smartwatermelon/dev-env.

---

## Review Hooks

### How Review Runs

- `code-reviewer` and `adversarial-reviewer` run on EVERY commit automatically via the commit-msg hook, which calls `~/.claude/hooks/run-review.sh` with the in-progress message
- adversarial-reviewer (code-critic plugin) uses a structured failure mode checklist, severity calibration, and domain awareness
- Models (defaults; override with `git config review.model`, `review.adversarialModel`, `review.arbiterModel`):
  - code-reviewer: `claude-haiku-4-5-20251001` for commits, `claude-sonnet-4-6` for `--mode=full-diff` and `--mode=codebase`
  - adversarial-reviewer: `claude-sonnet-4-6` in every mode
  - arbiter: `claude-sonnet-4-6`, invoked only when code-reviewer returns a BLOCKING FAIL and adversarial-reviewer returns PASS
- Size limits: `review.maxLines` (default 1000) is the full-review ceiling; above it, review is chunked per file. Above `review.skipThreshold` (default 2500) the commit is blocked and must be split.
- commit-msg skips review when the subject starts with `fixup!`, `squash!`, `wip:`, `WIP:`, or `wip`/`WIP` followed by whitespace
- The pre-push hook runs one `--mode=full-diff` review that must pass. It files no issues. `--mode=codebase` is weekly/on-demand only (see CHECKLISTS.md, "On-Demand Codebase Review").
- `run-review.sh` has no special path for security-critical files. `is_security_critical` (in `lib-review-issues.sh`) is used only by `pre-merge-review.sh` (those diffs are never summarized) and for the `security` issue label. See REFERENCE.md for the pattern.

### Review Log Verification

After every commit, verify the hook ran by reading the log header:

```bash
head -6 "$(git -C /abs/path/to/repo rev-parse --absolute-git-dir)/last-review-result.log"
```

Check: timestamp within ~60s, repo matches, branch matches, commit matches HEAD.

The global `~/.claude/last-review-result.log` is a pointer file with a `log:` field pointing to the per-repo authoritative log.

### Review Timeouts

If review times out:

- Retry the commit (transient failures happen)
- Increase timeout: `git config review.timeout 300`
- Split into smaller commits

---

## Settings Rationale

### `useAutoModeDuringPlan: false` (`settings.json:293`)

Disables Claude Code's auto-mode permission classifier while in Plan Mode. Auto mode
normally lets a heuristic classifier silently approve Bash commands it judges
read-only, skipping the permission prompt. Plan Mode's whole point is that nothing
executes until the human reviews and approves the plan — auto-mode's classifier
running underneath it has previously caused the classifier to override Plan Mode with
conflicting "execute immediately" behavior (see upstream Claude Code changelog).
Keeping this `false` means every action during planning stays gated on an explicit
human decision, consistent with this config's broader preference for explicit
checkpoints (Protocol 6's merge-lock authorization, etc.) over auto-approval.

---

## Return to Main Documentation

→ Return to `~/.claude/CLAUDE.md`
