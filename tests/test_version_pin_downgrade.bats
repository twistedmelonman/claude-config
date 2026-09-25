#!/usr/bin/env bats
# Tests for downgrade_version_unfamiliarity_findings() in hooks/run-review.sh.
#
# Why this exists: a reviewer model's training cutoff makes any version pin
# newer than that cutoff read as "this version doesn't exist" — a false
# BLOCKING FAIL on a deliberate, tested pin. The function rewrites that
# specific objection to WARNING, but never when the block also carries a
# substantive claim (CVE, deprecation, breaking change), and never when an
# unrelated blocking finding survives alongside it.
#
# Run: bats tests/test_version_pin_downgrade.bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../hooks/run-review.sh"
  # log_warn is defined elsewhere in the script; stub it so sourcing just the
  # one function under test is enough.
  log_warn() { :; }
  export -f log_warn
  eval "$(sed -n '/^has_blocking_severity() {/,/^}/p' "${SCRIPT}")"
  eval "$(sed -n '/^downgrade_version_unfamiliarity_findings() {/,/^}/p' "${SCRIPT}")"
  eval "$(sed -n '/^parse_verdict() {/,/^}/p' "${SCRIPT}")"
}

@test "pure unfamiliarity: severity becomes WARNING" {
  run downgrade_version_unfamiliarity_findings "VERDICT: FAIL
ISSUE: pin to actionlint 1.7.7 does not exist
SEVERITY: BLOCKING
DETAILS: no such version published"
  [[ "${output}" == *"SEVERITY: WARNING"* ]]
  [[ "${output}" != *"SEVERITY: BLOCKING"* ]]
}

