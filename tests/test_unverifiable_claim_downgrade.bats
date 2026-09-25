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

@test "the #455 report's original finding text is downgraded" {
  local out
  out=$(downgrade_unverifiable_findings "VERDICT: FAIL
ISSUE: \`%{submissionId}\` is not a documented Netlify Forms email subject token; will render as literal string
SEVERITY: BLOCKING
LOCATION: index.html:42
DETAILS: submissionId is not a submitted form field and does not appear in Netlify's documented token list for this feature." "index.html")
  [[ "${out}" == *"SEVERITY: WARNING"* ]]
  [ "$(parse_verdict "${out}")" = "PASS" ]
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

@test "#488 replay: a finding against a file not in the diff is downgraded" {
  local out
  out=$(downgrade_unverifiable_findings "VERDICT: FAIL
ISSUE: Hardcoded GitHub API token and unsafe rm with eval
SEVERITY: BLOCKING
LOCATION: tally.sh:14
DETAILS: A token is embedded in tally.sh and eval runs rm on untrusted input." \
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
