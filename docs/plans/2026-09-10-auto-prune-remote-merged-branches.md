# PRD: Auto-prune locally-stale branches whose remote is gone

**Status:** proposal
**Date:** 2026-09-10
**Author:** arich (drafted by Claude Code)

## Problem

All merging in the `beacon-biosignals` org happens remotely: PRs are
squash-merged on GitHub and the branch is deleted there. Nothing deletes the
local copy. Local checkouts therefore accumulate branches whose work has fully
landed, indistinguishable at a glance from branches with unmerged work.

This is not cosmetic. It produced a wrong conclusion in a real session
(2026-09-10, `beacon-biosignals/infra`): a scan for policy-violating branches
reported two of five as carrying live unmerged work. Both had in fact merged
weeks earlier (PRs #6493, #6484). The check used was:

```bash
git branch --merged origin/main
```

**`--merged` cannot detect a squash-merge.** Squashing produces a new commit
whose parent history omits the branch tip, so the tip never becomes an ancestor
of `main`, and `--merged` correctly-but-uselessly reports "not merged" forever.
The two branches were also 12–27 commits behind, which made them look like
neglected in-progress work rather than completed work.

The cost of the gap: a human is asked to adjudicate branches that need no
decision, and — worse — an agent may report merged work as pending and act on
that. The wrong signal is the deliverable failure, not the disk usage.

## Goals

1. Local branches whose remote counterpart has been deleted are pruned
   automatically, without the user asking.
2. Zero risk of deleting a branch that holds commits existing nowhere else.
3. Works when the merge was a squash (the common Beacon case), a rebase, or a
   merge commit — i.e. does not depend on ancestry.
4. Cheap enough to run unattended and often; no network cost the user did not
   already incur.

## Non-goals

- Pruning branches with no upstream at all (purely local work). Out of scope:
  indistinguishable from work-in-progress.
- Pruning remote branches. The remote is GitHub's to manage via
  "delete branch on merge".
- Enforcing branch *naming*. That is a separate, already-recorded rule
  (`initials/the-topic` in Beacon repos).
- Any behavior in non-Beacon repos beyond what is safe generically.

## Mechanism

Do not use `--merged`. Use upstream-gone detection: after a pruning fetch, git
marks a local branch whose configured upstream no longer exists as `[gone]`.

```bash
git fetch --prune                     # updates remote-tracking refs
git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads \
  | awk '$2=="[gone]"{print $1}'      # branches whose remote was deleted
```

This is ancestry-independent, so squash-merges are detected correctly.

**Validated 2026-09-10** against a genuine known-bad case in
`beacon-biosignals/infra`: a branch tracking a fabricated remote ref reported
`track=[]` while that ref existed, and `track=[[gone]]` after it was deleted.
Run across the real repo it matched exactly the one planted branch, with no
false positives among five live branches. (A first attempt at validation —
tracking a ref that still existed — proved nothing and was discarded; a clean
result from a check never shown to fail is not evidence.)

### Safety gate — required

`[gone]` alone is insufficient. A branch can have a deleted upstream *and*
local commits that were never pushed (e.g. the remote branch was deleted while
work continued locally, or the PR was closed unmerged). Delete only when the
branch holds nothing unique:

```bash
# unique commits reachable from $b but not from any other ref
git rev-list --count "$b" --not --exclude="refs/heads/$b" --all
```

Delete only if that count is `0`, using `git branch -d` (not `-D`) as a second
independent guard. If the count is non-zero, **report, never delete** — this
is the case that most needs a human, and it is exactly the case a naive
implementation would destroy.

Additional refusals:
- Never touch the currently checked-out branch.
- Never touch `main` / the default branch, regardless of state.
- Skip repos with a rebase/merge/bisect in progress.
- Skip a dirty working tree if the branch is checked out.

## Placement

Two candidates were considered against the real deployment layout.

**Recommended: a script in `claude-config`, invoked by a hook.**
`scripts/prune-gone-branches.sh`, wired as `SessionStart` alongside the
existing `hook-session-start.sh`. Rationale:

- `SessionStart` already exists and already surfaces a background queue
  (`pending-issues`), so this matches an established pattern.
- Runs once per session — frequent enough to keep checkouts clean, rare enough
  that a `fetch --prune` per repo is not a cost concern.
- Testable in isolation; `claude-config/scripts/tests/` and `hooks/tests/`
  already exist.
- Independent of `gh`, so it works for plain `git` workflows too.

**Rejected: extending `gh-wrapper.sh`.** The wrapper lives in the *dotfiles*
repo (`~/Developer/dotfiles/bash/gh-wrapper.sh`, deployed to
`~/.config/bash/`), not in `claude-config`, so this PRD's home repo cannot own
it. It is also already 913 lines carrying unrelated concerns (draft-forcing,
merge-lock enforcement, real-binary resolution), and it only triggers on `gh`
invocations — branches go stale after a *merge*, which the user may perform in
the GitHub UI without ever running `gh` locally. Wrong trigger, wrong repo.

A `gh pr merge` post-hook could complement the above later (prune immediately
after a self-merge), but must not be the primary mechanism.

### Scope of repos

Operate on the repos in the current session's workspace. In
`~/Developer/beacon-biosignals`, that is each child checkout — the workspace
root is not a git repo, so the script must iterate children rather than assume
a single toplevel. Behavior must be identical in single-repo workspaces.

## Interaction with the existing documented tool

`~/.claude/docs/INFRASTRUCTURE.md:27` documents a "Branch cleanup"
entry — `audit-branches.sh` at `~/.claude/scripts/audit-branches.sh`. **That
file does not exist**, at that path or anywhere in `claude-config` or
`~/.claude/scripts/` (verified 2026-09-10). The row is stale documentation
pointing at a tool that is absent.

Resolve deliberately, per Chesterton's Fence: establish whether it was ever
written and what it did (`git log --all -- '*audit-branches*'` in
`claude-config` and `dotfiles`) before either reviving the name or removing the
row. Do not silently create a differently-named script and leave the stale row
in place — that is how the four wrong conclusions in the 2026-09-10 session
started.

## Output contract

Quiet on the happy path; a hook that chatters gets ignored.

- Pruned nothing: print nothing (exit 0).
- Pruned N: one line per repo, e.g.
  `[prune] infra: deleted 2 merged-remote branches (arich/foo, arich/bar)`.
- Found `[gone]` branches holding unique commits: one warning line naming them
  and the unique-commit count, and **do not delete**. This is the line that
  earns the feature its trust.
- Never fail the session. Any git error is reported and skipped; exit 0
  regardless, matching `hook-session-start.sh`'s treatment of a missing
  directory as normal.

## Testing

Under `scripts/tests/`, following existing convention. Each case builds a
throwaway repo pair in a temp dir — no network, no real remote.

1. **Squash-merge case (the motivating bug):** branch pushed, squash-merged
   into main remotely, remote branch deleted → pruned. Assert `--merged` would
   *not* have caught it, so the test fails if someone "simplifies" the
   implementation back to `--merged`.
2. **Unique-commits guard:** `[gone]` upstream plus an unpushed local commit →
   NOT deleted, warning emitted.
3. **No upstream:** purely local branch → untouched.
4. **Current branch** is `[gone]` and safe → untouched (cannot delete checked-out).
5. **`main`** never deleted.
6. **Clean repo** → no output, exit 0.
7. **Multi-repo workspace** → each child handled independently; one broken repo
   does not abort the rest.
8. **Rebase in progress** → skipped.

`shellcheck -S info` clean, no `# shellcheck disable`, and `((var += 1))` not
`((var++))` per the shell standards in `CLAUDE.md`.

## Open questions

1. **Fetch cost.** Every session start would `fetch --prune` each checkout in
   the workspace. In `beacon-biosignals` that is 5 repos, one of them large.
   Acceptable, or gate behind a staleness check (skip if `FETCH_HEAD` is newer
   than N minutes)?
2. **Auto-delete vs. report-only default.** This PRD assumes auto-delete when
   provably safe. A more conservative first release reports and offers the
   command. Given the safety gate makes data loss essentially impossible, and
   the whole point is to stop asking the human about non-decisions,
   auto-delete is recommended — but it is a preference call.
3. **Scope beyond Beacon.** The mechanism is generically correct. Enable
   everywhere, or restrict to `beacon-biosignals` initially where the
   squash-merge-remotely workflow is known to hold?
4. **`audit-branches.sh`** — revive the documented name, or remove the stale
   row? Depends on the history check above.
