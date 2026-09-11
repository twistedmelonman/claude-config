---
name: receive-handoff
description: Use when the user explicitly says "receive handoff," "pick up where I left off," or starts a session continuing work saved by an earlier session. Reads the Google Drive handoff export and loads the files and KB entries it points to, so this session starts with working context rather than a description of context. Typically the first message of a session.
version: 1.3.0
---

# Receive Handoff

## When to use

Trigger only on an explicit handoff request, ideally as the first message in a
new session.

## Before you start: load the connector

The Google Drive tools are often not loaded at session start. Load them before
step 1. In Claude Code, use `ToolSearch` with a query selecting the Drive
tools (`search_files`, `read_file_content`). The tool-name prefix varies by
client — do not hardcode it. If the Drive tools cannot be loaded at all, say
so plainly and stop; do not proceed as if the handoff had been read.

## What to do

1. Identify the workstream. If the user already named one, use it.

   Otherwise **search before asking** — a broad search costs one call and
   usually removes the need for the question entirely:

   ```text
   title contains 'Claude Handoff' and mimeType = 'application/vnd.google-apps.document'
   ```

   - Exactly one workstream in the results → use it and say which one you
     picked. Do not ask; asking a question with one possible answer wastes a
     round-trip that the user has to sit through.
   - More than one → ask once, and **list the workstreams you found** with
     their dates, so the answer is a selection rather than a recall exercise.
   - None → say so plainly and ask whether to start a new one.

2. Find the document. Search by title, not by a remembered file id:

   ```text
   title contains 'Claude Handoff - <workstream>' and mimeType = 'application/vnd.google-apps.document'
   ```

   **Select the match with the newest `modifiedTime`.** This rule is load-
   bearing. `prepare-handoff` writes a new document per handoff and then
   trashes the older ones, so a leftover match means a trash call failed.
   Reading the newest is correct whether or not that cleanup succeeded.

   If more than one match survives, read the newest and **report the others to
   the user as stale copies**. Do not merge them.

