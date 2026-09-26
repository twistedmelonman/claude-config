#!/usr/bin/env bats
# Tests for downgrade_unverifiable_findings() and diff_changed_paths() in
# hooks/run-review.sh.
#
# Why this exists: reviewers run with no tools and no network, yet emitted
# BLOCKING findings on two kinds of claim they had no way to check.
#   - #455 / #555: a flat claim about external behavior. The Netlify fixtures
#     below are VERBATIM live reviewer output from 2026-09-24: Haiku blocked a
#     documented `%{submissionId}` variable 3 of 3 times, and once the arbiter
#     upheld it. netlify-live-2 is that arbiter's restatement.
#   - #488: a finding against `tally.sh`, a file that was never in the diff.
# The function turns those into WARNING. The tests below also pin the other
# direction: real defects must keep blocking.
#
# Run: bats tests/test_unverifiable_claim_downgrade.bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../hooks/run-review.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures/unverifiable-claims"
  log_warn() { :; }
  export -f log_warn
  export REVIEW_LOG=/dev/null
  eval "$(sed -n '/^has_blocking_severity() {/,/^}/p' "${SCRIPT}")"
  eval "$(sed -n '/^_path_exists_in_repo() {/,/^}/p' "${SCRIPT}")"
  eval "$(sed -n '/^_finding_quotes_diff() {/,/^}/p' "${SCRIPT}")"
  eval "$(sed -n '/^downgrade_unverifiable_findings() {/,/^}/p' "${SCRIPT}")"
  eval "$(sed -n '/^diff_changed_paths() {/,/^}/p' "${SCRIPT}")"
  eval "$(sed -n '/^parse_verdict() {/,/^}/p' "${SCRIPT}")"
}

# --- Kind 1: external-behavior claims (#455, #555) ---

@test "every measured live Netlify false block is downgraded and the verdict passes" {
  local f out
  for f in "${FIX}"/netlify-live-*.txt; do
    out=$(downgrade_unverifiable_findings "$(cat "${f}")" "contact.html")
    [[ "${out}" != *"SEVERITY: BLOCKING"* ]] || {
      echo "still blocking: ${f}"
      return 1
    }
    [[ "${out}" == *"SEVERITY: WARNING"* ]]
    [ "$(parse_verdict "${out}")" = "PASS" ]
  done
}

