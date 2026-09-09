# Review-Convergence Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three root causes behind `run-review.sh`'s local pre-commit hook failing to converge on repeated commit attempts (dev-env#35): the code-reviewer prompt is diff-only with no file-scope context, there is no memory of what a prior FAILed round already flagged, and code-reviewer's BLOCKING verdict overrides a clean adversarial-reviewer pass with no reconciliation step.

**Architecture:** All three fixes live in `hooks/run-review.sh` (commit mode only — chunked/full-diff/codebase modes are out of scope for this plan) plus a new helper library `hooks/lib-review-context.sh` for the file-header-context and round-memory logic, kept separate from `lib-review-issues.sh` (which is scoped to issue-filing, not review-context assembly). Each fix is independently testable and independently revertable via existing `git config review.*` knobs.

**Tech Stack:** Bash (existing hook infrastructure), `git show`/`git diff --cached` for context extraction, existing `invoke_agent` / mock-CLI test harness in `hooks/tests/run-review-test.sh`.

## Global Constraints

- Every new/changed function must have `hooks/tests/run-review-test.sh` coverage using the existing `make_mock_claude` / `make_mock_claude_by_agent` mock patterns — no new mock infrastructure unless a fix genuinely needs 3-way agent differentiation (Fix 3 does; extend the mock rather than replace it).
- All new behavior must be reachable through existing `git config review.*` knobs so it can be disabled without a code change if it misbehaves in production. Follow the existing `git config --get --type=<type> review.<name> 2>/dev/null || echo "<default>"` pattern (see `run-review.sh:62-67`).
- `set -euo pipefail` discipline: every new command substitution that can legitimately return empty/nonzero must be guarded with `|| true` or an explicit check, matching the rest of the file (see the `_read_commit_message` guards at `run-review.sh:349-354` for the canonical pattern).
- No new external tool dependencies — only tools already used in this file (`git`, `shasum`, `awk`, `grep`, `sed`, `timeout`).
- This plan touches **commit mode only**. `full-diff` and `codebase` modes already get Sonnet-only single-reviewer treatment and are not subject to the Haiku/Sonnet disagreement this plan addresses.
- Filing convention for Fix 3's disagreement-log issues: target repo is **hardcoded to `smartwatermelon/claude-config`** (the reviewer infrastructure's own repo), never `REPO_OWNER`/`REPO_NAME` (which is the repo under review, e.g. `dev-env`) — these must not be confused.

---

## Current State Reference

`hooks/run-review.sh` commit-mode flow (as of commit `067c6d0`):

- `AGENT_PROMPT` is built at line 1138, embedding only `${DIFF}` (the `git diff --cached` output) — no file context beyond what's in the diff hunk itself.
- `CODE_REVIEWER_CACHE="${CACHE_DIR}/code-reviewer-${DIFF_HASH}"` (line 1118) only ever stores a `PASS` verdict (see `invoke_agent`, line 227-299, specifically lines 292-298) — a FAIL round leaves no trace once the diff changes on the next attempt (which it always does, since the developer edits the code to try to fix it).
- Verdict evaluation at lines 1284-1311: `CODE_REVIEWER_VERDICT == FAIL` + `SEVERITY: BLOCKING` → `exit 1` immediately (line 1288), with **no check of `ADVERSARIAL_VERDICT` first**. The adversarial output is only consulted afterward, and only to *add* a block (line 1301-1307), never to override a code-reviewer block.
- `CACHE_DIR="${GIT_DIR_PATH}/claude-review-cache"` (line 718) — per-repo, git-dir-scoped, already exists and is cleaned of entries older than 30 days (line 722).

---

## Task 1: File-header context injection (Fix 1)

**Files:**

- Create: `hooks/lib-review-context.sh`
- Modify: `hooks/run-review.sh:1121-1167` (commit-mode `AGENT_PROMPT` builder)
- Test: `hooks/tests/run-review-test.sh` (new Test 24)

**Interfaces:**

- Produces: `extract_file_header_context <file>` — reads the given file's leading comment block (from the **working tree**, since pre-commit diffs are against the staged index and the file exists on disk at review time) and echoes up to the first 15 non-blank comment lines, stopping at the first line that is neither blank nor a comment (`^\s*#`). Echoes nothing if the file doesn't exist or has no leading comment block. Second parameter (optional) caps the number of lines extracted, default 15.
- Consumes (from `run-review.sh`): `CHANGED_FILES` (already computed at line 836, currently only populated when `REVIEW_MODE == commit`), `DIFF`.

- [ ] **Step 1: Write `hooks/lib-review-context.sh` with `extract_file_header_context`**