3. Read the document with `read_file_content`.

   Expect the Markdown syntax to come back backslash-escaped (`\#`, `\-`,
   `` \` ``) — an artifact of the plain-text-to-Doc conversion, verified
   2026-09-11. The content is intact. Read through the escaping; do not treat
   it as corruption and do not report the document as malformed because of it.

   **Strip the escapes out of any identifier before you use it.** The
   escaping is not confined to markup — it lands inside the pointers
   themselves, so a value copied verbatim out of the document will fail or,
   worse, look up the wrong thing. Verified 2026-09-11:

   | In the document | Actual value |
   |---|---|
   | `D\_kwDOC5tEDM4AocXf` | `D_kwDOC5tEDM4AocXf` (pasted as-is: GraphQL "malformed" error) |
   | `\#3604` | `#3604` |
   | `snapshot\_debian\_timestamp` | `snapshot_debian_timestamp` |
   | `git\_pkgs\_proxy` | `git_pkgs_proxy` |

   Before any grep, `gh` call, API lookup, or file open, **strip every
   backslash that precedes a non-alphanumeric character.** Use the general
   rule, not a list of characters to watch for: the same document also
   contains `\[r\] SRE Q3/Q4 2026`, so brackets escape too, and any
   enumeration will miss whichever character appears next.

   A grep for an escaped identifier returns empty, which reads exactly like
   "this work is already done" — an escaping artifact that imitates a real
   finding. When a grep for something from the export comes back empty, rule
   out escaping before reporting it as a state change.

4. **Check which sections are present before following any pointer.**
   `prepare-handoff` requires these:

   Timestamp · Task · Files in scope · Remote / PR state · Uncommitted work ·
   Relevant KB / memory · Issue tracker · Decisions locked · Open questions ·
   Next step

   Three of them — **Remote / PR state**, **Uncommitted work**, and **Issue
   tracker** — cannot be written from recollection. They only exist if the
   writer actually ran `git` and `gh`. The others can be composed from memory
   and a prior document, and therefore survive even when nothing was verified.

   So if any of those three is absent, or folded into another section (PR
   states listed as bullets under **Files in scope**, for example), treat the
   whole export as **unverified**: report that first, and downgrade every
   mutable claim in it to a claim needing a fresh lookup rather than checking
   a sample. This is worth doing because it is mechanical — it tells you the
   document was not verified without requiring you to trust the writer's
   account of how carefully it was written.

   An older export may predate these sections; check the export's Timestamp
   against the skill's own version history before calling their absence a
   defect. A document written against an earlier version did not skip them.

5. Follow the pointers, not just the labels:

   - For each entry under **Relevant KB / memory**, read that specific file or
     memory path directly rather than proceeding on the label alone.
   - **Resolve a relative path against every plausible root before calling it
     missing.** A path like `knowledge-base/topics/<area>/projects/<project>/status.md`
     looks repo-relative, but a cloud-drive mount has its own root and the
     same path may resolve there. A cloud drive synced to the local
     filesystem is reachable with ordinary file tools — it is not
     API-only — so "the connector did not return it" is not evidence of
     absence either. Before reporting any path missing, try:

     ```bash
     # the obvious repo root
     ls <repo>/<path>
     # local sync mounts (macOS Google Drive shown; adjust per provider)
     ls ~/Library/CloudStorage/GoogleDrive-*/My\ Drive/<path>
     # and fall back to a name search rather than concluding from two misses
     find <candidate-root> -name "$(basename <path>)" -not -path '*/.git/*' 2>/dev/null
     ```

     **Check project memory for the answer first.** A recorded reference
     memory naming the correct root is faster and more reliable than
     searching, and a prior session has usually already paid this cost. This
     exact failure has happened: a KB path was reported missing from the git
     repo and the Drive API while all four files sat readable at the local
     Drive sync mount — and a memory entry recording that mount path already
     existed, unconsulted. "Not where the export implied" means the root is
     wrong far more often than it means the file is gone.
   - For **Files in scope**, open the files needed to act on the stated
     **Next step**. Don't open every listed file speculatively if only one or
     two are relevant to the immediate next action — open the rest on demand
     as the session requires them.
   - **Check the branch per repo, and treat a missing branch as a defect, not
     a pass.** "Every repo" means every `owner/repo` string anywhere in the
     document, plus every local checkout containing a listed path — not just
     the entries that look like repos. **Files in scope** routinely mixes
     repos, PR numbers, Discussion ids, and tracker GIDs in one list, so
     counting its bullets is not the same as counting repos.

     A PR or issue written as a bare `#N`, with no `owner/repo`, is
     **ambiguous, not obvious**. Resolve it against each candidate repo and
     say which one you inferred; a number that exists in two repos will
     silently answer for the wrong one.

     For every repo so identified:

     ```bash
     git -C <repo> branch --show-current
     git -C <repo> log --oneline -1
     git -C <repo> status -sb
     git -C <repo> status --porcelain
     ```

     A workspace can hold several checkouts and its top directory may not be a
     repo at all, so there is no single "current branch" to compare against —
     resolve each repo separately.

     If the export names **no** branch for a repo, that is a reportable
     omission. Do not let the check quietly succeed because there was nothing
     to compare: a verification step that passes on absent data is worse than
     no step, because it produces false confidence. If the export names a
     branch that differs from the checked-out one, report the mismatch rather
     than switching.

   - **Reconcile every claim about mutable external state before trusting
     it.** PR states, issue states, and access grants change after the
     document is written, and they are the claims most likely to be both
     wrong and load-bearing. For each PR, issue, or grant the export
     mentions:

     ```bash
     gh pr view <n> --repo <owner/repo> --json number,state,isDraft,mergedAt
     gh pr list --repo <owner/repo> --head <branch> --state all \
       --json number,title,state,isDraft
     gh issue list --repo <tracker> --state open --label <area>
     ```

     Also look for work the export does **not** mention: an open PR on the
     branch it named, or open tracker items for this workstream, are things
     the next action depends on.

     **Compare each change time against the export's Timestamp, and separate
     wrong-at-write from decayed.** A claim whose `mergedAt`/`closedAt`/
     `createdAt` *predates* the Timestamp was already false when the document
     was written — the writer did not run the lookup. A claim that changed
     *after* the Timestamp is ordinary decay. These have different causes and
     different fixes, so do not merge them into one "stale" list: report the
     wrong-at-write ones separately and say so, because they mean every
     unverified claim in the document is suspect, not just the ones you
     happened to check. Report as: claim | actual | changed at | export
     written at.

   - **`MERGED` does not mean "in effect."** A merged PR can be reverted, and
     the revert usually does not say "revert" — an incident-mode fix uses
     `git checkout <sha>^ -- <files>`, which lands as an ordinary commit. So
     `git log --grep=revert` is the check that misses. Scope the query to what
     the PR touched instead, and cross-check the tracker for the PR number:

     ```bash
     gh pr view <n> --repo <owner/repo> --json mergedAt,files
     git -C <repo> log --oneline origin/main --since=<mergedAt> -- <paths it touched>
     gh issue list --repo <tracker> --state all --search '<owner/repo>#<n>'
     ```

     An export that calls a merged change "live and verified" is making a
     claim about the current tree, not about the merge. Resolve it against the
     tree.

   - **Before acting on the Next step, verify it is still undone.** Grep the
     live tree for whatever identifier the Next step implies, and check
     whether a PR already covers it. An empty grep or an existing PR means
     the step is done or in flight. This is the single highest-value check in
     the skill: the observed failure mode of handoff documents is to
     understate progress, so a Next step that proposes destructive or
     hard-to-reverse work — a destroy/recreate, a migration, a rename of live
     resources — must be confirmed as not-yet-applied before anyone runs it.

   - **Agreement between the export and a document it cites is not
     corroboration.** A `HANDOFF-*.md`, KB `status.md`, or journal entry the
     export points at is most likely where the export got the claim, so
     finding the same statement there is one source counted twice. This is how
     a wrong claim reads as triple-confirmed. Date the artifacts against the
     tree before believing any of them:

     ```bash
     git -C <repo> log -1 --format=%ci -- <path>   # or `stat` for an untracked file
     ```

     An untracked, git-excluded note carries no staleness signal at all — no
     diff, no history, nothing to show it was superseded — so an artifact
     older than the commit that contradicts it loses to the commit.

   - **Say which claim classes you could not verify.** `git` and `gh` cover
     repos and GitHub, and nothing else. Asana GIDs, Slack references, Drive
     documents, and access grants need their own connector, which may not be
     loaded in this session. Try it if it is; if not, write "not verified from
     this client" for that class in the report. Silence about a class must not
     read as verified — an unlabeled gap is indistinguishable from a pass.

   - **Note pointers that cannot exist in this client.** If the export points
     at persistent memory, "this Project's instructions," or another
     client-scoped store, that namespace may not exist in this session.
     Check what is actually present (for example the project memory directory)
     rather than assuming the pointer resolved. Content that lived only in
     another client's store is **lost**, not merely unread — report it as
     missing context, because the export will typically say it deliberately
     did not restate that content.

6. Present back to the user, in compact form: task, next step, and anything
   that looks stale, contradictory, or missing. Report specifically:

   - **an export missing Remote / PR state, Uncommitted work, or Issue
     tracker** — say plainly that it appears unverified, and that the mutable
     claims in it were not checked by the writer
   - **claims that were already wrong when the document was written** —
     separately from ones that decayed afterward, with both timestamps

   - referenced files or KB paths that no longer exist — only after trying
     every plausible root, including local cloud-drive sync mounts, and only
     after checking project memory for a recorded root. Say which roots you
     tried. "Missing" asserted from one failed lookup is the easiest wrong
     finding to produce in this whole skill, and it reads as authoritative.
   - a path whose stated location is wrong — a repo-shaped path that actually
     lives in a cloud drive, or vice versa. Say where it really is; do not
     report it as missing when it resolved somewhere else.
   - a decision in the export that conflicts with something just read in the
     KB or the code
   - extra handoff documents found in step 2
   - a branch mismatch from step 5, **or a repo for which the export named no
     branch at all**
   - a merged change the export calls live that the tree shows was reverted
   - claim classes you could not verify from this client (Asana, Slack, Drive),
     named explicitly rather than left out
   - any claim about a PR, issue, or access grant that no longer matches
     live `gh` state — list claim vs. actual
   - work in flight that the export omits: an open PR on the named branch,
     open tracker items for this workstream, uncommitted or untracked files
   - **a Next step that is already done or in flight** — state this first and
     plainly, before summarizing anything else, because it invalidates the
     rest of the plan
   - client-scoped pointers (memory, Project instructions) unreachable from
     this session, and therefore context that is gone rather than unread

   Then wait for the user's next message before acting.

## Constraints

- Treat the export as context, not as a task list to execute unprompted. The
  **Next step** line is information about what was intended, not permission to
  do it.
- **The export is a set of claims about state, not state.** It was accurate
  when written and decays from that moment. Read every line as "the previous
  session believed X," then resolve X against the live tree, `gh`, and the
  filesystem. This matters most where the document is most confident: a
  decision recorded as locked, or an item recorded as pending.
- **Assume the export understates progress.** That is the observed bias in
  real handoffs — branches get committed, PRs get merged, blockers get
  resolved, and none of it writes itself back into a document. When the
  export and the live state disagree, the live state wins and the work is
  usually further along than described.
- Read-only verification is in scope while waiting for the user: greps, file
  reads, `git status`/`log`, and `gh` lookups are all part of following the
  pointers. Switching branches, editing files, and executing the **Next
  step** are not.
- If the document does not exist, say so plainly and ask whether to start a
  new one. Do not guess at prior content.
- If the Drive connector is unavailable, the read fails, or a referenced
  file/KB path can't be found, say so plainly instead of proceeding as if it
  resolved. A partially loaded handoff reported as complete is worse than a
  failed one.
