---
name: prepare-handoff
description: Use when the user explicitly says "prepare handoff," "wrap up for handoff," or asks to save the current session's state for a handoff to another Claude account. Writes a dense, structured export — not a prose summary — to a shared Google Drive document so a different account can resume work with minimal re-derivation. Do not trigger on generic session-ending language like "thanks" or "bye."
---

# Prepare Handoff

## When to use

Trigger only on an explicit handoff request. Do not infer intent to end a session from tone or politeness language.

## Governing principle

The receiving agent burns tokens every time it has to guess what something means. Optimize for zero re-derivation, not for brevity. Density beats compression: a file path costs fewer tokens to write than the paragraph explaining what's in it, and it's unambiguous. No word cap on this document — cap is on ambiguity, not length.

Write for a reader with no memory of this session and no ability to ask a follow-up. Resolve every pronoun and vague referent ("it," "that approach," "the fix") into the specific thing it refers to.

This document is overwritten on every handoff and no prior version is kept. Every section must therefore reflect the full current state of the task — everything still true, from this stint or any earlier one — not just what changed since the last handoff. If in doubt whether something belongs, ask: would dropping this leave the next agent unable to reconstruct it from anywhere else? If yes, include it.

## What to do

1. Identify the target document. If the user already named a workstream this session, use it. Otherwise ask once: "Which handoff doc — name or workstream?" Default naming convention: `Claude Handoff - <workstream>.gdoc`, stored in a Drive folder named `Claude Handoff`.
2. Compose the export with exactly these sections:
   - **Timestamp** — current date and time
   - **Task** — what we're doing, stated as a concrete goal, not a narrative of how we got here
   - **Files in scope** — every file, repo, or path currently relevant to the task, whether touched in this stint or carried forward from an earlier one, one line each: path + one clause on its role. Include branch name if relevant. This is a manifest, not prose. Drop a file only once it's no longer relevant to the task, not just because this stint didn't touch it.
   - **Relevant KB / memory** — specific paths or topics in shared knowledge (project memory files, docs, prior decisions) the receiving agent needs loaded. Point at them by identifier; do not restate their content here — the receiving agent will read them directly.
   - **Decisions locked** — bullet list of every settled decision still in force, regardless of which prior stint it was made in. This document is overwritten each handoff with no history kept, so this section must be cumulative, not scoped to the current session — omit only decisions that have since been reconsidered and reversed. Stated as facts ("using X because Y"), not as a log of the discussion that produced them.
   - **Open questions** — unresolved items, each specific enough to act on without more context
   - **Next step** — the single concrete next action
3. Search Drive for the target document by name.
   - If it exists, replace its full content with the new export. Do not append — this holds current state, not history.
   - If it does not exist, create it in the `Claude Handoff` folder.
4. Confirm to the user in one line what was written and where. Do not restate the export — they already saw it composed.

## Constraints

- Never write credentials, API keys, tokens, or account identifiers into the handoff document.
- No narrative framing, no restating context the reader can get from the files/KB pointers themselves. If a fact is available by following a pointer, point to it instead of copying it in.
- If the Drive connector is unavailable or the write fails, say so plainly and offer the export as plain text for the user to paste manually instead.