```bash
#!/usr/bin/env bash
# =========================================================
# lib-review-context.sh — Shared review-prompt context helpers
# =========================================================
#
# Extracted from run-review.sh so file-scope-context extraction and
# round-over-round feedback tracking can be unit tested independently
# of the full hook script.
#
# SOURCE GUARD:
#   Safe to source multiple times; second source is a no-op.
#
# USAGE:
#   source ~/.claude/hooks/lib-review-context.sh
#   extract_file_header_context "path/to/file.sh"
#
# =========================================================

[[ -n "${_LIB_REVIEW_CONTEXT_LOADED:-}" ]] && return 0
_LIB_REVIEW_CONTEXT_LOADED=1

# Reads a file's leading comment block (shebang line excluded) so review
# prompts can see stated scope/intent (e.g. "macOS-only, not intended for
# Linux/CI") that may not appear in the diff hunk itself. Reads from the
# working tree, not git blob — pre-commit review runs against files that
# already exist on disk with the staged changes applied to the index but
# also present as regular files (this is always true for a normal `git
# commit` invocation; the hook never runs against a bare/detached tree).
#
# Args: $1 = file path (relative to repo root or absolute)
#       $2 = max lines to extract (default 15)
# Echoes: the leading comment block, one line per output line, with the
#         leading '#' and exactly one following space stripped. Empty
#         output (no lines) if the file doesn't exist, is not readable,
#         or has no leading comment block.
extract_file_header_context() {
  local file="$1"
  local max_lines="${2:-15}"

  [[ -r "${file}" ]] || return 0

  awk -v max="${max_lines}" '
    NR == 1 && /^#!/ { next }               # skip shebang
    /^[[:space:]]*$/ { next }               # skip blank lines while still in header
    /^[[:space:]]*#/ {
      count++
      if (count > max) exit
      line = $0
      sub(/^[[:space:]]*#[[:space:]]?/, "", line)
      print line
      next
    }
    { exit }                                 # first non-comment, non-blank line ends header
  ' "${file}" 2>/dev/null || true
}
```

- [ ] **Step 2: Write the failing test in `hooks/tests/run-review-test.sh`**

Add near the end of the file, after the existing Test 23 block (before the final summary/exit section):

```bash
# =========================================================
# TEST 24: extract_file_header_context surfaces stated scope
# (dev-env#35 — code-reviewer flagged Linux portability on a script whose
# header explicitly says "macOS-only, not intended for Linux/CI" because
# the diff-only prompt never showed that line)
# =========================================================
echo ""
echo "=== Test 24: file header context is extracted and injected into prompt ==="

setup_repo
cd "${REPO_DIR}"
cat >scoped.sh <<'SCRIPT'
#!/usr/bin/env bash
# macOS-only: uses BSD sed (`sed -i ''`). Operator script for this user's
# own machines, not intended for Linux/CI.
echo "hello"
SCRIPT
git add scoped.sh
cd - >/dev/null
stage_small_change

MOCK24_DIR="${TMPDIR_TEST}/mock24"
# Mock records the prompt it received so the test can assert on prompt content.
mkdir -p "${MOCK24_DIR}"
cat >"${MOCK24_DIR}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
cat >> "${MOCK24_DIR}/received_prompt.txt"
echo "VERDICT: PASS

No blocking issues found."
exit 0
EOF
chmod +x "${MOCK24_DIR}/claude"
rm -f "${MOCK24_DIR}/received_prompt.txt"

TEST24_LOG="${TMPDIR_TEST}/test24-review.log"
rm -f "${TEST24_LOG}"

cd "${REPO_DIR}"
REVIEW_LOG="${TEST24_LOG}" CLAUDE_CLI="${MOCK24_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

received="$(cat "${MOCK24_DIR}/received_prompt.txt" 2>/dev/null || echo "")"

assert_contains \
  "prompt includes the file's stated macOS-only scope (dev-env#35)" \
  "not intended for Linux/CI" \
  "${received}"
```

- [ ] **Step 3: Run the new test to verify it fails**

Run: `bash ~/Developer/claude-config/hooks/tests/run-review-test.sh 2>&1 | grep -A3 "Test 24"`
Expected: FAIL — "prompt includes the file's stated macOS-only scope" fails because nothing injects it yet.

- [ ] **Step 4: Wire `lib-review-context.sh` into `run-review.sh` and inject header context into the commit-mode prompt**

In `run-review.sh`, add the source line near the existing `lib-review-issues.sh` source (around line 178-180):

```bash
# --- Shared context-assembly library (file-header extraction, round memory) ---
# shellcheck source=lib-review-context.sh
source "${_LIB_DIR}/lib-review-context.sh"
```

Then modify the `AGENT_PROMPT` builder (around line 1121-1167) to compute and inject a `FILE HEADER CONTEXT` section before `COMMIT_MSG_SECTION`. `CHANGED_FILES` is already computed at line 836 for commit mode; reuse it directly (it's in scope by the time `AGENT_PROMPT` is built):

```bash
# File-header context: give the reviewer each changed file's stated scope
# (e.g. "macOS-only, not intended for Linux/CI") even when that line isn't
# part of the diff hunk itself. Diff-only prompts can't see this — dev-env#35.
FILE_CONTEXT_SECTION=""
if [[ -n "${CHANGED_FILES}" ]]; then
  while IFS= read -r _cf; do
    [[ -z "${_cf}" ]] && continue
    _cf_header=$(extract_file_header_context "${_cf}")
    [[ -n "${_cf_header}" ]] || continue
    FILE_CONTEXT_SECTION="${FILE_CONTEXT_SECTION}--- ${_cf} ---