# The #455 report's own wording says "token" in the TEMPLATE sense
# ("substitution token", "email subject token"). #592 kept it blocking on the
# security list. Measured afterwards: it also never matched the external
# check, which wanted "does not support" before the noun, not "is not a
# documented <platform> ... token" after it. Both are fixed; this is #455's
# verbatim arbiter finding.
@test "the #455 report's original wording is downgraded" {
  local out
  out=$(downgrade_unverifiable_findings "VERDICT: FAIL
ISSUE: \`%{submissionId}\` is not a documented Netlify Forms email subject token; will render as literal string
SEVERITY: BLOCKING
LOCATION: index.html:42
DETAILS: submissionId is not a submitted form field and does not appear in Netlify's documented token list for this feature." "index.html")
  [[ "${out}" == *"SEVERITY: WARNING"* ]]
  [ "$(parse_verdict "${out}")" = "PASS" ]
}

# The KNOWN-BAD CASE for #455: every code-reviewer and arbiter finding from
# the four blocked tnjcleaning attempts on 2026-08-31, verbatim from that
# repo's reviewer-disagreements.log. All eight blocked on origin/main at
# f662d57, with or without the security exemption.
@test "every recorded tnjcleaning #455 finding (2026-08-31) is downgraded" {
  local f out n=0
  for f in "${FIX}"/tnjcleaning-455-*.txt; do
    n=$((n + 1))
    out=$(downgrade_unverifiable_findings "$(cat "${f}")" "index.html")
    [[ "${out}" != *"SEVERITY: BLOCKING"* ]] || {
      echo "still blocking: ${f}"
      return 1
    }
    [ "$(parse_verdict "${out}")" = "PASS" ]
  done
  [ "${n}" -eq 8 ]
}

@test "template token: a Netlify claim that also names an API token stays blocking" {
  local out
  out=$(downgrade_unverifiable_findings "VERDICT: FAIL
ISSUE: Netlify does not support this token syntax; the API token grants deploy access
SEVERITY: BLOCKING
LOCATION: netlify.toml:4
DETAILS: The deploy token is committed to the repo." "netlify.toml")
  [[ "${out}" == *"SEVERITY: BLOCKING"* ]]
  [ "$(parse_verdict "${out}")" = "FAIL" ]
}

@test "template token: GITHUB_TOKEN beside a platform claim stays blocking" {
  local out
  out=$(downgrade_unverifiable_findings "VERDICT: FAIL
ISSUE: GitHub Actions does not support masking GITHUB_TOKEN in this expression
SEVERITY: BLOCKING
LOCATION: ci.yml:12
DETAILS: The expression concatenates GITHUB_TOKEN into a step output." "ci.yml")
  [[ "${out}" == *"SEVERITY: BLOCKING"* ]]
}

@test "template token: 'the token is unsupported' with a credential word stays blocking" {
  local out
  out=$(downgrade_unverifiable_findings "VERDICT: FAIL
ISSUE: \`%{apiKey}\` is not a supported Netlify Forms subject variable
SEVERITY: BLOCKING
LOCATION: index.html:9
DETAILS: If the token is unsupported, the secret api key is sent in the subject." "index.html")
  [[ "${out}" == *"SEVERITY: BLOCKING"* ]]
}

@test "a Kind B claim about a CLI tool is downgraded (#555 class)" {
  run downgrade_unverifiable_findings "VERDICT: FAIL
ISSUE: sed uses POSIX bracket expression not supported by macOS BSD sed
SEVERITY: BLOCKING
LOCATION: lib.sh:50
DETAILS: macOS BSD sed does not support POSIX bracket expressions like [[:space:]]." "lib.sh"
  [[ "${output}" == *"SEVERITY: WARNING"* ]]
}

@test "a hedged external claim with a security class stays blocking" {
  local out
  out=$(downgrade_unverifiable_findings "VERDICT: FAIL
ISSUE: hardcoded API key in workflow; Actions does not support masking this syntax
SEVERITY: BLOCKING
LOCATION: ci.yml:3
DETAILS: The secret is committed in plain text." "ci.yml")
  [[ "${out}" == *"SEVERITY: BLOCKING"* ]]
  [ "$(parse_verdict "${out}")" = "FAIL" ]
}

@test "an in-diff logic defect worded with 'does not support' stays blocking" {
  run downgrade_unverifiable_findings "VERDICT: FAIL
ISSUE: parse_args does not support an empty argument list and crashes
SEVERITY: BLOCKING
LOCATION: foo.sh:12
DETAILS: \$1 is read unguarded under set -u." "foo.sh"
  [[ "${output}" == *"SEVERITY: BLOCKING"* ]]
}

@test "true positives stay blocking: eval, unquoted rm -rf, credential" {
  local body
  for body in \
    "ISSUE: user input passed to eval
SEVERITY: BLOCKING
LOCATION: foo.sh:3
DETAILS: eval \"\$INPUT\" executes arbitrary commands." \
    "ISSUE: unquoted rm -rf on an unset variable
SEVERITY: BLOCKING
LOCATION: foo.sh:4
DETAILS: rm -rf \$DIR/ deletes / when DIR is empty." \
    "ISSUE: credential committed
SEVERITY: BLOCKING
LOCATION: foo.sh:5
DETAILS: A GitHub token is hard-coded."; do
    run downgrade_unverifiable_findings "VERDICT: FAIL
${body}" "foo.sh"
    [[ "${output}" == *"SEVERITY: BLOCKING"* ]]
    [ "$(parse_verdict "${output}")" = "FAIL" ]
  done
}

@test "an unrelated real blocking finding keeps the verdict at FAIL" {
  local out
  out=$(downgrade_unverifiable_findings "VERDICT: FAIL
$(tail -n +3 "${FIX}/netlify-live-1.txt")

ISSUE: user input passed to eval
SEVERITY: BLOCKING
LOCATION: contact.html:3
DETAILS: eval of form data." "contact.html")
  [[ "${out}" == *"SEVERITY: WARNING"* ]]
  [[ "${out}" == *"SEVERITY: BLOCKING"* ]]
  [ "$(parse_verdict "${out}")" = "FAIL" ]
}

# --- Kind 2: LOCATION outside the diff (#488) ---

# #488's literal finding was a leaked token plus eval. Without the diff ($3)
# the phantom-file check cannot run, so a security finding outside the diff
# stays blocking. False passes are worse.
@test "#488 replay without the diff: a security finding outside the diff stays blocking" {
  local out
  out=$(downgrade_unverifiable_findings "VERDICT: FAIL
ISSUE: Hardcoded GitHub API token and unsafe rm with eval
SEVERITY: BLOCKING
LOCATION: tally.sh:14
DETAILS: A token is embedded in tally.sh and eval runs rm on untrusted input." \
    ".claude/hooks/extensions/example.sh.disabled")
  [[ "${out}" == *"SEVERITY: BLOCKING"* ]]
  [ "$(parse_verdict "${out}")" = "FAIL" ]
}

@test "#488 shape: a non-security finding against a file not in the diff is downgraded" {
  local out
  out=$(downgrade_unverifiable_findings "VERDICT: FAIL
ISSUE: off-by-one in the tally loop
SEVERITY: BLOCKING
LOCATION: tally.sh:14
DETAILS: The loop skips the last element." \
    ".claude/hooks/extensions/example.sh.disabled")
  [[ "${out}" == *"SEVERITY: WARNING"* ]]
  [ "$(parse_verdict "${out}")" = "PASS" ]
}

@test "a location in the diff is not downgraded, by full path or basename" {
  local loc
  for loc in "hooks/run-review.sh:120" "run-review.sh:120-130" "\`hooks/run-review.sh\` (line 4)"; do
    run downgrade_unverifiable_findings "VERDICT: FAIL
ISSUE: off-by-one in loop
SEVERITY: BLOCKING
LOCATION: ${loc}
DETAILS: The loop skips the last element." "hooks/run-review.sh"
    [[ "${output}" == *"SEVERITY: BLOCKING"* ]] || {
      echo "downgraded wrongly for LOCATION ${loc}"
      return 1
    }
  done
}

@test "a cross-file location with one file in the diff is not downgraded" {
  run downgrade_unverifiable_findings "VERDICT: FAIL
ISSUE: key mismatch across files
SEVERITY: BLOCKING
LOCATION: src/a.ts+src/b.ts
DETAILS: a writes key foo, b reads key bar." "src/b.ts"
  [[ "${output}" == *"SEVERITY: BLOCKING"* ]]
}

@test "unspecified or non-path locations are never downgraded (keeps #450 fail-closed)" {
  local loc
  for loc in "unspecified" "N/A" "" "general"; do
    run downgrade_unverifiable_findings "VERDICT: FAIL
ISSUE: FAIL verdict with no blocking finding and no structured boolean
SEVERITY: BLOCKING
LOCATION: ${loc}
DETAILS: Treated as blocking." "foo.sh"
    [[ "${output}" == *"SEVERITY: BLOCKING"* ]] || {
      echo "downgraded wrongly for LOCATION '${loc}'"
      return 1
    }
  done
}

@test "an empty changed-path list disables the location check" {
  run downgrade_unverifiable_findings "VERDICT: FAIL
ISSUE: off-by-one in loop
SEVERITY: BLOCKING
LOCATION: tally.sh:14
DETAILS: The loop skips the last element." ""
  [[ "${output}" == *"SEVERITY: BLOCKING"* ]]
}

# --- Structured sentinel ---

@test "the blocking=true sentinel is dropped only when nothing blocking survives" {
  local out
  out=$(downgrade_unverifiable_findings "__REVIEW_BLOCKING__ true
$(cat "${FIX}/netlify-live-3.txt")" "contact.html")
  [[ "${out}" != *"__REVIEW_BLOCKING__"* ]]

  out=$(downgrade_unverifiable_findings "__REVIEW_BLOCKING__ true
VERDICT: FAIL
ISSUE: user input passed to eval
SEVERITY: BLOCKING
LOCATION: contact.html:3
DETAILS: eval of form data." "contact.html")
  [[ "${out}" == *"__REVIEW_BLOCKING__ true"* ]]
}

@test "a PASS with no findings passes through unchanged" {
  run downgrade_unverifiable_findings "VERDICT: PASS
No blocking issues found." "foo.sh"
  [ "${output}" = "VERDICT: PASS
No blocking issues found." ]
}

# --- diff_changed_paths ---

@test "diff_changed_paths reads mnemonic, default, and rename headers" {
  local diff out
  diff='diff --git c/contact.html i/contact.html
--- c/contact.html
+++ i/contact.html
@@ -1 +1 @@
-a
+b
diff --git a/new.sh b/new.sh
new file mode 100755
--- /dev/null
+++ b/new.sh
diff --git a/old.txt b/renamed.txt
similarity index 100%
rename from old.txt
rename to renamed.txt'
  out=$(diff_changed_paths "${diff}")
  [[ "${out}" == *$'\n'"contact.html"$'\n'* || "${out}" == "contact.html"$'\n'* ]]
  grep -qx 'new.sh' <<<"${out}"
  grep -qx 'old.txt' <<<"${out}"
  grep -qx 'renamed.txt' <<<"${out}"
  ! grep -qx '/dev/null' <<<"${out}"
}

# --- Adversarial-review regressions: real defects that must keep blocking ---
# Each of these was downgraded by the first version of this function.

_assert_blocks() {
  # $1 = LOCATION, $2 = changed paths, $3 = ISSUE, $4 = DETAILS
  local out
  out=$(downgrade_unverifiable_findings "VERDICT: FAIL
ISSUE: ${3:-off-by-one in loop}
SEVERITY: BLOCKING
LOCATION: $1
DETAILS: ${4:-The loop skips the last element.}" "$2")
  if [[ "${out}" != *"SEVERITY: BLOCKING"* ]] || [ "$(parse_verdict "${out}")" != "FAIL" ]; then
    echo "downgraded wrongly: LOCATION '$1' against changed '$2'"
    echo "${out}"
    return 1
  fi
}

@test "location: a #L anchor on an in-diff file stays blocking" {
  _assert_blocks "hooks/run-review.sh#L120" "hooks/run-review.sh"
  _assert_blocks "hooks/run-review.sh#L120-L130" "hooks/run-review.sh"
}

@test "location: a directory stays blocking" {
  _assert_blocks "hooks/" "hooks/run-review.sh"
  _assert_blocks "hooks/tests/" "hooks/tests/run-review-test.sh"
  _assert_blocks "hooks/lib" "hooks/lib/x.sh"
}

@test "location: a glob stays blocking" {
  _assert_blocks "*.sh" "hooks/run-review.sh"
  _assert_blocks "hooks/*.sh" "hooks/run-review.sh"
  _assert_blocks "tests/test_*.bats" "tests/test_a.bats"
}

@test "location: a backslash path stays blocking" {
  _assert_blocks 'hooks\run-review.sh:12' "hooks/run-review.sh"
}

@test "location: a filename with a space stays blocking" {
  _assert_blocks "docs/my file.md:3" "docs/my file.md"
  _assert_blocks "\`docs/my file.md\` line 3" "docs/my file.md"
}

@test "location: a non-ASCII filename stays blocking" {
  _assert_blocks "docs/résumé.md:3" "docs/résumé.md"
  # git diff --name-only quotes non-ASCII paths by default (core.quotePath).
  _assert_blocks "docs/résumé.md:3" '"docs/r\303\251sum\303\251.md"'
}

@test "location: a file the change should have edited but did not stays blocking" {
  _assert_blocks "settings.json" "hooks/new-hook.sh" \
    "new hook is never registered" \
    "settings.json has no entry for the new hook, so it never runs."
  _assert_blocks "settings.json:40" "hooks/new-hook.sh" \
    "hook registration missing" \
    "hooks/new-hook.sh is added but nothing invokes it."
  _assert_blocks "README.md" "install.sh" \
    "docs out of date" \
    "The install steps should also be updated to describe the new flag."
}

@test "diff_changed_paths decodes git's octal-quoted non-ASCII paths" {
  local diff out
  diff='diff --git "a/docs/r\303\251sum\303\251.md" "b/docs/r\303\251sum\303\251.md"
--- "a/docs/r\303\251sum\303\251.md"
+++ "b/docs/r\303\251sum\303\251.md"
@@ -1 +1 @@
-a
+b'
  out=$(diff_changed_paths "${diff}")
  grep -qx 'docs/résumé.md' <<<"${out}"
}

@test "external: a secret printed to a CI log stays blocking" {
  _assert_blocks "ci.yml:12" "ci.yml" \
    "GITHUB_TOKEN is printed literally to the CI log" \
    "The echo step sends the value to the log unmasked."
}

@test "external: an in-diff parser that lacks a flag stays blocking" {
  _assert_blocks "parser.sh:30" "parser.sh" \
    "the new parser does not support that flag" \
    "--verbose is documented in usage() but the case statement has no branch for it."
}

@test "external: auth and logging findings stay blocking" {
  _assert_blocks "ci.yml:12" "ci.yml" \
    "auth header is sent to a host that does not support TLS syntax" \
    "The request leaks credentials."
  _assert_blocks "ci.yml:12" "ci.yml" \
    "values render as literal text in logs" \
    "Netlify does not support masking this variable."
}

@test "external: the live Netlify fixtures still downgrade after narrowing" {
  local f out
  for f in "${FIX}"/netlify-live-*.txt; do
    out=$(downgrade_unverifiable_findings "$(cat "${f}")" "contact.html")
    [ "$(parse_verdict "${out}")" = "PASS" ] || { echo "no longer downgraded: ${f}"; return 1; }
  done
}

@test "block split: numbered and bulleted ISSUE lines are separate findings" {
  local prefix out
  for prefix in "1. " "- " "- **" "### " "**"; do
    out=$(downgrade_unverifiable_findings "VERDICT: FAIL
${prefix}ISSUE: Submission ID placeholder syntax is invalid for Netlify Forms
SEVERITY: BLOCKING
LOCATION: contact.html:10
DETAILS: Netlify Forms does not support this syntax.

${prefix/1./2.}ISSUE: off-by-one in the field loop
SEVERITY: BLOCKING
LOCATION: contact.html:3
DETAILS: The loop skips the last field." "contact.html")
    [[ "${out}" == *"SEVERITY: BLOCKING"* ]] || { echo "merged under prefix '${prefix}'"; echo "${out}"; return 1; }
    [ "$(parse_verdict "${out}")" = "FAIL" ] || { echo "verdict promoted under prefix '${prefix}'"; return 1; }
  done
}

@test "block split: a numbered ISSUE merge cannot downgrade a real finding" {
  local out
  out=$(downgrade_unverifiable_findings "VERDICT: FAIL
1. ISSUE: stale helper
SEVERITY: BLOCKING
LOCATION: tally.sh:9
DETAILS: unused.
2. ISSUE: off-by-one in loop
SEVERITY: BLOCKING
LOCATION: foo.sh:3
DETAILS: The loop skips the last element." "foo.sh")
  # The foo.sh finding is in the diff and must block; tally.sh may downgrade.
  [ "$(parse_verdict "${out}")" = "FAIL" ]
  grep -A1 'off-by-one' <<<"${out}" | grep -q 'SEVERITY: BLOCKING'
}

@test "markdown severity: a bolded BLOCKING survivor keeps FAIL and the sentinel" {
  local out
  out=$(downgrade_unverifiable_findings "__REVIEW_BLOCKING__ true
VERDICT: FAIL
ISSUE: Submission ID placeholder syntax is invalid for Netlify Forms
SEVERITY: BLOCKING
LOCATION: contact.html:10
DETAILS: Netlify Forms does not support this syntax.

ISSUE: user input passed to eval
**SEVERITY:** BLOCKING
LOCATION: contact.html:3
DETAILS: eval of form data." "contact.html")
  [ "$(parse_verdict "${out}")" = "FAIL" ]
  [[ "${out}" == *"__REVIEW_BLOCKING__ true"* ]]
}

# --- #488: security finding against a PHANTOM file ---
#
# A scratch repo modelled on smartwatermelon/claude-wrapper#119: the change
# touches one `.disabled` template; tally.sh exists nowhere. Commits use git
# plumbing so no hook runs in the scratch repo.

_phantom_repo() {
  PHANTOM_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${PHANTOM_REPO}/.claude/hooks/extensions"
  git -C "${PHANTOM_REPO}" init -q
  printf '#!/usr/bin/env bash\n# example\n' >"${PHANTOM_REPO}/.claude/hooks/extensions/example.sh.disabled"
  git -C "${PHANTOM_REPO}" add .claude/hooks/extensions/example.sh.disabled
  _phantom_snapshot "base"
  printf 'echo "token pattern updated"\n' >>"${PHANTOM_REPO}/.claude/hooks/extensions/example.sh.disabled"
  git -C "${PHANTOM_REPO}" add .claude/hooks/extensions/example.sh.disabled
  PHANTOM_DIFF=$(git -C "${PHANTOM_REPO}" diff --cached)
  PHANTOM_PATHS=".claude/hooks/extensions/example.sh.disabled"
}

# Record the index as HEAD with plumbing (write-tree, commit-tree,
# update-ref), so no hook runs in the scratch repo.
_phantom_snapshot() {
  local tree obj
  local -a parent=()
  tree=$(git -C "${PHANTOM_REPO}" write-tree)
  if git -C "${PHANTOM_REPO}" rev-parse -q --verify HEAD >/dev/null; then
    parent=(-p HEAD)
  fi
  obj=$(printf '%s\n' "$1" | git -C "${PHANTOM_REPO}" -c user.name=t -c user.email=t@t commit-tree "${tree}" "${parent[@]}")
  git -C "${PHANTOM_REPO}" update-ref HEAD "${obj}"
}

_phantom_run() {
  (cd "${PHANTOM_REPO}" && downgrade_unverifiable_findings "$1" "${PHANTOM_PATHS}" "${PHANTOM_DIFF}")
}

# The KNOWN-BAD CASE for #488: the verbatim code-reviewer output recorded in
# a reviewer-disagreements.log on 2026-09-10. It blocked on origin/main at
# f662d57 even with the security exemption switched off, because its DETAILS
# names the changed file.
@test "#488 verbatim: a security finding against a file that exists nowhere is downgraded" {
  _phantom_repo
  local out
  out=$(_phantom_run "$(cat "${FIX}/issue-488-code-reviewer.txt")")
  [[ "${out}" == *"SEVERITY: WARNING"* ]]
  [[ "${out}" != *"SEVERITY: BLOCKING"* ]]
  [ "$(parse_verdict "${out}")" = "PASS" ]
}

@test "#488 phantom: the file tracked in HEAD keeps it blocking" {
  _phantom_repo
  printf 'TOKEN=x\n' >"${PHANTOM_REPO}/tally.sh"
  git -C "${PHANTOM_REPO}" add tally.sh
  _phantom_snapshot "add tally"
  # Remove it from the worktree and index; it now exists only in HEAD.
  git -C "${PHANTOM_REPO}" rm -q --cached tally.sh
  rm -f "${PHANTOM_REPO}/tally.sh"
  local out
  out=$(_phantom_run "$(cat "${FIX}/issue-488-code-reviewer.txt")")
  [[ "${out}" == *"SEVERITY: BLOCKING"* ]]
  [ "$(parse_verdict "${out}")" = "FAIL" ]
}

@test "#488 phantom: an untracked file of that name keeps it blocking" {
  _phantom_repo
  printf 'TOKEN=x\n' >"${PHANTOM_REPO}/tally.sh"
  local out
  out=$(_phantom_run "$(cat "${FIX}/issue-488-code-reviewer.txt")")
  [[ "${out}" == *"SEVERITY: BLOCKING"* ]]
}

@test "#488 phantom: the same basename in another directory keeps it blocking" {
  _phantom_repo
  mkdir -p "${PHANTOM_REPO}/scripts"
  printf 'TOKEN=x\n' >"${PHANTOM_REPO}/scripts/tally.sh"
  git -C "${PHANTOM_REPO}" add scripts/tally.sh
  _phantom_snapshot "add scripts/tally"
  local out
  out=$(_phantom_run "$(cat "${FIX}/issue-488-code-reviewer.txt")")
  [[ "${out}" == *"SEVERITY: BLOCKING"* ]]
}

@test "#488 phantom: an ISSUE line naming the changed file keeps it blocking" {
  _phantom_repo
  local out
  out=$(_phantom_run "VERDICT: FAIL
ISSUE: example.sh.disabled embeds a hardcoded GitHub token
SEVERITY: BLOCKING
LOCATION: tally.sh:3
DETAILS: A leaked token.")
  [[ "${out}" == *"SEVERITY: BLOCKING"* ]]
}

@test "#488 phantom: quoting code from the diff's added lines keeps it blocking" {
  _phantom_repo
  local out
  out=$(_phantom_run "VERDICT: FAIL
ISSUE: Hardcoded token in the hook template
SEVERITY: BLOCKING
LOCATION: tally.sh:3
DETAILS: The line \`echo \"token pattern updated\"\` leaks the token.")
  [[ "${out}" == *"SEVERITY: BLOCKING"* ]]
}

@test "#488 phantom: a missed-edit finding keeps it blocking" {
  _phantom_repo
  local out
  out=$(_phantom_run "VERDICT: FAIL
ISSUE: The new token check is missing from secrets.sh
SEVERITY: BLOCKING
LOCATION: secrets.sh
DETAILS: secrets.sh should also be updated so the leaked token is caught.")
  [[ "${out}" == *"SEVERITY: BLOCKING"* ]]
}

@test "#488 phantom: outside a git repository it stays blocking" {
  _phantom_repo
  local out
  out=$(cd "${BATS_TEST_TMPDIR}" && GIT_CEILING_DIRECTORIES="${BATS_TEST_TMPDIR}" \
    downgrade_unverifiable_findings "$(cat "${FIX}/issue-488-code-reviewer.txt")" "${PHANTOM_PATHS}" "${PHANTOM_DIFF}")
  [[ "${out}" == *"SEVERITY: BLOCKING"* ]]
}

@test "_path_exists_in_repo: absolute and parent paths count as existing; a phantom does not" {
  _phantom_repo
  (cd "${PHANTOM_REPO}" && _path_exists_in_repo "/etc/nothing-here.sh")
  (cd "${PHANTOM_REPO}" && _path_exists_in_repo "../nothing-here.sh")
  run bash -c "cd '${PHANTOM_REPO}' && $(declare -f _path_exists_in_repo) && _path_exists_in_repo tally.sh"
  [ "${status}" -eq 1 ]
}
