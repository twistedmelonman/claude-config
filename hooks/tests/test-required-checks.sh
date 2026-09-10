#!/usr/bin/env bash
# Tests for classify_status_checks() in pre-merge-review.sh (dev-env#106).
#
# The bug: the pre-merge gate treated EVERY red check as blocking, which is
# stricter than GitHub and deadlocked the lint burndown -- a PR that fixes a
# linter leaves that linter red on its own PR.
#
# Fixtures are REAL captured API responses, not hand-written approximations.
# Hand-typed mocks in this repo have encoded assumptions rather than
# measurements and produced green suites over broken code three times; see
# reference_mock_fidelity_blind_spot. Re-capture with:
#   gh pr view 278 --repo nightowlstudiollc/kebab-tax-netlify \
#     --json statusCheckRollup | jq -c '.statusCheckRollup'

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/../pre-merge-review.sh"
FIXTURES="${SCRIPT_DIR}/fixtures"

pass=0
fail=0

# Source only the classification section, so no network or main-script logic
# runs. Same technique as test-pre-merge-review.sh.
eval "$(sed -n '/^# --- Required Check Classification Functions/,/^# --- End Required Check Classification Functions/p' "${HOOK}" | grep -v '^# ---' || true)"

if ! declare -F classify_status_checks >/dev/null; then
  echo "FATAL: classify_status_checks not sourced -- section markers changed?"
  exit 1
fi

KEBAB_ROLLUP=$(<"${FIXTURES}/rollup-kebab-tax-278.json")
KEBAB_REQUIRED=$(<"${FIXTURES}/required-kebab-tax.json")
CC_ROLLUP=$(<"${FIXTURES}/rollup-claude-config-484.json")

# assert_contains <description> <haystack> <needle>
assert_contains() {
  local desc="$1" hay="$2" needle="$3"
  if printf '%s' "${hay}" | grep -qF -- "${needle}"; then
    printf 'PASS: %s\n' "${desc}"
    pass=$((pass + 1))
  else
    printf 'FAIL: %s\n      expected to find: %s\n      in: %s\n' \
      "${desc}" "${needle}" "${hay}"
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local desc="$1" hay="$2" needle="$3"
  if printf '%s' "${hay}" | grep -qF -- "${needle}"; then
    printf 'FAIL: %s\n      expected NOT to find: %s\n      in: %s\n' \
      "${desc}" "${needle}" "${hay}"
    fail=$((fail + 1))
  else
    printf 'PASS: %s\n' "${desc}"
    pass=$((pass + 1))
  fi
}

echo "=== the #106 case: kebab-tax-netlify PR 278 ==="
# This PR has a FAILURE (validate-audit) and a NEUTRAL (Pages changed), both
# non-required, while the single required check is green. Under the old code
# the whole rollup went to the prompt undifferentiated and this PR could not
# merge. It is the reason the issue was filed.
req=$(classify_status_checks "${KEBAB_ROLLUP}" "${KEBAB_REQUIRED}" required)
other=$(classify_status_checks "${KEBAB_ROLLUP}" "${KEBAB_REQUIRED}" other)

assert_contains "required list holds the required check" \
  "${req}" "claude-review / run-review"
assert_contains "the required check is SUCCESS" "${req}" "SUCCESS"
assert_not_contains "the FAILURE is NOT in the required list" \
  "${req}" "validate-audit"
assert_not_contains "the NEUTRAL is NOT in the required list" \
  "${req}" "Pages changed"

assert_contains "the failing check appears as non-required context" \
  "${other}" "validate-audit"
assert_contains "the failing check keeps its FAILURE conclusion" \
  "${other}" "FAILURE"
assert_contains "the NEUTRAL check appears as non-required" \
  "${other}" "Pages changed"

echo
echo "=== StatusContext nodes (Netlify) must not vanish ==="
# StatusContext has .context/.state, not .name/.conclusion. The pre-fix jq read
# only .name, so this rendered as a null-named entry.
assert_contains "netlify StatusContext is classified, not dropped" \
  "${other}" "netlify/kebab-tax/deploy-preview"
assert_not_contains "no null names leak into the required list" "${req}" "null"
assert_not_contains "no null names leak into the non-required list" \
  "${other}" "null"
assert_contains "StatusContext state is rendered" "${other}" "SUCCESS"

echo
echo "=== substring names must not be misclassified ==="
# `index` on a string does substring matching; membership must be equality.
# kebab-tax has both `lint-functions` and a required check whose name is a
# prefix of nothing here, so assert the general rule directly.
sub_rollup='[{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE"},
             {"__typename":"CheckRun","name":"lint-functions","status":"COMPLETED","conclusion":"SUCCESS"}]'
sub_req='["lint-functions"]'
sub_required=$(classify_status_checks "${sub_rollup}" "${sub_req}" required)
sub_other=$(classify_status_checks "${sub_rollup}" "${sub_req}" other)
assert_contains "exact name is required" "${sub_required}" "lint-functions"
assert_not_contains "a name that is a substring of a required one is NOT required" \
  "${sub_required}" "- lint:"
assert_contains "the substring-named check lands in non-required" \
  "${sub_other}" "- lint:"

echo
echo "=== fail-closed: unknown required set treats everything as required ==="
# This reproduces the pre-#106 behavior, which is what the hook must fall back
# to on 403/404. With an empty required list, the "other" side is everything.
closed=$(classify_status_checks "${KEBAB_ROLLUP}" '[]' other)
assert_contains "fail-closed list includes the failing check" \
  "${closed}" "validate-audit"
assert_contains "fail-closed list includes the required check" \
  "${closed}" "claude-review / run-review"
assert_contains "fail-closed list includes the netlify context" \
  "${closed}" "netlify/kebab-tax/deploy-preview"

echo
echo "=== all-green repo (claude-config PR 484) ==="
cc_req=$(classify_status_checks "${CC_ROLLUP}" '["claude-review / run-review"]' required)
cc_other=$(classify_status_checks "${CC_ROLLUP}" '["claude-review / run-review"]' other)
assert_contains "required check present" "${cc_req}" "claude-review / run-review"
assert_not_contains "standards-check is not required here" \
  "${cc_req}" "standards-check"
assert_contains "standards-check shows as non-required" \
  "${cc_other}" "standards-check"
# claude-review-haiku contains "claude-review" as a substring -- the exact
# check that a naive `index` match would misclassify as required.
assert_not_contains "claude-review-haiku is NOT required (substring trap)" \
  "${cc_req}" "haiku"
assert_contains "claude-review-haiku is non-required" "${cc_other}" "haiku"

echo
echo "=== empty and degenerate inputs ==="
empty_req=$(classify_status_checks '[]' '["x"]' required)
assert_contains "empty rollup yields the no-required-checks note" \
  "${empty_req}" "none"
none_req=$(classify_status_checks "${CC_ROLLUP}" '[]' required)
assert_contains "protected branch with contexts:[] blocks on nothing" \
  "${none_req}" "none"

echo
echo "=== control: the classifier is actually running ==="
# If classify_status_checks silently returned empty, several assert_not_contains
# above would pass for the wrong reason.
if [[ -n "${req}" ]] && printf '%s' "${req}" | grep -q 'claude-review'; then
  printf 'PASS: control -- classifier produced real output\n'
  pass=$((pass + 1))
else
  printf 'FAIL: control -- classifier produced no usable output\n'
  fail=$((fail + 1))
fi

echo
echo "======================================="
printf 'Results: %d passed, %d failed\n' "${pass}" "${fail}"
echo "======================================="
[[ "${fail}" -eq 0 ]]