${_cf_header}

"
  done <<<"${CHANGED_FILES}"
  if [[ -n "${FILE_CONTEXT_SECTION}" ]]; then
    FILE_CONTEXT_SECTION="FILE HEADER CONTEXT (stated scope/intent from each changed file's leading comments — weigh findings against this before flagging out-of-scope concerns):
${FILE_CONTEXT_SECTION}---

"
  fi
fi
unset _cf _cf_header
```

Then prepend `${FILE_CONTEXT_SECTION}` to `AGENT_PROMPT`, immediately before `${COMMIT_MSG_SECTION}`:

```bash
AGENT_PROMPT="${FILE_CONTEXT_SECTION}${COMMIT_MSG_SECTION}You are performing a pre-commit code review. ..."
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash ~/Developer/claude-config/hooks/tests/run-review-test.sh 2>&1 | grep -A3 "Test 24"`
Expected: PASS

- [ ] **Step 6: Run the full test suite to check for regressions**

Run: `bash ~/Developer/claude-config/hooks/tests/run-review-test.sh 2>&1 | tail -20`
Expected: all prior tests (1-23) still PASS; total FAIL count is 0.

- [ ] **Step 7: Commit**

```bash
cd ~/Developer/claude-config
git add hooks/lib-review-context.sh hooks/run-review.sh hooks/tests/run-review-test.sh
git commit -m "fix(review): inject changed-file header context into commit-mode prompt

code-reviewer's prompt was diff-only, so a stated scope comment like
'macOS-only, not intended for Linux/CI' was invisible unless that exact
line happened to fall inside the diff hunk. Extract each changed file's
leading comment block and prepend it to the prompt as FILE HEADER
CONTEXT, so scope-out-of-bounds findings can be weighed correctly.

Ref: smartwatermelon/dev-env#35"
```

---

## Task 2: Round-over-round feedback memory (Fix 2)

**Files:**

- Modify: `hooks/lib-review-context.sh` (add round-memory functions)
- Modify: `hooks/run-review.sh:1121-1230` (commit-mode prompt builder + post-verdict bookkeeping)
- Test: `hooks/tests/run-review-test.sh` (new Test 25)

**Interfaces:**

- Produces (in `lib-review-context.sh`):
  - `round_history_key` — echoes a stable key derived from `git symbolic-ref --short HEAD` (or `detached` if none) plus the sorted, newline-joined list of changed files (via `CHANGED_FILES`, passed as `$1`). Uses `shasum -a 256` for a filesystem-safe filename, matching the existing `DIFF_HASH`/`file_cache_key` pattern (`run-review.sh:548`, `730`).
  - `write_round_feedback <history_file> <round_output>` — appends `round_output` (the code-reviewer's raw FAIL output) to `history_file`, keeping only the **last 2** rounds (drop the oldest when a 3rd is appended). Uses a `---ROUND---` separator, symmetric with `lib-review-issues.sh`'s `---ISSUE---` separator convention.
  - `read_round_feedback <history_file>` — echoes the file's contents verbatim (empty string if missing), for direct interpolation into a prompt section.
  - `clear_round_feedback <history_file>` — removes the file. Called on a PASS so a future unrelated failure on the same branch+files doesn't inherit stale history.
- Consumes (from `run-review.sh`): `CACHE_DIR` (already computed, line 718), `CHANGED_FILES`, `CODE_REVIEWER_OUTPUT`, `CODE_REVIEWER_VERDICT`.

- [ ] **Step 1: Write the failing test in `hooks/tests/run-review-test.sh`**

```bash
# =========================================================
# TEST 25: round-over-round feedback is injected on a retry after a FAIL
# (dev-env#35 — code-reviewer re-litigated already-addressed findings
# with a different remedy each round because each --no-session-persistence
# call started from zero)
# =========================================================
echo ""
echo "=== Test 25: prior-round FAIL feedback is injected into the retry prompt ==="

setup_repo
stage_small_change

MOCK25A_DIR="${TMPDIR_TEST}/mock25a"
make_mock_claude "${MOCK25A_DIR}" 0 "VERDICT: FAIL

ISSUE: Hardcoded path
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Use \$HOME instead of a literal path."

TEST25_LOG="${TMPDIR_TEST}/test25-review.log"
rm -f "${TEST25_LOG}"

cd "${REPO_DIR}"
REVIEW_LOG="${TEST25_LOG}" CLAUDE_CLI="${MOCK25A_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

# Second round: same branch, same changed file (foo.sh) — simulates a retry
# after an edit that didn't fully address round 1's finding. Mock records
# the prompt it receives.
MOCK25B_DIR="${TMPDIR_TEST}/mock25b"
mkdir -p "${MOCK25B_DIR}"
cat >"${MOCK25B_DIR}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
cat >> "${MOCK25B_DIR}/received_prompt.txt"
echo "VERDICT: PASS