@test "pure unfamiliarity: verdict is promoted so the commit is not blocked" {
  local out
  out=$(downgrade_version_unfamiliarity_findings "VERDICT: FAIL
ISSUE: pin to actionlint 1.7.7 does not exist
SEVERITY: BLOCKING
DETAILS: unrecognized version")
  [ "$(parse_verdict "${out}")" = "PASS" ]
}

@test "a CVE claim is never downgraded, even when worded as unfamiliarity" {
  local out
  out=$(downgrade_version_unfamiliarity_findings "VERDICT: FAIL
ISSUE: lodash 4.17.19 unfamiliar
SEVERITY: BLOCKING
DETAILS: CVE-2020-8203 prototype pollution")
  [[ "${out}" == *"SEVERITY: BLOCKING"* ]]
  [ "$(parse_verdict "${out}")" = "FAIL" ]
}

@test "deprecation and breaking-change claims are never downgraded" {
  run downgrade_version_unfamiliarity_findings "ISSUE: foo 9.9.9 not a known version
SEVERITY: BLOCKING
DETAILS: this release is deprecated"
  [[ "${output}" == *"SEVERITY: BLOCKING"* ]]
}

@test "an unrelated blocking finding keeps the verdict at FAIL" {
  local out
  out=$(downgrade_version_unfamiliarity_findings "VERDICT: FAIL
ISSUE: pin to actionlint 1.7.7 does not exist
SEVERITY: BLOCKING
DETAILS: unrecognized version
ISSUE: rm -rf on an unguarded variable
SEVERITY: BLOCKING
DETAILS: deletes / when the variable is empty")
  [ "$(parse_verdict "${out}")" = "FAIL" ]
  # The version-pin finding is still downgraded; only the real bug blocks.
  [[ "${out}" == *"SEVERITY: WARNING"* ]]
  [[ "${out}" == *"SEVERITY: BLOCKING"* ]]
}

@test "a clean PASS passes through untouched" {
  local input="VERDICT: PASS
No issues found."
  [ "$(downgrade_version_unfamiliarity_findings "${input}")" = "${input}" ]
}

@test "empty input produces empty output" {
  local out
  out=$(downgrade_version_unfamiliarity_findings "")
  [ -z "${out}" ]
}

@test "downgraded findings are never deleted, only relabeled" {
  run downgrade_version_unfamiliarity_findings "VERDICT: FAIL
ISSUE: pin to actionlint 1.7.7 does not exist
SEVERITY: BLOCKING
LOCATION: .github/workflows/ci.yml:14
DETAILS: no such version published"
  [[ "${output}" == *"ISSUE: pin to actionlint 1.7.7 does not exist"* ]]
  [[ "${output}" == *"LOCATION: .github/workflows/ci.yml:14"* ]]
  [[ "${output}" == *"DETAILS: no such version published"* ]]
}

@test "applying the function twice is idempotent" {
  local once twice
  once=$(downgrade_version_unfamiliarity_findings "VERDICT: FAIL
ISSUE: tool 1.2.3 does not exist
SEVERITY: BLOCKING")
  twice=$(downgrade_version_unfamiliarity_findings "${once}")
  [ "${once}" = "${twice}" ]
}

# --- Verdict-promotion regression cases (found in adversarial review) ---

@test "promotion rewrites only the first VERDICT line, not a trailing one" {
  # `sed '1,/^VERDICT:/'` looks correct but its range ends at the SECOND
  # match, so it rewrote a trailing VERDICT line too.
  local out
  out=$(downgrade_version_unfamiliarity_findings "VERDICT: FAIL
ISSUE: tool 1.2.3 does not exist
SEVERITY: BLOCKING
VERDICT: FAIL")
  [ "$(printf '%s\n' "${out}" | head -1)" = "VERDICT: PASS" ]
  [ "$(printf '%s\n' "${out}" | tail -1)" = "VERDICT: FAIL" ]
}

@test "promotion preserves trailing text on the verdict line" {
  local out
  out=$(downgrade_version_unfamiliarity_findings "VERDICT: FAIL (1 issue)
ISSUE: tool 1.2.3 does not exist
SEVERITY: BLOCKING")
  [ "$(printf '%s\n' "${out}" | head -1)" = "VERDICT: PASS (1 issue)" ]
}

@test "promotion handles a lowercase verdict, matching parse_verdict" {
  # parse_verdict is case-insensitive, so a lowercase REVISE left unrewritten
  # would still normalize to FAIL and block the commit.
  local out
  out=$(downgrade_version_unfamiliarity_findings "verdict: revise
ISSUE: tool 1.2.3 does not exist
SEVERITY: BLOCKING")
  [ "$(parse_verdict "${out}")" = "PASS" ]
}

@test "promotion handles arbitrary verdict casing and both keyword lengths" {
  local out
  for v in "VERDICT: fAiL" "VERDICT: rEvIsE" "verdict: revise - see below"; do
    out=$(downgrade_version_unfamiliarity_findings "${v}
ISSUE: tool 1.2.3 does not exist
SEVERITY: BLOCKING")
    [ "$(parse_verdict "${out}")" = "PASS" ]
  done
  # REVISE is 6 chars and FAIL is 4; the tail must survive either way.
  out=$(downgrade_version_unfamiliarity_findings "VERDICT: REVISE - see below
ISSUE: tool 1.2.3 does not exist
SEVERITY: BLOCKING")
  [ "$(printf '%s\n' "${out}" | head -1)" = "VERDICT: PASS - see below" ]
}

@test "supply-chain claims block regardless of separator" {
  # The dot in the `supply.chain` pattern is an intentional wildcard; this
  # pins the variants it must keep catching if anyone escapes it.
  local out sep
  for sep in " " "-" "_"; do
    out=$(downgrade_version_unfamiliarity_findings "VERDICT: FAIL
ISSUE: tool 1.2.3 does not exist
SEVERITY: BLOCKING
DETAILS: possible supply${sep}chain compromise")
    [[ "${out}" == *"SEVERITY: BLOCKING"* ]]
    [ "$(parse_verdict "${out}")" = "FAIL" ]
  done
}

@test "markdown severity: a bolded BLOCKING survivor keeps FAIL and the sentinel" {
  local out
  out=$(downgrade_version_unfamiliarity_findings "__REVIEW_BLOCKING__ true
VERDICT: FAIL
ISSUE: pin to actionlint 1.7.7 does not exist
SEVERITY: BLOCKING
DETAILS: no such version published

ISSUE: user input passed to eval
**SEVERITY:** BLOCKING
DETAILS: eval of form data.")
  [ "$(parse_verdict "${out}")" = "FAIL" ]
  [[ "${out}" == *"__REVIEW_BLOCKING__ true"* ]]
}

@test "block split: a numbered ISSUE line starts a new finding" {
  local out
  out=$(downgrade_version_unfamiliarity_findings "VERDICT: FAIL
1. ISSUE: pin to actionlint 1.7.7 does not exist
SEVERITY: BLOCKING
DETAILS: no such version published
2. ISSUE: off-by-one in loop
SEVERITY: BLOCKING
DETAILS: The loop skips the last element.")
  [ "$(parse_verdict "${out}")" = "FAIL" ]
  grep -A1 'off-by-one' <<<"${out}" | grep -q 'SEVERITY: BLOCKING'
}
