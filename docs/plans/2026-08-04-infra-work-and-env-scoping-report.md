# Report: 2026-08-04 infra work + Claude Code environment-scoping problem

Prepared for import into Claude Desktop for holistic reasoning about a
company-machine-vs-personal-machine Claude Code configuration split.
Written from `arich-mac` (Andrew's Beacon-owned machine), working in
`~/Developer/beacon/infra` (Beacon's central infra-as-code repo).

## Part 1: What happened today, factually

### Branches / PRs touched

All three are Andrew Rich's own branches in `beacon-biosignals/infra`,
based on `main` as of commit `a5152b91`:

1. **`arich/terraform-version-floor`** → PR **#6345** ("Add Terraform
   version floor (>= 1.13.1)"), opened 2026-08-04T17:53:04Z.
   - Adds `required_version = ">= 1.13.1"` to
     `providers/providers_required.tf` (shared, symlinked into every
     root). Floor matches Atlantis's current `--default-tf-version`.
   - Bumped `.github/workflows/formatting.yaml`'s Terraform pin from a
     stale `~1.9` to `1.13.3`.
   - Added a version note to `handbook/infra-users/local-setup.md`.
   - Later in the session, added one more commit: bumped
     `.github/workflows/Copier.yaml`'s Terraform pin from `~1.9` to
     `1.13.3` to match the rest of CI (this was the fix for issue #10
     below). This second commit was made with `git commit --no-verify`
     by Andrew directly (see Part 2).
   - All CI checks green as of last check, including a transient
     `docker`/Hadolint failure (GitHub API 503) that cleared on
     `gh run rerun --failed`.

2. **`arich/pre-commit-ci-parity`** → PR **#6347** ("chore: add local
   pre-commit hooks that mirror CI formatting checks"), opened
   2026-08-04T18:39:14Z.
   - Adds `.pre-commit-config.yaml` hooks that mirror CI's formatting
     checks locally (shfmt, yamllint, markdownlint, terraform fmt,
     conftest, provider-check, state-check, etc., all
     `language: system`, meaning they expect tools already on PATH).
   - Fixed a portability bug in the conftest hook (empty-input guard).
   - Added setup instructions to `handbook/infra-users/local-setup.md`,
     including a fix mid-session: the initial `brew install pre-commit
     ruff hadolint` line omitted `shfmt`, `yamllint`,
     `markdownlint-cli`, and `terraform`, which are also required by
     the hooks. This exact gap was independently caught by an
     automated pre-push whole-codebase review and logged as a
     pending-issue file (see Part 2) — it was already fixed on this
     branch by the time the pending-issue was triaged.

3. **`arich/pr-template-contributing-link`** → PR **#6332** ("docs: link
   PR templates to CONTRIBUTING.md"), already open from before this
   session, currently awaiting approval. Adds a root-level default PR
   template and links PR templates to `CONTRIBUTING.md`. Not
   otherwise touched or advanced during this session.

### Explicitly out of scope, confirmed and left alone

A large batch of `[SHFv2] in development, refresh (#6306)` changes
(already merged to `main` before this session started) touched
`terraform/ack/`, `terraform/kro/`, `cluster-contents/`, and
`modules/kubernetes_access/`. An automated review tool had logged nine
non-blocking findings against that code (IAM over-scoping on
`AttachRolePolicy` and `GetRole`, a missing tag condition on
`secretsmanager:CreateSecret`, a Kubernetes RoleBinding/ClusterRoleBinding
mismatch, an undeclared cross-stack dependency, dead module variables,
etc.). None of these came from Andrew's branches — `git log --author`
and per-branch `--name-only` diffs confirmed zero overlap. Correctly
left untouched per "don't poke at other people's work." One additional
open question (Atlantis's actual pinned Terraform version vs. the new
`>= 1.13.1` floor) is already being investigated by a teammate (Erik);
explicitly deferred, not touched.

## Part 2: The gotchas — mechanically, what got in the way

These are the operationally interesting parts: friction encountered
while trying to follow the repo's own stated hook/validation policy.

### Gotcha 1: `zizmor` (GitHub Actions security linter) blocked an

unrelated one-line fix

**What happened:** Fixing pending-issue #10 (`Copier.yaml` still pinned
to Terraform `~1.9`, inconsistent with the new `>= 1.13.1` floor) meant
changing exactly one line: `terraform_version: "~1.9"` →
`terraform_version: "1.13.3"`. The repo's local pre-commit hooks (run
via `~/.config/pre-commit/config.yaml`, a *global* pre-commit config,
not the repo's own `.pre-commit-config.yaml`) ran `zizmor` against the
touched file and failed the commit with two `error`-level findings:

- `unpinned-uses`: `actions/checkout@v4` and
  `hashicorp/setup-terraform@v3` are not pinned to a commit hash.
- `excessive-permissions` (warning): the job has no explicit
  `permissions:` block.

**Why it's a false positive for this specific commit:** these findings
were verified to pre-exist on `main` (extracted the pre-diff version of
`Copier.yaml` via `git show`, ran `zizmor` against it directly — same
findings, same file, before the one-line change). The diff did not
introduce them. But the hook has no notion of "pre-existing vs.
newly-introduced" — it just fails on the current state of the whole
file, unconditionally, for any touch to that file.

**Tension with repo's own rules:** `infra/CLAUDE.md` explicitly says
"Keep PRs small and coherent... don't bundle unrelated cleanup." Fixing
the zizmor findings (pinning two actions to hashes, adding a
permissions block) would have been the "correct" security fix, but it
would have turned a one-line version bump into a mixed-concern commit
touching action-pinning security policy — exactly what the repo's PR
hygiene rule says not to do. There was no clean way to satisfy both
"small, coherent PR" and "hooks must pass" simultaneously for this
file.

**How it was resolved:** escalated to Andrew rather than silently
routing around it. Per Andrew's global CLAUDE.md
(`~/.claude/CLAUDE.md`), `--no-verify` is explicitly forbidden for
Claude to use ("Never `--no-verify` — Blocked by hooks; human must
commit manually in emergencies"). Claude prepared the exact commit
message and command, copied it to clipboard, and asked Andrew to run it
himself. Andrew ran it as `git commit --no-verify` manually. This is
the intended escape hatch per Andrew's own stated policy — the block is
on the *agent* invoking `--no-verify`, not on the flag ever being used.

**Follow-on effect:** because the commit bypassed hooks, it also
bypassed the *local* code-reviewer/adversarial-reviewer pass that
normally runs pre-commit. That pass instead ran later, automatically,
as part of the pre-*push* hook (see Gotcha 2) — so nothing was actually
skipped end-to-end, it just moved from pre-commit to pre-push.

### Gotcha 2: pre-push review surfaced a real (if minor) inconsistency

plus two more unrelated pending-issues

When `git push` ran, the repo's pre-push hook ran Semgrep, then a
full-diff adversarial review and a whole-codebase review in parallel.
Both passed (non-blocking), but surfaced:

- A real, correctly-scoped finding: CI now pins Terraform to `1.13.3`
  exactly, while `providers_required.tf`'s floor is `>= 1.13.1`,
  justified by a comment citing Atlantis's `--default-tf-version` of
  `1.13.1`. If Atlantis is actually still on `1.13.1`, CI is validating
  a different patch version than what Atlantis will actually run. This
  is the item already being investigated by Erik — correctly not acted
  on further here.
- Two more non-blocking findings *unrelated to this diff* (a stray
  `~1.13` pin in `platform-namespace.yaml` that permits 1.13.0, below
  the new floor; and Atlantis's Helm `image.tag: latest` being mutable
  and creating potential version skew). Both auto-filed to
  `~/.claude/pending-issues/` as markdown files, same mechanism as
  Part 3 below. Both correctly identified as pre-existing and out of
  scope for this diff, left untouched.
- A cosmetic tool bug: the pending-issue auto-filer tried to create an
  Apple Note via `osascript` and failed with an AppleScript syntax
  error (`Expected """ but found unknown token`), then fell back to
  writing the markdown file to disk, which worked. The Apple Notes path
  appears broken/unmaintained; the filesystem fallback is what's
  actually load-bearing today. (Separately: Claude Code itself has no
  Apple Notes access in this session — no MCP server or CLI bridge for
  Notes.app was available — so the file-based fallback was also the
  only thing Claude itself could read back.)

### Gotcha 3: a transient GitHub API 503 looked like a real CI failure

One job (`docker` / Hadolint via `reviewdog/action-hadolint`) failed
with `reviewdog: fail to get diff: GET
https://api.github.com/repos/beacon-biosignals/infra/pulls/6345: 503`.
This is GitHub's API, not the repo's code — this PR touches no
Dockerfiles, and the failure was a transient 503 from GitHub itself.
Confirmed transient by rerunning just the failed job
(`gh run rerun <id> --failed`); it passed on retry with no code changes.
Worth remembering as a pattern: an isolated single-job CI failure that
mentions a `50x` from `api.github.com` in its own log is very likely
infra flakiness, not a real signal, and a targeted rerun is the right
first move before treating it as a real finding.

## Part 3: The `pending-issues` mechanism, as observed in practice

`~/.claude/pending-issues/*.md` is a real, working mechanism (backed by
`~/.claude/scripts/lib-review-issues.sh` and friends) for logging
non-blocking review findings outside of GitHub Issues, since Beacon
doesn't use GH Issues. Confirmed behavior:

- Auto-created by pre-push whole-codebase review passes, one file per
  finding, filename derived from a slugified title + date.
- Intended primary destination is an Apple Notes note (comment in the
  hook output: "File this privately (e.g. paste into Notes.app 'Tech
  Debt' folder) — do not create a public GitHub issue for this"), with
  the markdown file as a fallback when the `osascript` call fails. In
  this session, `osascript` failed every time (AppleScript syntax
  error), so 100% of today's findings landed only in the markdown
  fallback, never in Notes.
- These files persist indefinitely and accumulate across unrelated
  branches/sessions — nothing currently triages, dedupes, or expires
  them automatically. In this session there were 13 files across 11
  distinct issues before triage, including 3 near-duplicate write-ups
  of the same `secretsmanager:CreateSecret` finding, generated by
  separate review passes on separate days/sessions.
- Triage in this session required manually cross-referencing each
  finding's file path against `git log --name-only` on Andrew's actual
  branches to determine authorship/relevance — there is no
  automatic "is this my diff" tagging on the file itself, even though
  the hook that generates them clearly has that diff in hand at
  creation time (it already knows "pre-existing relative to this diff"
  language for some findings but doesn't store it structurally).
- **Possible improvement worth considering separately:** the generator
  could stamp each file with the branch/commit it was generated from,
  and whether the review pass itself already classified the finding as
  pre-existing vs. newly-introduced, so future triage doesn't require
  re-deriving that from git history by hand.

## Part 4: The environment-scoping problem — current state

This is the part most relevant to the stated goal: differentiated
enforcement based on (a) which machine Claude Code is running on, and
(b) which repo/org is being worked on.

### Confirmed facts about the current setup

- **Machine identity is not tracked anywhere in config.** This
  session ran on host `arich-mac` (confirmed via `hostname`), which is
  Andrew's Beacon-owned/managed machine. The stated target machine for
  "personal rules" is `ASIAGO.local`. Searched the entire
  `~/Developer/claude-config` repo (the actual git-tracked source for
  `~/.claude`) for any reference to `ASIAGO`, `hostname`, or
  `arich-mac` outside of the status line script — there is none. No
  hook, no settings block, no conditional logic anywhere keys off which
  machine is running.
- **`~/.claude/CLAUDE.md` is a single global file**, symlinked from
  `~/Developer/claude-config/CLAUDE.md`, loaded identically regardless
  of machine or repo. It currently encodes rules that are clearly
  Beacon-specific in spirit even though the file doesn't say so
  explicitly — e.g. "Never commit to main," the PR lifecycle
  merge-lock protocol, "-D required because squash merge," etc. are
  all real constraints of how Beacon's `infra` repo and its
  `pre-merge-review.sh`/`merge-lock.sh` machinery work. It also
  contains genuinely machine-and-person-generic preferences (shell
  script standards, safety boundaries around `rm -rf`, git hygiene)
  that presumably should apply everywhere, Beacon or not.
- **`~/.claude/settings.json` (global) hooks are unconditional.**
  Confirmed by reading the file directly: `PreToolUse` hooks for
  `Bash` (`hook-block-all.sh`, which is the dispatcher that includes
  the `--no-verify` block), `Write`/`Edit` (merge-lock file
  protection), and `EnterWorktree` all fire for every tool call in
  every project, with no repo-path or org check inside the hook
  scripts themselves (spot-checked `hook-block-no-verify.sh` and
  `hook-block-short-no-verify.sh` directly — both operate purely on
  the command string, never on `cwd` or repo remote).
- **Project-scoped settings already exist and are the likely lever.**
  `beacon/infra/.claude/settings.local.json` exists today, currently
  used only for a short permissions allowlist (a few `Bash`/Slack MCP
  tool permissions). Claude Code's settings resolution already layers
  project-local settings on top of global ones — this file is real,
  live, and already proven to work in this exact repo. It is a
  plausible anchor point for "company-repo-specific rules," but its
  current scope is permissions, not hook wiring or CLAUDE.md content —
  extending it to also carry hook overrides has not been tried in
  this session.
- **Beacon's own repos already declare their own CLAUDE.md/AGENTS.md**
  (e.g. `infra/CLAUDE.md`, `platform-datastore/CLAUDE.md`,
  `knowledge-base/CLAUDE.md`, and the umbrella
  `~/Developer/beacon/CLAUDE.md`). These are checked into the repos
  themselves (company-owned, shared with all contributors, not
  personal to Andrew) and are loaded *in addition to* the global
  `~/.claude/CLAUDE.md`, not in place of it. Today, both layers apply
  simultaneously with no mechanism to suppress or relax global rules
  when a repo-local file is present — e.g. the global merge-lock
  protocol and the infra repo's own PR/security rules just stack.
- **No signal distinguishes "Beacon repo" from "personal repo" today
  beyond the human's own mental model of which directory they're in.**
  There's no marker file, git remote check, or path-prefix convention
  currently read by any hook or settings layer to make that
  distinction machine-readable.

### What a solution needs to reconcile

Restating the goal precisely, based on Andrew's request: on a
company-owned machine, in a company repo, company rules should be
enforced and personal rules relaxed/overridden. On Andrew's personal
machine(s) (ASIAGO.local and others), in personal or
`nightowlstudiollc` or other non-Beacon repos, Beacon rules should not
apply and personal rules should apply. This implies the actual
switching signal is not purely machine identity or purely repo
identity — it's the combination, and today's setup only has the
building blocks for one axis (project-local settings, which is
repo-scoped) but nothing for the other (machine-scoped conditionals),
and nothing that combines them or treats them as an either/or override
relationship rather than an always-additive stack.

Given the confirmed absence of any existing machine-identity check
anywhere in the current config, and the confirmed presence of a working
project-settings layering mechanism, the two known real anchor points
for a future design are: (1) `hostname`/machine-identity detection,
which does not exist yet and would need to be added fresh (e.g. inside
`hook-session-start.sh`, which already fires on every session and
already knows how to shell out — it currently only prints environment
info, per the Protocol 0 template in the global CLAUDE.md); and (2)
per-repo `.claude/settings.local.json` / repo-local CLAUDE.md files,
which already exist and already layer on top of global settings, but
whose layering today is strictly additive, never override-and-relax.
No further design decision is made here — this section only documents
what building blocks are confirmed to exist versus confirmed absent,
for Claude Desktop to reason over.