No blocking issues found."
exit 0
EOF
chmod +x "${MOCK25B_DIR}/claude"
rm -f "${MOCK25B_DIR}/received_prompt.txt"

cd "${REPO_DIR}"
echo "echo round2edit" >>foo.sh
git add foo.sh
REVIEW_LOG="${TEST25_LOG}" CLAUDE_CLI="${MOCK25B_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

received25="$(cat "${MOCK25B_DIR}/received_prompt.txt" 2>/dev/null || echo "")"

assert_contains \
  "retry prompt includes round 1's BLOCKING finding (dev-env#35)" \
  "Hardcoded path" \
  "${received25}"
```

- [ ] **Step 2: Run the new test to verify it fails**

Run: `bash ~/Developer/claude-config/hooks/tests/run-review-test.sh 2>&1 | grep -A3 "Test 25"`
Expected: FAIL — nothing writes or reads round history yet.

- [ ] **Step 3: Add round-memory functions to `hooks/lib-review-context.sh`**

Append to the file:

```bash
# Derive a stable cache key for round-over-round feedback tracking. Diff
# hashes change on every retry (the developer edits the code), so DIFF_HASH
# can't key this — key on the more stable "which branch, which files are
# in flight" identity instead. Args: $1 = CHANGED_FILES (newline-separated).
round_history_key() {
  local changed_files="$1"
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached")
  printf '%s\n%s\n' "${branch}" "$(printf '%s\n' "${changed_files}" | sort)" \
    | shasum -a 256 2>/dev/null | awk '{print $1}' || echo "noround"
}

# Append a FAIL round's raw output to the history file, capped at the last
# 2 rounds (oldest dropped). Args: $1 = history file path, $2 = round output.
write_round_feedback() {
  local history_file="$1"
  local round_output="$2"

  local existing=""
  [[ -f "${history_file}" ]] && existing=$(cat "${history_file}")

  {
    if [[ -n "${existing}" ]]; then
      # Keep only the LAST round from what's already there (so appending
      # this one caps total retained rounds at 2).
      printf '%s' "${existing}" | awk -v RS='---ROUND---\n' 'END{if(NR>0) printf "%s", $0}'
      printf '\n---ROUND---\n'
    fi
    printf '%s\n' "${round_output}"
  } >"${history_file}.tmp" && mv "${history_file}.tmp" "${history_file}"
}

# Echo a history file's contents verbatim; empty string if missing.
read_round_feedback() {
  local history_file="$1"
  [[ -f "${history_file}" ]] && cat "${history_file}" || true
}

# Remove a round-history file (called on PASS to reset for future runs).
clear_round_feedback() {
  local history_file="$1"
  rm -f "${history_file}"
}
```

- [ ] **Step 4: Wire round-memory into `run-review.sh`'s commit-mode flow**

Compute the history file path alongside the existing cache-key block (near line 1117-1119):

```bash
ROUND_HISTORY_KEY=$(round_history_key "${CHANGED_FILES}")
ROUND_HISTORY_FILE="${CACHE_DIR}/round-history-${ROUND_HISTORY_KEY}"
```

Inject prior feedback into the prompt, alongside `FILE_CONTEXT_SECTION` (Task 1) — add this block right after computing `FILE_CONTEXT_SECTION` and before building `AGENT_PROMPT`:

```bash
PRIOR_ROUND_SECTION=""
_prior_feedback=$(read_round_feedback "${ROUND_HISTORY_FILE}")
if [[ -n "${_prior_feedback}" ]]; then
  PRIOR_ROUND_SECTION="PRIOR ROUND FEEDBACK (from up to 2 previous FAILed review attempts on this branch/file-set — do NOT re-flag an issue below unless it is still genuinely present in the current diff; do not propose a different remedy for something already addressed):
${_prior_feedback}
---

"
fi
unset _prior_feedback
```

And prepend it to `AGENT_PROMPT` (ahead of `FILE_CONTEXT_SECTION`):

```bash
AGENT_PROMPT="${PRIOR_ROUND_SECTION}${FILE_CONTEXT_SECTION}${COMMIT_MSG_SECTION}You are performing a pre-commit code review. ..."
```

After the verdict is determined (near line 1228-1241, right after `CODE_REVIEWER_VERDICT` is normalized), add the write/clear bookkeeping:

```bash
if [[ "${CODE_REVIEWER_VERDICT}" == "PASS" ]]; then
  clear_round_feedback "${ROUND_HISTORY_FILE}"
else
  write_round_feedback "${ROUND_HISTORY_FILE}" "${CODE_REVIEWER_OUTPUT}"
fi
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash ~/Developer/claude-config/hooks/tests/run-review-test.sh 2>&1 | grep -A3 "Test 25"`
Expected: PASS

- [ ] **Step 6: Run the full test suite to check for regressions**

Run: `bash ~/Developer/claude-config/hooks/tests/run-review-test.sh 2>&1 | tail -20`
Expected: all prior tests (1-24) still PASS; total FAIL count is 0.

- [ ] **Step 7: Commit**

```bash
cd ~/Developer/claude-config
git add hooks/lib-review-context.sh hooks/run-review.sh hooks/tests/run-review-test.sh
git commit -m "fix(review): carry FAIL feedback across retry rounds on the same branch

