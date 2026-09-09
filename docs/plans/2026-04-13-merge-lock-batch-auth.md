# merge-lock batch auth (issue #108) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow `merge-lock auth` to accept a comma-separated list of PR numbers, writing one lock file per PR with a shared reason and a single shared timestamp.

**Architecture:** Minimal change to a single shell script. Parse `$2` as a comma-separated list, trim whitespace, validate each entry is a positive integer, then call the existing `create_merge_lock` once per PR — with the timestamp captured ONCE before the loop so all TTLs are aligned. Tighten reason to required (resolved design decision — see Scope below).

**Tech Stack:** Bash 5.x, bats for tests, shellcheck for lint.

**Files in scope:**

- Modify: `hooks/merge-lock.sh`
- Create: `tests/test_merge_lock_batch_auth.bats`

**Out of scope:** bulk `check` / `release` / `status` operations (explicitly deferred per issue).

---

## Scope decisions (resolved)

1. **Reason required in both single-PR and list form.** Issue #108 claims this is "same as today" but today reason defaults to `"Manual authorization"`. User chose to tighten — reason is now required everywhere. This is a minor breaking change and deserves a note in the commit body.
2. **Atomic validation, not atomic write.** If any PR in the list fails number validation, exit non-zero BEFORE writing any lock files. If filesystem write fails mid-loop (unlikely), remaining locks are skipped but earlier ones stay — acceptable since lock creation is idempotent and re-running the command is safe.
3. **Shared timestamp.** Capture `ts=$(date +%s)` once in the command dispatcher and pass it down to `create_merge_lock` as a new third argument. Prevents drift if the loop takes nonzero time.
4. **Whitespace tolerance.** `100, 204 ,553` → `100,204,553`. Trim each element after splitting on comma.
5. **Empty elements rejected.** `100,,204` is an error, not silently coerced to `100,204`.

---

## Task 1: Add failing tests first

**Files:**

- Create: `tests/test_merge_lock_batch_auth.bats`

**Step 1: Write the failing test file**

```bash
#!/usr/bin/env bats
# Tests for merge-lock batch authorization (issue #108).
# Run: bats tests/test_merge_lock_batch_auth.bats

SCRIPT="${BATS_TEST_DIRNAME}/../hooks/merge-lock.sh"

setup() {
  TMP_HOME="$(mktemp -d)"
  export HOME="${TMP_HOME}"
}

teardown() {
  rm -rf "${TMP_HOME}"
}

lock_file() {
  echo "${TMP_HOME}/.claude/merge-locks/pr-$1.lock"
}

@test "single PR form still works" {
  run bash "${SCRIPT}" auth 100 "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 100)" ]
  grep -q "^PR_NUMBER=100$" "$(lock_file 100)"
  grep -q "^REASON=ok$" "$(lock_file 100)"
}

@test "comma-separated list writes one lock per PR" {
  run bash "${SCRIPT}" auth 100,204,553 "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 100)" ]
  [ -f "$(lock_file 204)" ]
  [ -f "$(lock_file 553)" ]
}

@test "whitespace inside list is tolerated" {
  run bash "${SCRIPT}" auth "100, 204 ,553" "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 100)" ]
  [ -f "$(lock_file 204)" ]
  [ -f "$(lock_file 553)" ]
}

@test "all PRs share the same timestamp" {
  run bash "${SCRIPT}" auth 100,204,553 "ok"
  [ "${status}" -eq 0 ]
  ts100=$(grep "^TIMESTAMP=" "$(lock_file 100)" | cut -d= -f2)
  ts204=$(grep "^TIMESTAMP=" "$(lock_file 204)" | cut -d= -f2)
  ts553=$(grep "^TIMESTAMP=" "$(lock_file 553)" | cut -d= -f2)
  [ "${ts100}" = "${ts204}" ]
  [ "${ts204}" = "${ts553}" ]
}

@test "list form refuses when reason is missing" {
  run bash "${SCRIPT}" auth 100,204,553
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 100)" ]
  [ ! -f "$(lock_file 204)" ]
}

@test "single PR form also refuses when reason is missing (tightened)" {
  run bash "${SCRIPT}" auth 100
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 100)" ]
}

@test "non-numeric entry rejects entire batch" {
  run bash "${SCRIPT}" auth "100,abc,553" "ok"
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 100)" ]
  [ ! -f "$(lock_file 553)" ]
}

@test "empty element in list rejects entire batch" {
  run bash "${SCRIPT}" auth "100,,553" "ok"
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 100)" ]
  [ ! -f "$(lock_file 553)" ]
}
```

