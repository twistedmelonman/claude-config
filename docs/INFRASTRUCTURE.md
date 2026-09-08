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
| Protocol 4 (Code review) | pre-commit hook | `~/.config/git/hooks/pre-commit` |
| Protocol 4 (Iterative review) | pre-push hook | `~/.config/git/hooks/pre-push` |
| Protocol 6 (No REST/GraphQL merge) | PreToolUse Bash hook | `~/.claude/scripts/hook-block-api-merge.sh` |
| Protocol 6 (No REST/GraphQL merge) | gh() wrapper | `~/.config/bash/functions.sh` |
| Protocol 6 (Off-org PRs forced draft) | gh-wrapper.sh | `~/.config/bash/gh-wrapper.sh` |
| Build consistency | build-commons.sh | `~/.claude/lib/build-commons.sh` |
| Deployment safety | deploy-commons.sh | `~/.claude/lib/deploy-commons.sh` |
| Branch cleanup | audit-branches.sh | `~/.claude/scripts/audit-branches.sh` |

**Key Point**: If hooks block an operation, it means a protocol was violated. `--no-verify` is BLOCKED by Claude Code hooks. Emergency override (human only): Human must run commit manually.

**When a hook blocks your commit**: Go back and rework the code — do not ask the human to override. See CODE-REVIEW.md § "When Reviews Find Issues — Rework, Don't Override" for the full escalation ladder. Only after 3+ genuine rework attempts with no viable path forward should you present the findings and ask if the human wants to override.

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

---

## Review Hooks

### How Review Runs

- `code-reviewer` and `adversarial-reviewer` run on EVERY commit automatically via pre-commit hook
- adversarial-reviewer uses v1.1.0 agent with structured failure mode checklist, severity calibration, and domain awareness
- Security-critical files get an "elevated scrutiny" log note but all commits are reviewed

### Review Log Verification

After every commit, verify the hook ran by reading the log header:

```bash
head -6 $(git rev-parse --git-dir)/last-review-result.log
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

### `useAutoModeDuringPlan: false` (`settings.json:133`)

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

## Shared Libraries

- `~/.claude/lib/build-commons.sh` — Common build functions
- `~/.claude/lib/deploy-commons.sh` — Common deployment functions

---

## Return to Main Documentation

→ Return to `~/.claude/CLAUDE.md`