Each --no-session-persistence invocation started from zero, so a FAILed
round's findings were forgotten by the next retry — code-reviewer would
re-litigate already-addressed issues, sometimes with a different remedy
each time. Track up to the last 2 FAILed rounds per branch+changed-files
key under CACHE_DIR and inject them as PRIOR ROUND FEEDBACK so retries
build on prior findings instead of restarting the conversation.

Ref: smartwatermelon/dev-env#35"
```

---

## Task 3: Reconciliation arbiter + disagreement logging (Fix 3)

**Files:**

- Modify: `hooks/run-review.sh:1283-1311` (verdict evaluation) and the model-selection block (~line 101-129)
- Modify: `hooks/lib-review-issues.sh` is NOT touched — a separate, dedicated function is added directly in `run-review.sh` since the target repo (`smartwatermelon/claude-config`) is hardcoded and must never be confused with `REPO_OWNER`/`REPO_NAME` (the repo under review).
- Test: `hooks/tests/run-review-test.sh` (new Tests 26, 27)

**Interfaces:**

- Produces (in `run-review.sh`):
  - `ARBITER_MODEL` git-config knob, default `claude-sonnet-4-6` (same default as `ADVERSARIAL_MODEL`; override via `git config review.arbiterModel <model-id>`).
  - `file_reviewer_disagreement_issue <code_reviewer_output> <adversarial_output> <arbiter_output> <arbiter_verdict>` — files a GitHub issue against the **hardcoded** `smartwatermelon/claude-config` repo (not `REPO_OWNER`/`REPO_NAME`) via `gh issue create`, best-effort (`|| true`, never blocks the commit). Called unconditionally whenever the arbiter runs, regardless of which side it picks.
- Consumes: existing `invoke_agent`, `parse_verdict`, `DIFF`, `CODE_REVIEWER_OUTPUT`, `ADVERSARIAL_OUTPUT`.

- [ ] **Step 1: Write the failing test in `hooks/tests/run-review-test.sh`**

Extend `make_mock_claude_by_agent` to support a 3rd (arbiter) response, since the existing 2-way mock only distinguishes `*adversarial*` from everything else. Add a new mock helper rather than modifying the existing one (existing tests 12/13 depend on its current 2-way behavior):

```bash
# Like make_mock_claude_by_agent, but differentiates three agent identities
# by inspecting $2 (the --agent value): adversarial-reviewer, the arbiter
# agent name, and everything else (code-reviewer). Used for reconciliation
# tests where all three calls happen in the same run.
make_mock_claude_three_way() {
  local mock_dir="$1" cr_output="$2" ar_output="$3" arbiter_output="$4"
  mkdir -p "${mock_dir}"
  printf '%s\n' "${cr_output}" >"${mock_dir}/cr_output.txt"
  printf '%s\n' "${ar_output}" >"${mock_dir}/ar_output.txt"
  printf '%s\n' "${arbiter_output}" >"${mock_dir}/arbiter_output.txt"
  cat >"${mock_dir}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
if [[ "\$2" == *arbiter* ]]; then
  cat "${mock_dir}/arbiter_output.txt"
elif [[ "\$2" == *adversarial* ]]; then
  cat "${mock_dir}/ar_output.txt"
else
  cat "${mock_dir}/cr_output.txt"
fi
exit 0
EOF
  chmod +x "${mock_dir}/claude"
}

# =========================================================
# TEST 26: arbiter overrides a code-reviewer BLOCKING FAIL when it sides
# with adversarial-reviewer's PASS (dev-env#35)
# =========================================================
echo ""
echo "=== Test 26: arbiter can override code-reviewer FAIL when adversarial-reviewer PASSes ==="

setup_repo
stage_small_change

MOCK26_DIR="${TMPDIR_TEST}/mock26"
make_mock_claude_three_way "${MOCK26_DIR}" \
  "VERDICT: FAIL

ISSUE: Missing Linux platform guard
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Add a runtime OS check." \
  "VERDICT: PASS

No blocking issues found. Script header already states macOS-only scope." \
  "VERDICT: PASS

The adversarial-reviewer is correct: the script's header comment already
documents macOS-only scope, so code-reviewer's finding does not apply."

TEST26_LOG="${TMPDIR_TEST}/test26-review.log"
rm -f "${TEST26_LOG}"

exit_t26=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST26_LOG}" CLAUDE_CLI="${MOCK26_DIR}/claude" GH_ISSUE_FILING_DISABLED=1 bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t26=$?
cd - >/dev/null

assert_eq \
  "arbiter PASS overrides code-reviewer BLOCKING FAIL (exit 0) - dev-env#35" \
  "0" \
  "${exit_t26}"

# =========================================================
# TEST 27: arbiter siding with code-reviewer still blocks the commit
# =========================================================
echo ""
echo "=== Test 27: arbiter siding with code-reviewer still blocks commit ==="