**Step 2: Run tests to verify they fail**

Run: `bats tests/test_merge_lock_batch_auth.bats`
Expected: most tests FAIL (list form unsupported, reason not yet required).

**Step 3: Commit failing tests**

```bash
git checkout -b claude/feat-merge-lock-batch-auth-$(date +%s)
git add tests/test_merge_lock_batch_auth.bats
git commit -m "test: add failing tests for merge-lock batch auth (#108)"
```

---

## Task 2: Implement batch auth in merge-lock.sh

**Files:**

- Modify: `hooks/merge-lock.sh`

**Step 1: Change `create_merge_lock` to accept a timestamp argument**

Replace the function signature and body (lines 16–36) so timestamp is passed in rather than computed inside:

```bash
create_merge_lock() {
  local pr_number="$1"
  local reason="$2"
  local ts="$3"
  local lock_file="${LOCK_DIR}/pr-${pr_number}.lock"

  local user
  user=$(whoami)

  {
    echo "PR_NUMBER=${pr_number}"
    echo "AUTHORIZED_BY=${user}"
    echo "TIMESTAMP=${ts}"
    echo "REASON=${reason}"
  } >"${lock_file}"

  echo -e "${GREEN}[merge-lock]${NC} Authorization created for PR #${pr_number}"
  echo -e "${GREEN}[merge-lock]${NC} Valid for 30 minutes"
  echo -e "${GREEN}[merge-lock]${NC} Lock file: ${lock_file}"
}
```

**Step 2: Replace the `authorize | auth)` dispatcher case (lines 110–116)** with a batch-aware version that:

- Requires reason (tightened — see Scope).
- Splits `$2` on comma into an array.
- Trims whitespace from each element.
- Validates each element is a non-empty string of digits (`[0-9]+`).
- Captures a single timestamp.
- Loops, calling `create_merge_lock "$pr" "$reason" "$ts"`.

```bash
  authorize | auth)
    if [[ -z "${2:-}" ]]; then
      echo "Usage: $0 authorize <pr_number[,pr_number...]> <reason>" >&2
      exit 1
    fi
    if [[ -z "${3:-}" ]]; then
      echo "Error: reason is required" >&2
      echo "Usage: $0 authorize <pr_number[,pr_number...]> <reason>" >&2
      exit 1
    fi

    # Parse comma-separated list into validated PR numbers.
    IFS=',' read -r -a _pr_raw <<<"$2"
    _pr_list=()
    for _entry in "${_pr_raw[@]}"; do
      # Trim leading/trailing whitespace.
      _entry="${_entry#"${_entry%%[![:space:]]*}"}"
      _entry="${_entry%"${_entry##*[![:space:]]}"}"
      if [[ -z "${_entry}" ]]; then
        echo "Error: empty PR number in list" >&2
        exit 1
      fi
      if [[ ! "${_entry}" =~ ^[0-9]+$ ]]; then
        echo "Error: invalid PR number: ${_entry}" >&2
        exit 1
      fi
      _pr_list+=("${_entry}")
    done

    # Shared timestamp so all TTLs align.
    _ts=$(date +%s)
    for _pr in "${_pr_list[@]}"; do
      create_merge_lock "${_pr}" "$3" "${_ts}"
    done
    ;;
```

**Step 3: Run tests and verify they pass**

Run: `bats tests/test_merge_lock_batch_auth.bats`
Expected: all 8 tests PASS.

**Step 4: Run shellcheck**

Run: `shellcheck -S info hooks/merge-lock.sh`
Expected: clean (no output).

