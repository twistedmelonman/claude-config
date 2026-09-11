---
name: prepare-handoff
description: Use when the user explicitly says "prepare handoff," "wrap up for handoff," or asks to save the current session's state so another session can resume the work. Writes a dense, structured export — not a prose summary — to a Google Drive document so a later session can resume with minimal re-derivation. Verifies every path, branch, and identifier it records before writing, so the next session does not inherit stale pointers. Do not trigger on generic session-ending language like "thanks" or "bye."
version: 1.3.0
---

# Prepare Handoff

## When to use

Trigger only on an explicit handoff request. Do not infer intent to end a
session from tone or politeness language.

## Governing principle

The receiving agent burns tokens every time it has to guess what something
means. Optimize for zero re-derivation, not for brevity. Density beats
compression: a file path costs fewer tokens to write than the paragraph
explaining what's in it, and it's unambiguous. No word cap on this document —
the cap is on ambiguity, not length.

Write for a reader with no memory of this session and no ability to ask a
follow-up. Resolve every pronoun and vague referent ("it," "that approach,"
"the fix") into the specific thing it refers to.

Each handoff creates a new document and retires the previous one. The newest
document must therefore reflect the full current state of the task —
everything still true, from this stint or any earlier one — not just what
changed since the last handoff. If in doubt whether something belongs, ask:
would dropping this leave the next agent unable to reconstruct it from
anywhere else? If yes, include it.

## Before you start: load the connector

The Google Drive tools are often not loaded at session start. Load them before
step 1. In Claude Code, use `ToolSearch` with a query selecting the Drive
tools (`search_files`, `create_file`, `update_file`, `trash_file`,
`read_file_content`). The tool-name prefix varies by client — do not hardcode
it. If the Drive tools cannot be loaded at all, skip to the fallback in
**Constraints**.

## What to do

1. Identify the workstream. If the user already named one this session, use
   it. Otherwise ask once: "Which handoff doc — name or workstream?"

   Document title format: `Claude Handoff - <workstream> - <YYYY-MM-DD HHMM>`.
   The timestamp is part of the title because each handoff is a new file;
   it makes the newest one identifiable from search results alone, without
   opening any document.

   Do not put a file extension in the title. Drive titles have no extension —
   a `.gdoc` suffix is a local-sync artifact and will not match on search.

2. Locate the folder named `Claude Handoff`:

   ```text
   title = 'Claude Handoff' and mimeType = 'application/vnd.google-apps.folder'
   ```

   - If it exists, use its `id` as `parentId` in step 5.
   - If it does not exist, create it (`mimeType:
     application/vnd.google-apps.folder`) and use the returned id.

   Do not share the folder and do not ask about sharing. A single Google
   account owns and reads every handoff document; the accounts this skill
   hands off between are Claude accounts on the same machine, not Google
   accounts. Sharing is not part of this workflow.