setup_repo
stage_small_change

MOCK27_DIR="${TMPDIR_TEST}/mock27"
make_mock_claude_three_way "${MOCK27_DIR}" \
  "VERDICT: FAIL

ISSUE: Hardcoded credential
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Remove the hardcoded credential." \
  "VERDICT: PASS

No blocking issues found." \
  "VERDICT: FAIL

ISSUE: Hardcoded credential
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: code-reviewer is correct; adversarial-reviewer missed this."

TEST27_LOG="${TMPDIR_TEST}/test27-review.log"
rm -f "${TEST27_LOG}"

exit_t27=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST27_LOG}" CLAUDE_CLI="${MOCK27_DIR}/claude" GH_ISSUE_FILING_DISABLED=1 bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t27=$?
cd - >/dev/null

assert_eq \
  "arbiter siding with code-reviewer still blocks commit (exit 1)" \
  "1" \
  "${exit_t27}"
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `bash ~/Developer/claude-config/hooks/tests/run-review-test.sh 2>&1 | grep -A3 "Test 26\|Test 27"`
Expected: both FAIL — no arbiter call exists yet, so test 26's commit is still blocked (exit 1 instead of expected 0) and test 27 passes coincidentally (existing behavior already blocks) but for the wrong reason (no arbiter ran at all) — treat both as red until Step 4 lands, then re-verify 27 specifically exercises the arbiter path (check `${TEST27_LOG}` contains an arbiter section, not just the exit code).

- [ ] **Step 3: Add `GH_ISSUE_FILING_DISABLED` guard and `file_reviewer_disagreement_issue` to `run-review.sh`**

Near the top of the file, in the configuration block (after `TIMEOUT_SECONDS`, ~line 62):

```bash
# Test-only escape hatch: skip gh issue filing entirely. Production runs
# never set this; hooks/tests/run-review-test.sh sets it so tests don't
# require gh auth or hit the real GitHub API.
GH_ISSUE_FILING_DISABLED="${GH_ISSUE_FILING_DISABLED:-}"
```

Add the arbiter model knob next to `ADVERSARIAL_MODEL` (~line 127-129):

```bash
# Arbiter model: used only when code-reviewer and adversarial-reviewer
# disagree (BLOCKING FAIL vs PASS) in commit mode. Defaults to the same
# model as adversarial-reviewer since both need the bigger-model reasoning
# the disagreement itself signals is warranted.
ARBITER_MODEL=$(git config --get review.arbiterModel 2>/dev/null || echo "")
[[ -n "${ARBITER_MODEL}" ]] || ARBITER_MODEL="claude-sonnet-4-6"
ARBITER_MODEL_ARGS=(--model "${ARBITER_MODEL}")
```

Add the disagreement-logging function near the other helper functions, after `invoke_agent` (~line 300):

```bash
# Files a GitHub issue in smartwatermelon/claude-config (the reviewer
# infrastructure's OWN repo — hardcoded, never REPO_OWNER/REPO_NAME, which
# is the repo under review) logging a code-reviewer/adversarial-reviewer
# disagreement and how the arbiter resolved it. Best-effort: never blocks
# the commit regardless of gh auth state or API errors. dev-env#35's own
# investigation asked for this so recurring disagreement patterns are
# visible for future prompt/model tuning instead of silently resolved
# and forgotten each time.
file_reviewer_disagreement_issue() {
  local cr_output="$1" ar_output="$2" arbiter_output="$3" arbiter_verdict="$4"

  [[ -z "${GH_ISSUE_FILING_DISABLED}" ]] || return 0
  command -v gh >/dev/null 2>&1 || return 0

  local title="Reviewer disagreement: code-reviewer BLOCKING FAIL vs adversarial-reviewer PASS (arbiter: ${arbiter_verdict})"
  local body
  body=$(cat <<EOF
## Reviewer disagreement (auto-logged by run-review.sh)

**Repo under review:** ${REPO_OWNER:-unknown}/${REPO_NAME:-unknown}
**Branch:** ${_review_branch:-unknown}
**Commit:** ${_review_commit:-unknown}
**Arbiter model:** ${ARBITER_MODEL}
**Arbiter verdict:** ${arbiter_verdict}

### code-reviewer output
\`\`\`
${cr_output}
\`\`\`

### adversarial-reviewer output
\`\`\`
${ar_output}
\`\`\`

### Arbiter reasoning
\`\`\`
${arbiter_output}
\`\`\`

---
Filed automatically to track disagreement frequency and patterns for
future code-reviewer prompt/model tuning. See smartwatermelon/dev-env#35.
EOF
)

  gh issue create --repo "smartwatermelon/claude-config" \
    --title "${title}" \
    --body "${body}" \
    --label "tech-debt" \
    >/dev/null 2>&1 || true
}
```

- [ ] **Step 4: Wire the arbiter into the verdict-evaluation block**

Replace the existing block at lines 1284-1293 (the `if [[ "${CODE_REVIEWER_VERDICT}" == "FAIL" ]]` check) with:

