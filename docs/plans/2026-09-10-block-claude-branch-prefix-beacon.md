# PRD: Hard-block `claude/` branch names in beacon-biosignals repos

**Status:** proposal
**Date:** 2026-09-10
**Author:** arich (drafted by Claude Code)
**Companion:** `2026-09-10-auto-prune-remote-merged-branches.md`

## Problem

Beacon's documented convention
(`knowledge-base/handbook/code-and-data.md:49`) is:

> Branch names should conform to the format `initials/the-topic`, e.g.
> `jr/fix-this-dumb-bug`

Global Protocol 1 in `~/.claude/CLAUDE.md` mandates the opposite for agents:

```
git checkout -b claude/<type>-<description>-<session-id>
```

Protocol 1 carries no org exception, so an agent following its own mandatory
instructions produces a branch that violates the host org's convention. This is
not hypothetical drift — it happened **7 times** in `beacon-biosignals/infra`
between 2026-08-25 and 2026-09-10:

| PR | Branch | Outcome |
| --- | --- | --- |
| #6445 | `claude/r9-1-employee-auth-fe37bbb8` | merged into `main` |
| #6475 | `claude/fix-r9-1-keycloak-refs-0d793d31` | merged into `main` |
| #6484 | `claude/julia-pkg-server-active-membership` | merged into `main` |
| #6493 | `claude/git-pkgs-proxy-ecr-upstream-auth-5cb04eb9` | merged into `main` |
| #6510 | `claude/rename-git-pkgs-proxy-mvp-b687d2c9` | closed, recreated as #6512 |
| #6436 | `claude/infra-maintainers-arich-58655774` | closed, recreated as #6513 |
| #6435 | `claude/sre-admin-access-arich-58655774` | closed, recreated as #6514 |

Four landed in Beacon's `main` history permanently. Three required manual
remediation on 2026-09-10 (delete remote → rename → rebase → push → recreate
PR), which cost three PR numbers and closed a PR that already had a review
requested.

The rule has since been recorded in three local files (workspace-root
`CLAUDE.md`, `knowledge-base/CLAUDE.local.md`, and project memory). **That is
documentation, not enforcement.** Protocol 1 is also documentation, it is
marked mandatory, and it says `claude/`. Two documents in direct conflict
resolve however the agent's attention happens to fall that session. Only a
mechanical block makes the outcome deterministic.

## Goals

1. `git checkout -b claude/…` (and equivalents) in a `beacon-biosignals` repo
   fails, before the branch exists.
2. No opt-out, no env-var escape hatch — the same posture as the draft-forcing
   rule it is modeled on.
3. The error message states the correct name to use, so the agent's next
   attempt succeeds without a round-trip to the user.
4. Zero effect outside Beacon repos: `claude/` remains correct in
   `claude-config`, `dotfiles`, and `beacon-issues`.

## Non-goals