3. Compose the export with exactly these sections:

   - **Timestamp** — current date and time
   - **Task** — what we're doing, stated as a concrete goal, not a narrative
     of how we got here
   - **Files in scope** — every file, repo, or path currently relevant to the
     task, whether touched in this stint or carried forward from an earlier
     one, one line each: path + one clause on its role. This is a manifest,
     not prose. Drop a file only once it's no longer relevant to the task, not
     just because this stint didn't touch it.

     State the **working branch explicitly**, on its own line, for every repo
     listed — not "if relevant." A handoff that names no branch reads as
     though work has not started, which silently understates progress when a
     branch with commits already exists.

     Mark every path with where it actually lives: local filesystem, a git
     repo (and which), or a cloud drive. See **Pointer discipline** below.
   - **Remote / PR state** — for every repo in **Files in scope**: whether the
     branch is pushed, its ahead/behind count, every open or recently merged PR
     for that branch, and their CI status. A PR that exists and is green is the
     most decision-relevant fact about a workstream, and it has no other home —
     without this section it gets recorded nowhere and the next agent plans
     work that is already in review.

     **Record the `gh` output, not a paraphrase of it**, one line per PR:
     `owner/repo#N <state> mergedAt=<value>`, plus the time you ran the
     lookup. Always write the full `owner/repo#N` form — a bare `#N` is
     ambiguous across repos and the receiving agent has to guess which one.
     A pasted `mergedAt` is distinguishable from a remembered "open"; a
     paraphrase is not, which is why "compose from the command's output" is
     unenforceable on its own.
   - **Uncommitted work** — untracked and modified files in every listed repo,
     plus any stash entries, one line each: path + one clause on what it holds.
     A fresh session cannot see these from git history. Include scratch files,
     saved transcripts, and local-only notes; these often contain the newest
     information in the whole workstream, because they were written after the
     last commit.

     The session scratchpad is a special case: it does not survive the
     session. Anything there the next agent needs must be copied into a
     listed repo path or inlined into this document — pointing at a
     scratchpad path hands over a file that will not exist.
   - **Relevant KB / memory** — specific paths or topics in shared knowledge
     (project memory files, docs, prior decisions) the receiving agent needs
     loaded. Point at them by identifier; do not restate their content here —
     the receiving agent will read them directly. Apply the same **Pointer
     discipline** rules: a KB entry is the single easiest thing to get wrong,
     because repo-shaped paths and cloud-drive documents look identical once
     written down as text.

     **A client-scoped pointer cannot cross clients — inline it instead.**
     Claude Desktop Project instructions, a Claude Project's system-level doc,
     and per-client persistent memory live in a namespace the receiving
     session may not have. Claude Code, Claude Desktop, and claude.ai each
     have their own. Pointing at one from a handoff that a different client
     reads names something unreachable, and the content is then lost with no
     error — the pointer looks fine and resolves to nothing. If a fact lives
     only in a client-scoped store, copy the fact into this document. This is
     the one case where restating content is correct; "read my memory for the
     locked principles" is not a pointer the next agent can follow.
   - **Issue tracker** — if the project uses a tracker for this kind of work,
     the open items for this workstream, by number and one-line title, plus
     the query that lists them. Where the project's `CLAUDE.md` requires
     checking a tracker before starting work in an area, hand over that
     query's result rather than making the next agent rediscover it. Omit the
     section entirely if the project has no such tracker.
   - **Decisions locked** — bullet list of every settled decision still in
     force, regardless of which prior stint it was made in. Each handoff
     writes a fresh document, so this section must be cumulative, not scoped
     to the current session — omit only decisions that have since been
     reconsidered and reversed. Stated as facts ("using X because Y"), not as
     a log of the discussion that produced them.
   - **Open questions** — unresolved items, each specific enough to act on
     without more context
   - **Next step** — the single concrete next action

   **No section may be omitted or folded into another one.** **Remote / PR
   state**, **Uncommitted work**, and **Issue tracker** are the three that
   cannot be written without running commands, which makes them the three
   that get dropped when the commands were not run — and dropping them is
   exactly the signal the reader needs. If a section has nothing in it, write
   the heading with "none"; if its commands failed, write the heading with the
   error or with `UNVERIFIED:` lines. Never nothing.

   The receiving skill treats the absence of any of those three as evidence
   that the entire export is unverified, and downgrades every mutable claim in
   it accordingly. Omitting one to save space therefore discredits the whole
   document rather than shortening it. (**Issue tracker** is the single
   exception, and only when the project has no tracker at all.)

   Before writing, re-read the composed sections against each other. A path,
   branch, or identifier stated in two sections must read identically in both.
   Diff them literally rather than checking that they feel consistent:
   `modules/git_pkgs_proxy/` in one section and `terraform/git_pkgs_proxy/` in
   another is two different claims, only one of which resolves. The same goes
   for dates — a due date given as one value in **Task** and another in
   **Open questions** must be reconciled in both places, not flagged in one
   and left contradictory in the other.
   **Decisions locked** is the usual offender: a decision recorded weeks ago
   ("the module lives at X") outlives the layout it described, while **Files
   in scope** gets refreshed from the live tree. When the two disagree, the
   live tree wins — fix the decision entry rather than leaving a document that
   contradicts itself, and say in one clause that the location changed.