Per global standards: resolve every issue; no `# shellcheck disable`. Watch for SC2207 (array assignment) and SC2155 (declare-and-assign) — the implementation above uses `read -r -a` to avoid SC2207.

**Step 5: Run full test suite**

Run: `bats tests/`
Expected: all tests PASS, including unrelated pre-merge suites.

**Step 6: Commit implementation**

```bash
git add hooks/merge-lock.sh
git commit -m "feat(merge-lock): support comma-separated PR list in auth (#108)

Allow 'merge-lock auth 100,204,553 \"ok\"' to write one lock file per PR
with a shared reason and shared timestamp. Single-PR form preserved.

Breaking (minor): reason is now required in both single-PR and list form
(previously defaulted to 'Manual authorization'). Tightened per #108
acceptance criteria.

Closes #108"
```

---

## Task 3: Update help text and verify end-to-end

**Files:**

- Modify: `hooks/merge-lock.sh` (help block, lines ~141–148)

**Step 1: Update help text**

Change the `authorize` help line to:

```
  authorize <pr[,pr...]> <reason>  - Create merge authorization(s) (30 min TTL)
```

**Step 2: Manual smoke test**

```bash
rm -f ~/.claude/merge-locks/pr-999{1,2,3}.lock
bash hooks/merge-lock.sh auth 9991,9992,9993 "manual smoke test"
bash hooks/merge-lock.sh list | grep -E 'PR #999[123]'
bash hooks/merge-lock.sh check 9992
rm -f ~/.claude/merge-locks/pr-999{1,2,3}.lock
```

Expected: three locks listed, `check 9992` exits 0 and prints `Authorized`.

**Step 3: Commit help text**

```bash
git add hooks/merge-lock.sh
git commit -m "docs(merge-lock): update help text for batch auth"
```

---

## Task 4: Local review + push

**Step 1:** Both `code-reviewer` and `adversarial-reviewer` run automatically via pre-commit hook. Verify clean verdicts in `$(git rev-parse --git-dir)/last-review-result.log` after each commit.

**Step 2:** Pre-commit verification output (per Protocol 4):

```
🔍 PRE-COMMIT VERIFICATION:
□ Branch check: claude/feat-merge-lock-batch-auth-<id>  (NOT main)
□ Tests: bats tests/ → pass
□ Shellcheck: shellcheck -S info hooks/merge-lock.sh → clean
□ Code review: code-reviewer + adversarial-reviewer → clean
□ Commit message: conventional format, references #108
VERDICT: READY TO COMMIT
```

**Step 3:** Push and open PR (separate turn per Protocol 6):

```bash
git push -u origin HEAD
gh pr create --title "feat(merge-lock): support comma-separated PR list in auth (#108)" --body "Closes #108"
```

**Step 4:** Run post-push loop per `superpowers:post-push-loop`. STOP after PR opens. Wait for explicit `merge-lock auth <PR#> "ok"` before merging.

---

## Risk register

- **Shellcheck surprises in array parsing.** The `IFS=',' read -r -a` pattern avoids SC2207, but `_entry` trim expressions can trigger SC2295 (unquoted patterns) — the expressions above use `"${_entry%%[![:space:]]*}"` with full quoting. If shellcheck flags anything, fix it; do not `disable`.
- **bats mock of `$HOME`.** Tests rely on `LOCK_DIR` resolving to `${HOME}/.claude/merge-locks` — verified from `hooks/merge-lock.sh:6`. If that path changes, the tests need updating.
- **Breaking change on reason.** Any caller currently running `merge-lock auth 100` (no reason) will now fail. Search the repo for such callers before merging:

  ```
  Grep for: merge-lock.sh auth|merge-lock auth
  ```

  If any are found, update them in the same PR.

---

## Plan complete

Plan saved to `docs/plans/2026-04-13-merge-lock-batch-auth.md`. Two execution options:

1. **Subagent-Driven (this session)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Parallel Session (separate)** — Open new session with `superpowers:executing-plans`, batch execution with checkpoints.

Which approach?
