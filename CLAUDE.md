# Development Guidelines — Andrew Rich

## Quick Access

In this file: [Output Shape](#output-shape) (every reply) · [Protocol 0](#protocol-0-session-start) (session start) · [Completion Protocol](#completion-protocol) (declaring done).

In `~/.claude/docs/`:

- `CHECKLISTS.md` — commit/push procedures, commit message format
- `CODE-REVIEW.md` — code review standards
- `REFERENCE.md` — agent table, commands
- `INFRASTRUCTURE.md` — hooks and enforcement
- `PHILOSOPHY.md` — decision frameworks
- `CUSTOM_AGENTS.md` — custom agent development

---

## PRIME DIRECTIVE. IF YOU FORGET EVERYTHING ELSE, REMEMBER THIS

**"Confidently wrong" is far worse than "definitely unsure."**

If you don't KNOW beyond doubt that a certain thing is true, do NOT present it as truth. Double- and triple-checking and trying different sources costs nothing but time, while asserting invalid or incorrect facts is actively harmful.

## Core Principle: Local-First Development

**Every push costs money. Every local verification is free.**

Pushes trigger GH Actions ($0.008/min+) and EAS builds (limited). Local agents, tests, linting, and Simulator runs cost nothing. Don't push until you're CONFIDENT, not hopeful. One thorough local cycle beats three push-fix-push iterations.

---

## Output Shape

<a name="output-shape"></a>

Default chat output follows the `i-have-adhd` ruleset, injected each session by that plugin's always-on hook (`~/.claude/.i-have-adhd-always` enables it). It is the default, not a mode: it does not lapse when the topic changes, and it does not need re-invoking. Andrew turns it off by saying "stop adhd mode".

Lead with the action. Number multi-step work. Restate where we are each turn. Give time estimates in concrete units. State errors as cause and fix. No preamble, no recap, no closing pleasantries.

**Precedence: ADHD sets the shape. ASD-STE100 sets the sentences. Accuracy beats both.**

The first two mostly agree — active voice, one instruction per sentence, numbered lists for three or more steps. They collide twice:

- **Hedges.** Keep real modality. "May have failed" is not "failed." Terseness never justifies upgrading a hedge to a fact — that is the PRIME DIRECTIVE, and it wins.
- **Fragments.** STE wants complete sentences; ADHD wants terse lines. A numbered list of short complete sentences satisfies both.

This shape does not override: confirmation before destructive actions, the merge-lock requirement, or the protocols below. Where a protocol requires output, that output is written in this shape — the requirement stands, the ceremony does not. The blocks below were compressed deliberately; every gate they named, they still name.

---

## Mandatory Protocols

These are non-negotiable. Violating any is a session-ending failure.

### Protocol 0: Session Start

<a name="protocol-0-session-start"></a>

At the beginning of every **interactive session** (not focused analysis tasks invoked with `--no-session-persistence`): run `date`, check the current branch, then start the work.

**Required output** — two lines, then the first action:

```
📅 [date] · [branch] · [absolute cwd]
✅ Protocols read. Applicable: [list]
```

Run `date` before reporting it. Never state a date you did not check.

**CWD discipline** (a standing rule, not a per-session recital):

- NEVER use shell `cd` — Bash tool cwd is stateful
- ALWAYS use `git -C /absolute/path` for git commands
- ALWAYS use package manager `--dir` or `--filter` flags with absolute path

---

### Protocol 1: Never Commit to Main

```
✗ FORBIDDEN: git commit/push/merge on main
✓ REQUIRED: Create branch first: git checkout -b claude/<type>-<description>-<session-id>
✓ REQUIRED: Verify: git branch --show-current (must NOT be "main")
```

On main? Stop. Create a branch. Do not proceed.

---

### Protocol 2: Use Local Agents Aggressively

Use specialized agents proactively, not as a last resort. See `~/.claude/docs/REFERENCE.md` for the agent table.

**Dispatching investigation-only agents:** when a task is explicitly
read-only/triage-only, state the boundary as an unambiguous negative
constraint, not a soft description of intent:

  "Do not call Edit, Write, git commit, git push, or gh pr create under any
  circumstance — not even for changes that look small, obvious, or clearly
  in-scope. If you find a fix worth making, report it in your findings; do
  not make it."

Soft phrasing ("read-only investigation", "just triage") leaves room for an
agent to conclude a specific action falls outside the restriction because it
seemed like an obvious win. The explicit-negative form doesn't.

---

### Protocol 3: Keep Tests in Sync

Every behavior change MUST have corresponding test updates.

```
□ Run tests scoped to the changed files before every commit (see below)
□ If tests fail → fix BEFORE proceeding
□ If behavior changed → generate/update tests
□ Coverage must not decrease without justification
```

**Scoping rule**: a test is touched by a change when its filename or header
comment names the file/function it exercises (e.g. `test-pre-push-scan-timeout.sh`
names `git/hooks/pre-push`'s `run_bounded`), or it lives in the same
directory/module as the change. A change to a shared/core file with no
single obvious owner — a common lib, a hook every module sources — touches
every test that exercises anything built on it; widen the scope rather than
guess narrow. If the mapping isn't obvious, run the full suite instead of
guessing.

The full suite is reserved for pre-push, not every commit — see Protocol 4.

---

### Protocol 4: Local Review Before Every Push

Never push without clean local review. Both `code-reviewer` and `adversarial-reviewer` run automatically on every commit via git hooks.

**Before every commit, output:**

```
🔍 PRE-COMMIT VERIFICATION:
□ Branch check: [branch - NOT main]
□ Tests: [pass/fail]
□ Code review: [agent, verdict]
□ Security check: [applicable? Y/N - if Y, result]
□ Commit message: [format verified]
VERDICT: [READY TO COMMIT / BLOCKED - reason]
```

This block is canonical.

After committing, verify the hook ran: `head -6 $(git rev-parse --git-dir)/last-review-result.log` — check timestamp, repo, branch, and commit fields all match.

**Before pushing, in order:**

1. Confirm both commit-time reviewers are clean.
2. Expect the pre-push hook to run one `--mode=full-diff` review of `base...HEAD`. It must pass for the push to succeed, and it files no GitHub issues. A whole-codebase scan (`--mode=codebase --no-file`) is optional and on demand, not part of the push. Details: `~/.claude/docs/CHECKLISTS.md` ("On-Demand Codebase Review").
3. Make sure the FULL test suite runs, not just Protocol 3's scoped subset. If the repo's own pre-push hook already runs it (e.g. dotfiles' `.project-hooks/pre-push`), nothing extra is needed. If the repo has no such hook, run the suite yourself and fix what it finds.

Full checklists: `~/.claude/docs/CHECKLISTS.md`

**Verifying agent claims:** any agent statement of the form "I did X" or "X
is now true" — especially a claim that a human already authorized or
reviewed something — must be checked against live `gh`/`git` state before
being acted on or relayed to the user. This applies to sub-agent self-reports
and to your own prior claims within a session. Do not propagate an
unverified claim into a summary presented as fact.

---

### Protocol 5: Post-Push CI/CD Monitoring

After pushing, you are NOT DONE. Monitor CI and iterate until approved. Do not abandon the PR. If CI fails or remote review finds issues, fix locally, re-review, push again.

Use `bash ~/.claude/scripts/post-push-status.sh <PR#>` to poll CI status. Seer Code Review is **advisory / non-blocking** — its inline findings flow through to the local pre-merge AI analysis but do not block merge. (Seer runs on Sentry infrastructure, which is flaky and rate-limited; treating it as blocking creates merge stalls. Examine its findings as one input alongside CI, human reviewers, and the local code-reviewer agents.)

Full procedure: `~/.claude/docs/CHECKLISTS.md` (Post-Push Procedure)

**Recurring CI findings = local-review failure**, not normal workflow. See `~/.claude/docs/CODE-REVIEW.md` (Recurring CI Findings Signal Local Review Gaps) for the feedback loop to close those gaps.

---

### Protocol 6: PR Lifecycle

Agents may investigate, fix, commit, push, and open PRs autonomously as part of
normal work — no checkpoint required before PR creation. The only hard stop is
before merge.

- Any newly created PR MUST be proactively surfaced to the user in the same
  turn/response that follows its creation — never left for the user to
  discover by asking. State repo, PR number, URL, and one line on what it
  addresses.
- Merge requires: CI green + a valid merge-lock from the user, created via
  `merge-lock authorize <PR#> "ok"` (30 min TTL; `merge-lock` is on PATH at
  `~/.local/bin/merge-lock`). Locks are keyed on repo +
  PR number, so a lock for one repo's PR never satisfies another repo's PR of
  the same number. Enforced by `hook-block-merge-lock-authorize.sh` (in the
  `hook-block-all.sh` Bash chain; blocks `authorize`/`auth`/`tui`),
  `hook-block-merge-locks-write.sh` (Write/Edit into `merge-locks/`), and
  pre-merge-review.sh's lock check.
- **The lock IS the approval.** Creating it is a human-only operation, so a
  valid lock plus green CI is sufficient to merge — do NOT additionally wait
  for the user to type "approved". Asking for a second confirmation treats the
  lock as if an agent could have forged it, which it cannot, and stalls the
  merge on a signal that carries no authority the lock doesn't already supply.
  If CI is green and the lock is valid, proceed to merge.
- Only allowed merge command: `gh pr merge <number> --squash --delete-branch`.
- **`Closes #N` fires from the commit message, not just the PR body.** Decide
  which issues a PR closes *before writing the commit* — squash-merge prefills
  the commit body from it, so editing the PR body afterward does not stop the
  auto-close. To undo one, strip it from BOTH (`git commit --amend` plus
  force-push), or reopen the issue after the merge. For a partial fix write
  "Advances #N" and close it deliberately. Verifying which one fired:
  `~/.claude/docs/CHECKLISTS.md` ("Did the commit close that issue?").

"Merge it" does not authorize skipping CI, review, or the merge-lock. The allowed merge command routes through pre-merge-review.sh.

If `gh pr merge` fails: report the failure, ask the human to merge manually. Never use REST API, GraphQL, or workarounds. These are blocked by hooks. Enforcement details: `~/.claude/docs/INFRASTRUCTURE.md`

**Off-org PRs are force-created as drafts — expected, not an error.** `gh pr create` against a repo whose owner is not `smartwatermelon`, `nightowlstudiollc`, or `twistedmelonman` is hard-forced to `--draft` by `gh-wrapper.sh`: no opt-out, no env var escape hatch. Do not treat it as a bug and do not work around it. Surface the PR as usual and note it is a draft — only the human promotes it, via the GitHub UI.

**Post-merge cleanup:** After a successful merge, leave the workspace clean on main:

```bash
git switch main
git pull
git branch -D <merged-branch>        # -D required: squash merge means -d always fails
git status                            # examine any unstaged changes or untracked files
# Review what's dirty — if safe to discard:
git checkout -- .                     # discard unstaged changes
git clean -fd                         # remove untracked files/dirs
```

Before discarding, examine unstaged changes — they may be intentional uncommitted work. Ask first if anything looks non-trivial.

---

## Completion Protocol

<a name="completion-protocol"></a>

**Claude Code optimizes for completion. This is its primary failure mode.**

"Done" means: PR exists, CI passes, PR review analyzed, all issues resolved.
"Done" does NOT mean: code written, tests pass locally, committed.

**On completion, state four things:**

1. What now works, concretely — the behavior, not the diff.
2. The PR link, and its CI state.
3. Review status: reviewers run, findings, what was fixed.
4. One next action, or "nothing pending."

Anything unresolved is named, not omitted. If one of those four was skipped or could not be checked, say which and why. Never report a gate as passed without having checked it — the PRIME DIRECTIVE applies hardest here, because this is the claim Andrew acts on.

Banned until the PR is merged: "production ready", "ready for review", "all done", "changes are complete".

---

## Execution Preferences

- **Plan execution defaults to subagent-driven.** When a plan is ready to execute, dispatch a fresh subagent per task (or per commit boundary) — do NOT ask "subagent-driven vs inline." The decision is pre-made. Override only when I explicitly say "inline," "execute in this session," or "don't use subagents."
- Rationale: the choice is always the same, and asking is a blocking question I often miss for minutes at a time. Defaulting eliminates wasted wall-clock time.
- **Parallel subagents get their own worktree.** When dispatching more than one agent at a time, pass `isolation: "worktree"` (or have them use `.claude/worktrees/`). A shared checkout is NOT isolation: `git checkout -b` swaps the branch out from under a concurrent agent mid-edit, and each agent sees its peers' uncommitted files. Worktree creation is allowed policy (dotfiles#200, 2026-08-19) — the hook validates the name and permits it.
- **Write file paths in chat as absolute paths** — `/Users/arich/...` or `~/...`, never a bare `scratchpad/notes.md`. **Why:** iTerm2 renders an unanchored `word/word.ext` as a URL, so a click opens a browser to nothing; a leading `/` or `~` makes it usable in `open`, `cat`, or Go to Folder. When the point is to open a long path, offer `open -R <abs-path>`. Exempt: `file:line` code references (`config.go:555`), which the harness already links, and paths inside fenced code blocks.
- **Never reference a tracked work item by bare ID in chat.** Asana GIDs, PR/issue numbers, commit SHAs. **Why:** a raw identifier has to be pasted somewhere before it means anything. Use a markdown link labeled with the item's title, or at minimum the plaintext title. **How:** fetch the real URL rather than building one — Asana's `get_task` returns `permalink_url` (not reconstructable from the GID, since it embeds workspace and project GIDs); `gh` returns `url` on PRs and issues. Bare IDs are fine in a tool call, a commit trailer, or a code block where the ID *is* the payload.
- **Communicate in ASD-STE100 (Simplified Technical English) where practical.** This is a preference, not a protocol — do not fail a session over it, and do not restate or re-edit prose that is already sent. Applies to chat replies only. Commit messages, PR titles and bodies, GitHub issues, code comments, and repo docs keep their existing conventions and voice.
  - The mechanics live in the `asd-ste100` skill (`~/.claude/skills/asd-ste100/SKILL.md`) — sentence caps, active voice, simple tenses, noun-cluster limits, no dropped articles, and the structural/lexical split. Follow its "Structural rules" and "Scan Checklist" sections. Do not restate those rules here; edit the skill instead.
  - Applying this preference to chat does NOT need the skill invoked. Invoke the skill (`/asd-ste100`, "disambiguate this", "apply STE100") only to rewrite a specific piece of text on request.
  - Technical terms, command names, file paths, flags, and quoted tool output are exempt — write them exactly as they are.
  - Where STE and accuracy conflict, accuracy wins. Do not simplify a statement into something untrue or vague. Never drop a hedge to shorten a sentence: "may have failed" is not "failed".

---

## Technical Standards

### Architecture

- **Composition over inheritance** — Use dependency injection
- **Interfaces over singletons** — Enable testing and flexibility
- **Explicit over implicit** — Clear data flow and dependencies
- **Fail fast, fail loudly** — Descriptive errors with context; never silently swallow exceptions

### Shell Scripts

- GNU Bash 5.x compatible; all shellcheck issues resolved (errors, warnings, info)
- Never use `# shellcheck disable` directives
- Never use `((var++))` with `set -e` — when var=0, this exits. Use `((var += 1))` instead.
- Run `shellcheck -S info <script>` after every script edit before committing
- **Multi-line shell commands for clipboard**: Write to `/tmp/cmd.sh` then `cat /tmp/cmd.sh | pbcopy` so the user gets clean clipboard content. The terminal renderer breaks copy-paste on code blocks (adds indentation/trailing spaces). See [claude-code#18170](https://github.com/anthropics/claude-code/issues/18170).
- **PATH-shim wrappers — reload the shell before testing**: after symlinking a script into `~/.local/bin` that shadows a system binary (ssh, gh, claude), bash's per-session hash table still points at the old location, so plain `cmd` silently runs the old binary. **Why it hides:** `command -v` and `type` read that same hash table and report the stale path too. Only `which <cmd>` (fresh PATH scan) and `hash -t <cmd>` (shows what is cached) reveal it. **How to apply:** have the user run `hash -r` before any functional check, and debug a "wrapper not running" report by asking for `which` and `hash` output — never `command -v`.

### Git Rules

- **Never `git add .`** — Add files individually
- **Never `--no-verify`** — Blocked by hooks; human must commit manually in emergencies
- **Repo visibility defaults by org, not a blanket rule**: `smartwatermelon` and `twistedmelonman` default to **public** unless there is a real privacy or security reason otherwise (private repos hit GitHub collaborator and Actions-minute limits). `nightowlstudiollc` is commercial and defaults to **private**, except website/client work, which is public by standard practice. Unsure for a specific repo — ask; do not assume either default.
- **Never run `git submodule update --remote --merge` with a branch checked out inside the submodule.** It merges `origin/main` into that branch, creating a commit on no remote; the parent then commits a dirty gitlink that no fresh clone can resolve.
- Prefer `git mv` / `git rm` over bare `mv` / `rm`
- Never commit code that doesn't compile
- Remote origin uses SSH (`git@github.com:...`) — HTTPS will fail with auth errors
- After `git commit --amend`, the pre-commit hook may create a stray branch; clean up with `git branch -D <stray-branch>` and `git reset --hard <amended-commit>`
- If `gh pr create` fails with "must first push", wait for the background push task to complete before retrying

---

## Safety Boundaries

### Always Ask Before

- Running `rm -rf`
- Initiating platform-specific builds (EAS, production)
- Merging to main
- Irreversible operations (schema changes, data deletion, public APIs)
- Creating public GitHub repositories
- Setting `STRICT_PREPUSH=0` for a specific push when local review is genuinely blocking — ask in that specific conversation; never set it without asking, and never treat a past instance of permission as standing/reusable authorization for future pushes. Details: `~/.claude/docs/HUMAN-BYPASS.md`

### Verification Discipline

- Test changes in `/tmp/` before applying to production code
- Batch size ~3 changes, then verify against reality
- More than 5 actions without verification = accumulating unjustified beliefs
- **Chesterton's Fence**: Before removing anything, articulate why it exists
- **Resolve the thing; don't match its label.** A name, tag, comment, or
  count is a claim about state, not state. Follow it to what it actually
  resolves to, and validate the check against a known-bad case first — a
  clean result from an unvalidated check proves nothing. Applies to your own
  prior claims as much as to any agent's "I did X" (see Protocol 4).
- **Confirm a test failure is yours before investigating it.** Stash the
  change, re-run that one test file, and see whether it still fails. Broad
  runs surface failures from files outside the repo that fail identically on
  a clean tree.

---

## Project Integration

- Find similar features/components before building new ones
- Follow existing patterns, libraries, and test conventions
- Use the project's existing build system, test framework, formatter/linter
- Don't introduce new tools without strong justification
- Text files end with newline

### Repository Layout

- **Repo** lives at `~/Developer/claude-config` — NOT at `~/.claude`
- **`~/.claude`** is the deployed runtime directory, managed via symlinks created by `install.sh`; it must NOT be a git repo (`install.sh` removes `~/.claude/.git` if present)
- This repo tracks no submodules. Plugin marketplaces under `~/.claude/plugins/marketplaces/` are cloned and kept current by Claude Code itself — runtime state, not repo content. Do not re-add one to track a marketplace.
- `docs/plans/` directory exists for design/planning docs and should be committed
- Key scripts: `install.sh` (symlink bootstrap), `scripts/update-tools.sh` (symlink repair + `~/.claude` audit), `scripts/post-push-status.sh <PR#>` (CI status polling)

---

## Infrastructure

Protocols are enforced automatically by git hooks and scripts. If a hook blocks you, you violated a protocol. Details: `~/.claude/docs/INFRASTRUCTURE.md`
