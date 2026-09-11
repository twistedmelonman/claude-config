---
name: prepare-handoff
description: Use when the user explicitly says "prepare handoff," "wrap up for handoff," or asks to save the current session's state so another session can resume the work. Writes a dense, structured export — not a prose summary — to a Google Drive document so a later session can resume with minimal re-derivation. Do not trigger on generic session-ending language like "thanks" or "bye."
version: 1.0.0
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

   - If it exists, use its `id` as `parentId` in step 4.
   - If it does not exist, create it (`mimeType:
     application/vnd.google-apps.folder`), then **tell the user plainly that
     the new folder is not shared with anyone**. Offer to share it if they
     supply an address. Never create the folder and report success without
     stating that it is unshared — a handoff nobody else can read looks
     identical to a working one until it fails.
   - Never share the folder without the user asking for it in this session.

3. Compose the export with exactly these sections:

   - **Timestamp** — current date and time
   - **Task** — what we're doing, stated as a concrete goal, not a narrative
     of how we got here
   - **Files in scope** — every file, repo, or path currently relevant to the
     task, whether touched in this stint or carried forward from an earlier
     one, one line each: path + one clause on its role. Include branch name if
     relevant. This is a manifest, not prose. Drop a file only once it's no
     longer relevant to the task, not just because this stint didn't touch it.
   - **Relevant KB / memory** — specific paths or topics in shared knowledge
     (project memory files, docs, prior decisions) the receiving agent needs
     loaded. Point at them by identifier; do not restate their content here —
     the receiving agent will read them directly.
   - **Decisions locked** — bullet list of every settled decision still in
     force, regardless of which prior stint it was made in. Each handoff
     writes a fresh document, so this section must be cumulative, not scoped
     to the current session — omit only decisions that have since been
     reconsidered and reversed. Stated as facts ("using X because Y"), not as
     a log of the discussion that produced them.
   - **Open questions** — unresolved items, each specific enough to act on
     without more context
   - **Next step** — the single concrete next action

4. Create the new document with `create_file`:

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

5. Retire the previous handoff document for this workstream. Search:

   ```text
   title contains 'Claude Handoff - <workstream>' and mimeType = 'application/vnd.google-apps.document'
   ```

   For every match other than the one just created, in order of preference:

   - `trash_file` it.
   - If that fails (a non-owner usually cannot trash a file they did not
     create), fall back to `update_file` to rename it
     `<existing title> (superseded <ISO timestamp>)`.
   - If both fail, say so plainly. Do not report a clean handoff.

   Retirement is best-effort by design. The receiving agent selects the newest
   document by `modifiedTime` regardless, so a stale copy left behind degrades
   tidiness, not correctness.

6. Confirm to the user in one line: the document title, and the folder it went
   to. Do not restate the export — they already saw it composed. If step 5
   left any document un-retired, state that in the same breath.

## Constraints

- Never write credentials, API keys, or tokens into the handoff document.
- Do not add an author or account line. The document records *which
  workstream* it belongs to, not who wrote it.
- No narrative framing, no restating context the reader can get from the
  files/KB pointers themselves. If a fact is available by following a pointer,
  point to it instead of copying it in.
- If the Drive connector is unavailable or the write fails, say so plainly and
  offer the export as plain text for the user to paste manually instead. Do
  not describe a handoff as saved unless a `create_file` call returned a
  document id.