- Renaming the four already-merged branches. They are immutable history.
- Enforcing the *rest* of the convention (that the prefix is genuinely the
  user's initials, that the topic is descriptive). Block the known-wrong
  prefix; do not attempt to validate arbitrary names.
- Blocking `claude/` on the remote side. Not possible from this machine.

## Why this is NOT the same mechanism as draft-forcing

The request modeled this on `gh-wrapper.sh`'s off-org draft-forcing. That
analogy is right about *posture* — mechanical, no opt-out — but the mechanism
does not transfer, for three reasons found by reading
`~/Developer/dotfiles/bash/gh-wrapper.sh:519-530`:

1. **Wrong tool.** Draft-forcing intercepts `gh pr create`. Branch creation is
   `git checkout -b` / `git switch -c` / `git branch` — never `gh`. The wrapper
   never sees it.
2. **Wrong repo.** `gh-wrapper.sh` lives in **dotfiles**, deployed to
   `~/.config/bash/`. A `claude-config` PRD cannot own it.
3. **Inverted allowlist.** The wrapper's list
   (`smartwatermelon | nightowlstudiollc | twistedmelonman`) is the *in-org*
   set, and it force-drafts everything **else** — which is why Beacon PRs come
   back as drafts. Reusing that list would apply this rule to every non-Beacon
   repo and exempt Beacon, the exact opposite of the requirement. Beacon
   appears in a *different* list in the same file
   (`_gh_wrapper_sync_identity`: `beacon-biosignals | andrewmrich`), which is
   the one whose sense matches.

**Recommended mechanism instead:** a `PreToolUse` Bash hook in
`claude-config/scripts/`, chained from `hook-block-all.sh`, following
`hook-block-main-commit.sh`. That is the established pattern for "block a
command shape before it runs," it already handles the subcommand-position and
`git -C` problems described below, and it sits in the repo this PRD belongs to.

## Mechanism

`scripts/hook-block-claude-branch.sh`, chained from `hook-block-all.sh`
(`PreToolUse`, Bash matcher).

### Detection

Fire only when a command **creates** a branch whose name starts with
`claude/`, in a repo owned by `beacon-biosignals`. Creation forms to match:

```
git checkout -b claude/x        git checkout -B claude/x
git switch -c claude/x          git switch -C claude/x
git branch claude/x             git branch -m <old> claude/x
git push origin HEAD:refs/heads/claude/x
```

Reuse `hook-block-main-commit.sh`'s **subcommand-position regex**, not a
substring test. That file documents (from #429) exactly why substring matching
is wrong in both directions: it blocks read-only commands that merely mention
the word, and it misses real invocations that are wrapper- or path-qualified
(`env FOO=1 git …`, `/usr/bin/git …`). Both apply here verbatim — e.g.
`git log --all --grep=claude/` must not be blocked.

### Which repo is judged

Same problem and same resolution as `hook-block-main-commit.sh`: honor
`git -C <path>` when present, since that is the repo the command acts on; fall
back to the hook's own cwd otherwise, and **say which basis was used** in any
block message. The Bash tool's cwd is stateful and drifted twice during the
2026-09-10 session (once into `knowledge-base`, once into `infra`), so a
cwd-based verdict can name the wrong repo. Do not omit this.

### Owner resolution

Resolve owner from `git config --get remote.origin.url` for the judged repo,
stripping scheme/host and taking the first path segment — the same
normalization `_gh_wrapper_resolve_owner` performs, which correctly handles
both `git@github.com:beacon-biosignals/infra.git` (Beacon's SSH remotes) and
HTTPS URLs.

Block only when owner is `beacon-biosignals`, case-insensitively. Explicitly
**not** in scope: `andrewmrich/beacon-issues` (personal), `git-pkgs/proxy`
(a third-party checkout that sits inside the Beacon workspace directory —
verified 2026-09-10, so directory location alone is not a safe proxy for
ownership).

### Failure mode

Fail **open**, not closed. If owner cannot be resolved (no remote, detached
state, unreadable config), allow the command. A branch-naming violation is
cheap to fix; a hook that blocks all branch creation in an unrecognized repo
breaks every workflow on the machine. This differs deliberately from
`_gh_wrapper_sync_identity`'s fail-closed stance on identity, where acting as
the wrong account is the worse outcome.

### Message

```
BLOCKED: `claude/` branch prefix is not allowed in beacon-biosignals repos.

Beacon convention (knowledge-base/handbook/code-and-data.md): initials/the-topic
  use:  arich/<topic>          e.g. arich/fix-keycloak-client-tag
  not:  claude/<type>-<desc>-<session-id>   (global Protocol 1 — does not apply here)

Judged repo: <path> (basis: -C flag | cwd)
```

Naming the correct form inline is the point: the agent retries correctly
instead of asking the user. State that this overrides Protocol 1 *for the
prefix only* — never committing to `main`, branching before committing, and
verifying with `git branch --show-current` still apply.

## Testing

Under `scripts/tests/`, matching existing convention. Each case feeds the hook
a synthetic `PreToolUse` JSON payload on stdin and asserts the exit code.

**Must block** (in a `beacon-biosignals` remote):

1. `git checkout -b claude/foo`
2. `git switch -c claude/foo`
3. `git branch claude/foo`
4. `git branch -m old claude/foo`
5. `git -C /path/to/infra checkout -b claude/foo` — judged via `-C`
6. `/usr/bin/git checkout -b claude/foo` — path-qualified
7. `env FOO=1 git checkout -b claude/foo` — wrapper-qualified
8. `git push origin HEAD:refs/heads/claude/foo`

**Must allow:**
9. `git checkout -b arich/foo` — conforming name
10. `git log --all --grep=claude/` — mentions, creates nothing
11. `git show HEAD # claude/foo` — comment only
12. `git branch --list 'claude/*'` — read-only
13. `git checkout -b claude/foo` in a `smartwatermelon` remote — off-scope
14. `git checkout -b claude/foo` in `andrewmrich/beacon-issues` — off-scope
15. `git checkout -b claude/foo` with no remote — fails open
16. `git checkout claude/foo` — switching to an *existing* branch, not creating

Case 16 matters for the remediation flow: while cleaning up violations you must
still be able to check out an offending branch to rename it.

`shellcheck -S info` clean, no `# shellcheck disable`, `((var += 1))` not
`((var++))`.

## Open questions

1. **Should this generalize?** A `beacon-biosignals`-only block is narrow. The
   same conflict will recur in any org with its own convention. Options: keep
   it hardcoded (simple, matches the wrapper's precedent), or drive it from a
   small owner→prefix-policy table. Recommend hardcoding first; generalize on
   the second occurrence.
2. **Fix Protocol 1 itself?** The block treats a symptom. Protocol 1 is the
   thing that says `claude/` with no org exception. Adding "unless the repo's
   org defines its own convention" to `~/.claude/CLAUDE.md` removes the
   conflict at the source — the hook then catches only genuine slips rather
   than compliance with a contradictory rule. **Recommend doing both**; the
   hook alone leaves an agent stuck between two mandatory instructions with no
   documented resolution.
3. **Retroactive audit?** The 7 known violations were found by scanning 5 local
   checkouts. The user confirmed unclonedrepos imply no work, so coverage is
   believed complete — but that rests on the assumption holding. Worth one
   org-wide `gh` sweep to confirm, or accept the assumption?
4. **`git push` coverage.** Case 8 blocks the explicit refspec form. A plain
   `git push -u origin claude/foo` after the branch already exists locally is a
   second chance to catch a violation that slipped through. Block there too, or
   treat local creation as the single choke point?
