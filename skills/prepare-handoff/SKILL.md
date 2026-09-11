---
name: prepare-handoff
description: Use when the user explicitly says "prepare handoff," "wrap up for handoff," or asks to save the current session's state so another session can resume the work. Writes a dense, structured export — not a prose summary — to a Google Drive document so a later session can resume with minimal re-derivation. Verifies every path, branch, and identifier it records before writing, so the next session does not inherit stale pointers. Do not trigger on generic session-ending language like "thanks" or "bye."
version: 1.1.0
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
   - **Relevant KB / memory** — specific paths or topics in shared knowledge
     (project memory files, docs, prior decisions) the receiving agent needs
     loaded. Point at them by identifier; do not restate their content here —
     the receiving agent will read them directly. Apply the same **Pointer
     discipline** rules: a KB entry is the single easiest thing to get wrong,
     because repo-shaped paths and cloud-drive documents look identical once
     written down as text.
   - **Decisions locked** — bullet list of every settled decision still in
     force, regardless of which prior stint it was made in. Each handoff
     writes a fresh document, so this section must be cumulative, not scoped
     to the current session — omit only decisions that have since been
     reconsidered and reversed. Stated as facts ("using X because Y"), not as
     a log of the discussion that produced them.
   - **Open questions** — unresolved items, each specific enough to act on
     without more context
   - **Next step** — the single concrete next action

   Before writing, re-read the composed sections against each other. A path,
   branch, or identifier stated in two sections must read identically in both.
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

   Every environment running this skill has filesystem and shell access
   (Claude Code has Bash; Claude Desktop has Desktop Commander and Bash), so
   there is no excuse for an unchecked path. Do not write a pointer you have
   not resolved in this session.

   For each entry in **Files in scope** and **Relevant KB / memory**:

   - **Resolve local paths.** Confirm the file or directory exists. If it does
     not, either correct it to the real location or drop it. Never carry a
     path forward from a previous handoff on the assumption it still resolves.
   - **Label the storage location.** A repo-shaped path like
     `knowledge-base/topics/foo/status.md` implies a git repo; if the document
     actually lives in Google Drive, say so and give the Drive title or file
     id. These are indistinguishable once written as plain text, and the
     receiving agent will search the filesystem, find nothing, and report the
     file missing when it exists elsewhere. Prefix each entry with its
     location — `[local]`, `[repo:<name>]`, `[drive]` — or state it in the
     entry's descriptive clause.
   - **Name the branch and check it out.** For each repo, record the current
     branch and its HEAD commit subject. Verify with
     `git -C <path> branch --show-current` and `git -C <path> log --oneline -1`.
   - **Confirm identifiers exist where you claim they do.** If an entry says a
     string appears in a file or module (an identifier awaiting a rename, a
     config key), grep for it and confirm. If the grep comes back empty, that
     is a finding: either the work is already done or it lives somewhere else,
     and the next agent must be told which. Do not describe something as
     pending without checking that it is still pending.
   - **Note uncommitted work.** Untracked or modified files in a listed repo
     belong in the manifest; a fresh session cannot see them from git history.

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
  Carrying a completed item forward as an open one is a live failure mode:
  the first real handoff written by this skill described an identifier as
  awaiting a rename when the rename branch already existed with commits, and
  the identifier was no longer in the module it named.
- No narrative framing, no restating context the reader can get from the
  files/KB pointers themselves. If a fact is available by following a pointer,
  point to it instead of copying it in.
- If the Drive connector is unavailable or the write fails, say so plainly and
  offer the export as plain text for the user to paste manually instead. Do
  not describe a handoff as saved unless a `create_file` call returned a
  document id.