```bash
if [[ "${CODE_REVIEWER_VERDICT}" == "FAIL" ]]; then
  # Check if BLOCKING severity exists
  if echo "${CODE_REVIEWER_OUTPUT}" | grep -q "SEVERITY: BLOCKING"; then
    # Reconciliation: if adversarial-reviewer (already a bigger model,
    # already reasoning about failure modes) independently reached PASS,
    # don't take code-reviewer's BLOCKING FAIL as final — ask a third
    # agent to arbitrate rather than silently trusting either side.
    # dev-env#35: non-convergent Haiku findings that adversarial-reviewer
    # explicitly called "solid design choices" on the same diff.
    if [[ "${ADVERSARIAL_AVAILABLE}" == true && "${ADVERSARIAL_VERDICT}" == "PASS" ]]; then
      log_warn "code-reviewer BLOCKING FAIL disagrees with adversarial-reviewer PASS — arbitrating"

      ARBITER_PROMPT="Two reviewers disagree on whether this diff is safe to commit. Read both verdicts and the diff, then decide which reviewer is correct.

IMPORTANT: You are being invoked as a focused analysis tool with --no-session-persistence.
Do NOT output Protocol 0 environment check or any preamble.
Begin your response directly with the verdict in the specified format below.

=== CODE-REVIEWER VERDICT (found a BLOCKING issue) ===
${CODE_REVIEWER_OUTPUT}

=== ADVERSARIAL-REVIEWER VERDICT (found no blocking issue) ===
${ADVERSARIAL_OUTPUT}

=== DIFF UNDER REVIEW ===
\`\`\`diff
${DIFF}
\`\`\`

Decide: is code-reviewer's BLOCKING finding a genuine, currently-present issue in this diff, or is adversarial-reviewer correct that it doesn't apply (e.g. out of stated scope, already mitigated, a false positive)?

CRITICAL: Respond with this exact format:

VERDICT: [PASS or FAIL]

[Explain which reviewer is correct and why, in 2-4 sentences.]

[If VERDICT: FAIL, restate the still-blocking issue:]
ISSUE: [one-line description]
SEVERITY: BLOCKING
LOCATION: [file:line]
DETAILS: [explanation and fix]"

      ARBITER_CACHE="${CACHE_DIR}/arbiter-${DIFF_HASH}"
      ARBITER_OUTPUT=$(invoke_agent "adversarial-reviewer" "${ARBITER_PROMPT}" "${ARBITER_CACHE}" "${ARBITER_MODEL_ARGS[@]}") || true
      [[ -n "${ARBITER_OUTPUT}" ]] || ARBITER_OUTPUT="VERDICT: FAIL (agent error: invoke_agent produced no output)"

      echo "=== ARBITER (reconciling code-reviewer vs adversarial-reviewer) ===" >&2
      echo "${ARBITER_OUTPUT}" >&2
      echo "" >&2
      { printf '=== ARBITER ===\n%s\n' "${ARBITER_OUTPUT}"; } >>"${REVIEW_LOG}" || true

      ARBITER_VERDICT=$(parse_verdict "${ARBITER_OUTPUT}")
      [[ -n "${ARBITER_VERDICT}" ]] || ARBITER_VERDICT="FAIL"
      printf 'arbiter: %s\n' "${ARBITER_VERDICT}" >>"${REVIEW_LOG}" || true

      file_reviewer_disagreement_issue "${CODE_REVIEWER_OUTPUT}" "${ADVERSARIAL_OUTPUT}" "${ARBITER_OUTPUT}" "${ARBITER_VERDICT}"

      if [[ "${ARBITER_VERDICT}" == "PASS" ]]; then
        log_success "Arbiter sided with adversarial-reviewer — commit allowed"
      else
        log_error "Arbiter sided with code-reviewer - commit rejected"
        exit 1
      fi
    else
      log_error "code-reviewer found blocking issues - commit rejected"
      exit 1
    fi
  else
    log_warn "code-reviewer found warnings (non-blocking)"
    # Continue to adversarial if security-critical
  fi
fi
```

Note: reuses the `"adversarial-reviewer"` agent name for the arbiter call (not a new agent definition) since the arbiter's job — assume-wrong-until-proven reasoning about a specific disagreement — is the same skill `adversarial-reviewer` already has; only the prompt differs. This avoids needing a new agent registration. `ARBITER_CACHE` is deliberately a distinct cache key from `ADVERSARIAL_CACHE` (different prompt content) so `invoke_agent`'s existing PASS-caching doesn't cross-contaminate the two.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash ~/Developer/claude-config/hooks/tests/run-review-test.sh 2>&1 | grep -A3 "Test 26\|Test 27"`
Expected: both PASS. For Test 27, additionally confirm the arbiter actually ran: `grep -q "ARBITER" "${TMPDIR_TEST}/test27-review.log"` style check — if the plan's Step 2 caveat about "27 passes for the wrong reason" pre-fix still applies post-fix, add an explicit `assert_contains "arbiter ran" "=== ARBITER" "$(cat "${TEST27_LOG}")"` assertion to Test 27 to make this unambiguous.

