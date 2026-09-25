# Code Review Standards — Andrew Rich

> **Note:** This is auxiliary documentation for `~/.claude/CLAUDE.md`
>
> **When to read:**
>
> - During Protocol 4 AI review iterations
> - When reviewing code (yours or others')
> - When using code-reviewer or adversarial-reviewer agents

---

## General Code Review Checklist

### Security

- [ ] No hardcoded credentials or API keys
- [ ] Input validation on user data
- [ ] No injection vulnerabilities (SQL, XSS, command injection)
- [ ] Proper authentication/authorization checks
- [ ] No sensitive data in logs or error messages
- [ ] Environment variables used for all secrets

### Correctness

- [ ] Logic handles edge cases
- [ ] Async/await used correctly (no missing awaits)
- [ ] Error handling with try-catch or equivalent
- [ ] No race conditions
- [ ] Resource cleanup (connections, listeners, timers, subscriptions)
- [ ] Graceful degradation on external service failures

### Quality

- [ ] Follows existing codebase patterns
- [ ] Self-documenting variable and function names
- [ ] No dead code (remove, don't comment out)
- [ ] DRY — no unnecessary duplication
- [ ] Appropriate level of abstraction
- [ ] **Diagnostic granularity**: distinct failure modes produce distinct error messages (missing dependency ≠ missing file ≠ parse error ≠ value mismatch). Don't let `|| true` or empty-default fallbacks collapse several failure modes into one misleading message. See §Recurring CI Findings → "Logged patterns" for the example-driven rule.
- [ ] **Comment minimalism**: comments are limited to what isn't obvious from the code. A comment that only restates what the code already says should be flagged and removed.

---

## Red Flags — Immediate Rejection

1. Hardcoded credentials or API keys
2. `console.log` or debug statements in production code
3. Commented-out code blocks
4. TODO without GitHub issue reference
5. Disabled linting/type checking rules without justification
6. Missing error handling on async operations
7. Unsanitized user input
8. Synchronous blocking operations in async contexts
9. Tests removed or disabled
10. Coverage decreased without explicit justification

---

## Anti-Patterns to Avoid

- **Over-engineering**: Don't add abstraction until needed (need 3 real examples)
- **Premature optimization**: Profile before optimizing
- **Shotgun surgery**: Changes should be cohesive, not scattered
- **God objects**: Keep components/functions focused
- **Magic numbers**: Use named constants
- **Deep nesting**: Refactor deeply nested conditionals (early returns)
- **Tight coupling**: Components should be loosely coupled
- **Ignoring errors**: Always handle error cases explicitly
- **Skipping review**: Never bypass Protocol 4

---

## When Reviews Find Issues — Rework, Don't Override

When a pre-commit hook or review agent flags an issue, the **strongly preferred** response is to go back and rework the code until it passes cleanly. Do not ask the human to bypass hooks with `--no-verify` or similar overrides.

**Escalation ladder:**

1. **Rework the code** — Fix the flagged issue directly. This is the expected outcome ~90% of the time.
2. **Rework differently** — If the first fix introduced new issues, try a different approach to the original change.
3. **Narrow the commit** — Split the change so the problematic part is isolated and the rest can land cleanly.
4. **After 3+ genuine rework attempts**, if the review agent is flagging something you believe is a false positive or an irreconcilable style disagreement, _then_ explain the situation to the human and ask whether they'd like to override. Present the specific findings and why you believe they're incorrect.

**Never** jump straight to requesting `--no-verify`. The human should only need to override hooks in rare, genuinely exceptional cases — not as a routine escape hatch for review friction.

---

## Recurring CI Findings Signal Local Review Gaps

Local review (pre-commit code-reviewer + adversarial-reviewer, pre-push codebase-reviewer) exists to catch issues **before** push. Every finding that slips to CI costs real time and money; local verification is free.

**The rule:** If CI consistently returns findings local review missed, treat it as a local-review failure — not as CI "catching extra stuff."

**Feedback loop:** When a CI finding lands that local review should have caught, note the category. After 2–3 repeats of the same category, update local reviewer prompts, pre-commit hooks, or this file's checklists so the class of issue is caught locally.

**Not normal workflow:** `post-push-loop` iterations are a safety net, not the primary review mechanism. A PR needing 3+ loop iterations means local review needs improvement.

### Logged patterns

These classes of finding have recurred enough that local review must catch them before push.

**Error-path diagnostic granularity** (logged 2026-04-16 after PR #15, scripts repo, took 5 push cycles)

Every distinct failure mode in a script must produce a distinct, actionable error message. Fallbacks like `$(cmd || true)` or `jq '.x // empty'` merge "dependency missing", "file missing", "parse failed", and "value wrong" into one generic message, forcing the operator to guess which one actually happened.

Checks to apply during pre-commit review of any script:

1. For every `[[ -z "${var}" ]]` check: is there a distinct branch for each way `var` could end up empty (command missing, command ran but no data, data exists but is empty)?
2. For every `cmd || true` / `cmd || :` / `jq '.x // empty'`: is a genuine parse/tool failure swallowed and redirected into a downstream check that names something else?
3. For every external tool invocation (`jq`, `awk`, `curl`, `gh`, ...) used beyond a single one-liner: is there a `command -v <tool>` preflight with a `brew install <tool>` hint?
4. For every file read (`cat`, `jq <file>`, `source <file>`): is there a `[[ -f "${file}" ]]` preflight with a remediation message before the parser runs?

If any of these are missing, flag as BLOCKING in local review — not as a non-blocking observation. The CI reviewer has repeatedly treated these as non-blocking, then flagged the next one after the first was fixed. Treating them as blocking locally breaks that cycle.

---

## Reviewer Convergence

Three mechanisms keep local pre-commit review from looping without making
progress (dev-env#35):

1. **File-header context**: code-reviewer's prompt includes each changed
   file's leading comment block, not just the diff hunk — so a stated
   scope ("macOS-only, not intended for Linux/CI") is visible even when
   that line isn't part of the diff.
2. **Round memory**: up to the last 2 FAILed rounds on the same
   branch+file-set are carried forward into the next retry's prompt as
   PRIOR ROUND FEEDBACK, so code-reviewer doesn't re-flag an
   already-addressed issue with a new remedy each time.
3. **Arbitration**: when code-reviewer's BLOCKING FAIL disagrees with a
   clean adversarial-reviewer PASS, a third arbiter call (Sonnet) decides
   which is correct instead of code-reviewer's verdict winning by default.
   Every arbitration — whatever the verdict — appends a full verbatim
   record of all three reviewers to `.git/reviewer-disagreements.log` in
   the repo being reviewed. **Nothing is filed as a GitHub issue.**

   Arbitrations used to file into `smartwatermelon/claude-config` on an
   arbiter FAIL. That was removed in claude-config#418: across five real
   filings, not one produced work in this repo — an arbiter FAIL turned out
   to mean "the reviewers disagreed and one was right", not "the tooling
   needs attention", and four of the five were about other repos entirely.

If review still fails to converge after these mechanisms are in place,
that is itself worth a fresh issue. Read
`.git/reviewer-disagreements.log` first — it holds every arbitration for
this repo, including the reviewers' verbatim output, which no issue ever
carried.

---

## Version-Pin Unfamiliarity Is Not a Blocking Finding

A reviewer model's training data has a cutoff. A manifest pin (any file, any
ecosystem) for a tool/package version released after that cutoff reads to the
reviewer as "this version doesn't exist" or "I don't recognize this" — a false
BLOCKING FAIL on code that was pinned deliberately and already tested (Protocol
3 requires tests pass before a diff reaches review, so "tests passed" is not
re-verified here — it's inherited).

**The rule:** `hooks/run-review.sh`'s `downgrade_version_unfamiliarity_findings`
rewrites a BLOCKING finding to WARNING when its text matches unfamiliarity
language ("does not exist," "no such version," "unfamiliar," "don't recognize")
and does **not** match known-bad language (CVE, vulnerability, deprecated,
yanked, breaking change, security advisory). A finding matching both is never
downgraded — a substantive security or compatibility claim always wins over an
unfamiliarity pattern. This is deliberately not ecosystem-aware (no
package.json-vs-go.mod special-casing) and does not query any package registry;
when the pinned tool has a local binary on PATH, its `--version` output is
logged alongside the downgrade as corroborating evidence, but a missing local
binary does not block the downgrade.

A block is classified as a whole, from its `ISSUE:` line to the next one, so
`DETAILS:` text counts toward the finding it belongs to. When a downgrade
leaves no `SEVERITY: BLOCKING` anywhere in the output, the leading `VERDICT:`
line is promoted `FAIL`/`REVISE` → `PASS` as well; `parse_verdict` reads only
the `VERDICT:` line, so relabeling severities without that step would still
block the commit. A finding that survives alongside the version pin — an
unrelated blocking bug — keeps the verdict at FAIL.

Downgraded findings stay visible — logged to `REVIEW_LOG` and relabeled
`SEVERITY: WARNING` in the reviewer output, never deleted — same visibility
standard as reviewer-disagreement arbitration above.

Applies to the pre-commit review path only (whole-diff and chunked per-file);
full-diff and codebase pre-push modes are unaffected, since a version pin is a
per-file manifest fact, not a cross-file integration concern.

---

## A Claim the Reviewer Cannot Check Does Not Block

The commit and full-diff reviewers run with `--tools ""`. They cannot read a
file outside the diff, and they cannot read a vendor's documentation. Two
kinds of BLOCKING finding therefore state something the reviewer had no way to
check. Both have blocked correct commits.

1. **External behavior** (claude-config#455, #555). An example is "Netlify
   does not support `%{submissionId}`". The variable is documented. Haiku
   blocked it 3 times in 3 runs, and once the arbiter upheld the block.
2. **A LOCATION outside the diff** (claude-config#488). One finding cited
   `tally.sh`. That file never existed in the repository.

**The rule:** `downgrade_unverifiable_findings` in `hooks/run-review.sh`
changes such a finding from BLOCKING to WARNING. It runs on both commit-time
reviewers before arbitration, and on the full-diff reviewer. It uses the same
promotion and sentinel rules as the version-pin downgrade above.

- The external-behavior check matches narrow wording: "undocumented", "does
  not support ... syntax", "will be sent literally", or "placeholder syntax
  is invalid". It does not fire when the finding also names a security or
  data-loss class, such as a hardcoded credential, an injection, `eval`,
  `rm -rf`, or a CVE.
- The location check fires only when LOCATION contains a path and none of
  its paths matches a file in the diff. The script reads the diff headers
  with any prefix style, so `diff.mnemonicPrefix` does not affect the match.
  An `unspecified` or empty LOCATION is never downgraded.
- Each downgrade adds a `downgraded:` line to `REVIEW_LOG`, so you can
  measure the rate.

The shared prompt rules make the same point first: a Kind B claim is never
BLOCKING. The script check is the backstop for when the model ignores that
rule.

The chunked commit path and codebase mode do not run this check. Codebase
mode has Read, Grep, and Glob, so it can open the files it cites.

**Developer intent at pre-push** (claude-config#489). The full-diff reviewer
now gets the commit messages for `origin/main..HEAD` (or `main..HEAD`) in its
prompt, labeled as context and not as proof. A tradeoff that the author
states and accepts is not reported again. A message never excuses a real
cross-file defect.

---

## Return to Main Documentation

→ Return to `~/.claude/CLAUDE.md`
