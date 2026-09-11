---
name: receive-handoff
description: Use when the user explicitly says "receive handoff," "pick up where I left off," or starts a session continuing work from another Claude account. Reads the shared Google Drive handoff export and loads the files and KB entries it points to, so this session starts with working context rather than a description of context. Typically the first message of a session.
---

# Receive Handoff

## When to use

Trigger only on an explicit handoff request, ideally as the first message in a new session.

## What to do

1. Identify the target document. If the user already named a workstream, use it. Otherwise ask once: "Which handoff doc — name or workstream?" Default naming convention: `Claude Handoff - <workstream>.gdoc`, stored in a Drive folder named `Claude Handoff`.
2. Read the document via the Drive connector.
3. Follow the pointers, not just the labels:
   - For each entry under **Relevant KB / memory**, read that specific file or memory path directly rather than proceeding on the label alone.
   - For **Files in scope**, open the files needed to act on the stated **Next step**. Don't open every listed file speculatively if only one or two are relevant to the immediate next action — open the rest on demand as the session requires them.
4. Present back to the user, in compact form: task, next step, and anything from the doc that looks stale, contradictory, or missing (e.g. a referenced file that no longer exists, a decision that conflicts with something just read in the KB). Then wait for the user's next message before acting.

## Constraints

- Treat the export as context, not as a task list to execute unprompted.
- If the document does not exist, say so plainly and ask whether to start a new one. Do not guess at prior content.
- If the Drive connector is unavailable, the read fails, or a referenced file/KB path can't be found, say so plainly instead of proceeding as if it resolved.
