---
name: receive-handoff
description: Use when the user explicitly says "receive handoff," "pick up where I left off," or starts a session continuing work saved by an earlier session. Reads the Google Drive handoff export and loads the files and KB entries it points to, so this session starts with working context rather than a description of context. Typically the first message of a session.
version: 1.0.0
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

1. Identify the workstream. If the user already named one, use it. Otherwise
   ask once: "Which handoff doc — name or workstream?"

2. Find the document. Search by title, not by a remembered file id:

   ```text
   title contains 'Claude Handoff - <workstream>' and mimeType = 'application/vnd.google-apps.document'
   ```

   **Select the match with the newest `modifiedTime`.** This rule is load-
   bearing. `prepare-handoff` writes a new document per handoff and retires
   the old ones on a best-effort basis, so more than one match is an expected
   state, not an error.

   - If more than one match survives, read the newest and **report the others
     to the user as stale copies** — including any whose title ends in
     `(superseded ...)`. Do not merge them.
   - Do not read a document whose title marks it superseded unless it is the
     only match, in which case say so before using it.

3. Read the document with `read_file_content`.

   Expect the Markdown syntax to come back backslash-escaped (`\#`, `\-`,
   `` \` ``) — an artifact of the plain-text-to-Doc conversion, verified
   2026-09-11. The content is intact. Read through the escaping; do not treat
   it as corruption and do not report the document as malformed because of it.

4. Follow the pointers, not just the labels:

   - For each entry under **Relevant KB / memory**, read that specific file or
     memory path directly rather than proceeding on the label alone.
   - For **Files in scope**, open the files needed to act on the stated
     **Next step**. Don't open every listed file speculatively if only one or
     two are relevant to the immediate next action — open the rest on demand
     as the session requires them.
   - Verify the branch named in the export is the current branch before
     acting on anything in it. If it differs, report the mismatch rather than
     switching.

5. Present back to the user, in compact form: task, next step, and anything
   that looks stale, contradictory, or missing. Report specifically:

   - referenced files or KB paths that no longer exist
   - a decision in the export that conflicts with something just read in the
     KB or the code
   - extra handoff documents found in step 2
   - a branch mismatch from step 4

   Then wait for the user's next message before acting.

## Constraints

- Treat the export as context, not as a task list to execute unprompted. The
  **Next step** line is information about what was intended, not permission to
  do it.
- If the document does not exist, say so plainly and ask whether to start a
  new one. Do not guess at prior content.
- If the Drive connector is unavailable, the read fails, or a referenced
  file/KB path can't be found, say so plainly instead of proceeding as if it
  resolved. A partially loaded handoff reported as complete is worse than a
  failed one.