4. **Pointer discipline: verify every pointer before writing it.**

   This is the section most likely to be skipped and the one that causes the
   most damage. A stale pointer is worse than an absent one: the receiving
   agent spends real tokens chasing a path that cannot resolve, and a pointer
   that resolves to the *wrong* thing sends it confidently down a dead end.
   An unverified manifest is a set of claims about state, not state.

   **Probe for the tools first; do not assume you have them.** Most clients
   running this skill have shell access (Claude Code has Bash; Claude Desktop
   has Desktop Commander), but some do not, and a client whose only view of
   the work is the conversation will otherwise compose a whole document of
   confident recollection. Check, once:

   ```bash
   git --version && gh auth status
   ```

   - Both succeed → every pointer below is verifiable, so there is no excuse
     for an unchecked one. Do not write a pointer you have not resolved in
     this session.
   - Either fails → say so in **Timestamp**, in one clause, and prefix
     **every** mutable claim in the document with `UNVERIFIED:`. A handoff
     that cannot see the tree is still worth writing; one that hides that it
     could not see the tree is not.

   **Run this block before composing, once per repo in scope, and compose
   from its output — not from memory and not from a previous handoff.** This
   is not optional and not a suggestion to "confirm somehow": an instruction
   to verify that names no command gets skipped under time pressure, which is
   how a stale pointer ships.

   ```bash
   R=<absolute repo path>
   git -C "$R" branch --show-current          # → the branch line, verbatim
   git -C "$R" log --oneline -1               # → HEAD commit subject
   git -C "$R" status -sb                     # → ahead/behind vs upstream
   git -C "$R" status --porcelain             # → Uncommitted work section
   git -C "$R" stash list                     # → also Uncommitted work
   git -C "$R" log --oneline origin/HEAD..HEAD # → what this branch actually did

   # Remote / PR state — a merged or open PR invalidates "not yet done"
   gh pr list --repo <owner/repo> --head "$(git -C "$R" branch --show-current)" \
     --state all --json number,title,state,isDraft
   gh pr checks <pr-number> --repo <owner/repo>

   # Re-check every PR/issue number you are about to write down. Their state
   # changed since you last looked; that is what mutable state does.
   gh pr view <n> --repo <owner/repo> --json number,state,isDraft,mergedAt

   # Issue tracker section
   gh issue list --repo <tracker> --state open --label <area>
   ```

   **Every identifier you describe as pending must be grepped in the live
   tree, and the grep must be non-empty.**

   ```bash
   grep -rn '<identifier-claimed-pending>' "$R" --include='*.tf'   # adjust filter
   ```

   An empty result is never nothing — it is a finding. It means the work is
   already done, or it lives somewhere other than where you were about to say
   it lives. Resolve which, and write that instead. Do not write "not yet
   renamed," "still needs X," or "pending" about any string you did not just
   find.

   For each entry in **Files in scope** and **Relevant KB / memory**:

   - **Resolve local paths.** Confirm the file or directory exists. If it does
     not, either correct it to the real location or drop it. Never carry a
     path forward from a previous handoff on the assumption it still resolves.
   - **Label the storage location on every entry, individually.** A
     repo-shaped path like `knowledge-base/topics/foo/status.md` implies a git
     repo; if the document actually lives in Google Drive, say so and give the
     Drive title or file id. These are indistinguishable once written as plain
     text, and the receiving agent will search the filesystem, find nothing,
     and report the file missing when it exists elsewhere.

     Prefix each entry with `[local]`, `[repo:<name>]`, or `[drive]`. A label
     on the section heading does **not** count: a heading that says "(Google
     Drive)" over entries written as `knowledge-base/topics/...` reads as a
     repo path on every single line, and the heading loses to the path every
     time. One prefix per line, no exceptions, even when every entry in the
     block shares a location.
   - **Name the branch and check it out.** For each repo, record the current
     branch and its HEAD commit subject. Verify with
     `git -C <path> branch --show-current` and `git -C <path> log --oneline -1`.
     Do this for **every** repo in scope, separately — a multi-repo workspace
     has no single "current branch," so one branch line for the whole document
     is always wrong when more than one repo is listed.
   - **Confirm identifiers exist where you claim they do.** If an entry says a
     string appears in a file or module (an identifier awaiting a rename, a
     config key), grep for it and confirm. If the grep comes back empty, that
     is a finding: either the work is already done or it lives somewhere else,
     and the next agent must be told which. Do not describe something as
     pending without checking that it is still pending.
   - **Do not call a merged change "live" on the strength of the merge.** A
     merge is a fact about history; "live and verified" is a claim about the
     current tree, and a revert between the two is invisible in the PR's own
     state — an incident-mode fix lands as an ordinary commit, so it does not
     say "revert" anywhere. Check the paths the PR touched for later commits,
     and check the tracker for follow-ups naming that PR, before describing
     any merged work as in effect.

   - **Never source a claim from your own prior artifact.** A note you wrote
     in an earlier session — a `HANDOFF-*.md`, a scratch plan, a previous
     handoff document — is exactly as stale as any other pointer, but it reads
     as authoritative because you wrote it. When such a file quotes a value
     (`default = "foo-poc"`), that is a claim about the tree as it was, not as
     it is. Re-read the tree. Where the two disagree, the tree wins and the
     artifact is the thing that needs correcting.
   - **Note uncommitted work.** Untracked or modified files in a listed repo
     belong in the manifest; a fresh session cannot see them from git history.
     Read them before summarizing them — a scratch file or saved transcript
     written after the last commit routinely holds the newest facts in the
     workstream, including resolutions to items you are about to record as
     open.

   If a pointer cannot be verified — no access, ambiguous location, a path you
   cannot find — write it with an explicit `UNVERIFIED:` prefix and one clause
   saying what you could not confirm. A flagged uncertainty is useful; a
   confident wrong path is not.