- [ ] **Step 6: Run the full test suite to check for regressions**

Run: `bash ~/Developer/claude-config/hooks/tests/run-review-test.sh 2>&1 | tail -20`
Expected: all prior tests (1-25) still PASS; total FAIL count is 0.

- [ ] **Step 7: Commit**

```bash
cd ~/Developer/claude-config
git add hooks/run-review.sh hooks/tests/run-review-test.sh
git commit -m "fix(review): arbitrate code-reviewer/adversarial-reviewer disagreements

Previously a code-reviewer BLOCKING FAIL exited immediately regardless of
what adversarial-reviewer concluded — no reconciliation existed even when
adversarial-reviewer explicitly passed the same diff. Add a third-agent
arbiter call (Sonnet, reusing the adversarial-reviewer agent with a
dedicated reconciliation prompt) that runs only when the two disagree
(BLOCKING FAIL vs PASS), and log every arbitration as a GitHub issue in
this repo regardless of outcome, so disagreement patterns are visible for
future code-reviewer prompt/model tuning.

Ref: smartwatermelon/dev-env#35"
```

---

## Task 4: Update documentation

**Files:**

- Modify: `hooks/run-review.sh:32-42` (header comment: CONFIGURATION section)
- Modify: `~/.claude/docs/CODE-REVIEW.md` (via `~/Developer/claude-config`'s copy, if that doc is sourced from this repo — verify path first)

**Interfaces:** None (documentation only).

- [ ] **Step 1: Verify where CODE-REVIEW.md's source of truth lives**

Run: `ls -la ~/.claude/docs/CODE-REVIEW.md` — check whether it's a symlink into `claude-config` or a standalone file. If it's a symlink, edit the target in `claude-config`; if standalone, this step is out of scope for this repo (skip Task 4's second file and note it in the commit message).

- [ ] **Step 2: Update `hooks/run-review.sh`'s CONFIGURATION comment block**

Add the two new knobs to the existing list at lines 32-37:

```bash
#   review.arbiterModel    - Claude model ID for the reconciliation arbiter
#                             (default: claude-sonnet-4-6, only invoked when
#                             code-reviewer BLOCKING FAIL disagrees with an
#                             adversarial-reviewer PASS)
```

- [ ] **Step 3: Add a "Reviewer Convergence" section to `CODE-REVIEW.md`** (only if Step 1 confirmed the symlink)

Add after the existing "Recurring CI Findings Signal Local Review Gaps" section:

```markdown
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
   Every arbitration is logged as a GitHub issue in claude-config
   regardless of outcome, to surface disagreement patterns over time.

If review still fails to converge after these mechanisms are in place,
that is itself worth a fresh issue — check `smartwatermelon/claude-config`
issues for "Reviewer disagreement:"-titled entries first, since the
arbiter-logging in mechanism 3 may already have captured the pattern.
```

- [ ] **Step 4: Commit**

```bash
cd ~/Developer/claude-config
git add hooks/run-review.sh docs/CODE-REVIEW.md
git commit -m "docs(review): document the three convergence mechanisms and new git config knobs

Ref: smartwatermelon/dev-env#35"
```

---

## Task 5: Close out dev-env#35

**Files:** None (GitHub issue only, in `smartwatermelon/dev-env`, a different repo from the one all prior tasks touched).

- [ ] **Step 1: Push the claude-config branch and open a PR**

Follow the standard branch/PR/CI workflow (Protocol 6) for `smartwatermelon/claude-config`. Do NOT skip CI or merge without explicit human authorization, per every other session in this project.

- [ ] **Step 2: After the PR merges, close dev-env#35 with a cross-repo reference**

```bash
gh issue close 35 --repo smartwatermelon/dev-env --comment "Fixed via smartwatermelon/claude-config#<PR-number>: file-header context injection, round-over-round FAIL memory, and a reconciliation arbiter for code-reviewer/adversarial-reviewer disagreements (logged as new issues in claude-config going forward for pattern tracking)."
```

---

## Self-Review Notes

- **Spec coverage:** All three user-approved fixes (file-scope context, round memory keyed by branch+files, third-arbiter reconciliation with disagreement logging to claude-config) have dedicated tasks and tests. Documentation update captured in Task 4. Issue closeout captured in Task 5.
- **Placeholder scan:** No TBD/TODO markers; all code blocks are complete, runnable bash matching existing file conventions (mktemp, `|| true` guards, `git config --get` pattern, `shasum -a 256` for cache keys).
- **Type/interface consistency:** `extract_file_header_context`, `round_history_key`, `write_round_feedback`, `read_round_feedback`, `clear_round_feedback`, and `file_reviewer_disagreement_issue` are each defined once (Tasks 1-3) and consumed with matching names/arg order in every later reference. `ARBITER_MODEL_ARGS` mirrors the existing `ADVERSARIAL_MODEL_ARGS` / `CODE_REVIEWER_MODEL_ARGS` array pattern exactly.
- **Scope boundary respected:** commit mode only, as agreed — full-diff/codebase modes untouched.