5. Create the new document with `create_file`:

   - `title`: from step 1
   - `parentId`: the folder id from step 2
   - `textContent`: the composed export
   - `contentMimeType`: `text/plain`
   - Leave conversion enabled (do **not** set
     `disableConversionToGoogleType`). Plain text converts to a Google Doc,
     which is what the read side needs — `read_file_content` does not support
     `text/plain`, so an unconverted upload would force the receiving agent
     into a base64 download.

   Write the export in Markdown. Verified 2026-09-11: headings, bullets, and
   backticked paths survive the conversion and stay readable, but
   `read_file_content` returns the syntax characters backslash-escaped
   (`\#`, `\-`, `` \` ``). Content is intact; do not rely on the markup
   parsing cleanly on the far side. Prefer clear section headings over nested
   formatting.

   The escaping is **not** confined to markup — it lands inside identifiers,
   which is why the read side has to strip it before use. Verified
   2026-09-11: a GraphQL node id written as `D_kwDOC5tEDM4AocXf` comes back as
   `D\_kwDOC5tEDM4AocXf` and fails with "Expected string or block string, but
   it was malformed" if pasted literally; `#3604` becomes `\#3604`, and every
   `snake_case` path (`snapshot_debian_timestamp`) gains backslashes. You
   cannot prevent this from the write side, so do not try to pre-escape or
   work around it. Write identifiers normally and rely on the receiving
   skill's strip step.

   Create the new document **before** retiring the old one. If creation
   fails, the previous handoff must still be the newest valid document.

6. Retire the previous handoff document for this workstream. Search:

   ```text
   title contains 'Claude Handoff - <workstream>' and mimeType = 'application/vnd.google-apps.document'
   ```

   `trash_file` every match other than the one just created. The same Google
   account owns every handoff document, so this is expected to succeed. If a
   trash call does fail, say so plainly and name the document left behind —
   do not report a clean handoff.

   A stale copy left behind degrades tidiness, not correctness: the receiving
   agent selects the newest document by `modifiedTime` regardless.

7. Confirm to the user in one line: the document title, and the folder it went
   to. Do not restate the export — they already saw it composed. If step 6
   left any document un-retired, state that in the same breath. If any pointer
   went out with an `UNVERIFIED:` prefix, name those too — the user is the
   only one who can resolve them before the next session inherits them.

## Constraints

- Never write credentials, API keys, or tokens into the handoff document.
- Do not add an author or account line. The document records *which
  workstream* it belongs to, not who wrote it.
- Do not describe work as pending without confirming it is still pending.
  Carrying a completed item forward as an open one is a live failure mode,
  and it has now recurred **with this rule already in force** — so treat the
  command block in step 4 as the rule, not this paragraph.
  - First occurrence: a handoff described an identifier as awaiting a rename
    when the rename branch already existed with commits, and the identifier
    was no longer in the module it named.
  - Second occurrence, nine minutes after this constraint was committed: the
    same workstream's handoff again recorded the rename as "Not yet executed"
    while the rename was committed, pushed, and sitting in an open PR with
    green CI; it also recorded four PR states as open that were merged or
    closed, and recorded an access grant as "still pending" when the grant
    had merged the day before. Two distinct mechanisms produced that: the
    rename claim was restated from the writer's own earlier
    `HANDOFF-*.md` note, which quoted a `default = "...-poc"` value that the
    tree no longer had; the PR and access-grant states were carried forward
    from recollection without a fresh `gh` lookup. Both need their own
    guard — re-read the tree instead of your notes, and re-query every
    number.

  The lesson is that "confirm it is still pending" is not actionable on its
  own: it names an outcome without naming a command, so it gets satisfied by
  re-reading whatever the writer already believed. Every claim of pendency
  needs a non-empty grep, and every PR or issue number needs a fresh `gh`
  lookup, in this session.
- Errors of this class are directionally dangerous, not randomly wrong: they
  all understate progress. The next agent then re-plans work that is done, or
  re-executes a destructive change whose PR is already open. When the live
  state and your recollection disagree about how far along something is,
  assume the work is further along than you remember and go verify.
- No narrative framing, no restating context the reader can get from the
  files/KB pointers themselves. If a fact is available by following a pointer,
  point to it instead of copying it in. The sole exception is a client-scoped
  store (memory, Project instructions) — inline those, per step 3.
- If the Drive connector is unavailable or the write fails, say so plainly and
  offer the export as plain text for the user to paste manually instead. Do
  not describe a handoff as saved unless a `create_file` call returned a
  document id.
