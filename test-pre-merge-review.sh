#!/usr/bin/env bash
# Test classification functions for pre-merge-review.sh

set -euo pipefail

# Source the script to get access to functions
# Note: We need to prevent execution of the main script logic
# We'll source functions by temporarily disabling the main execution

# Colors for test output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

# Test helper
assert_true() {
  local description="$1"
  shift
  if "$@"; then
    echo -e "${GREEN}✓${NC} ${description}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗${NC} ${description}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_false() {
  local description="$1"
  shift
  if ! "$@"; then
    echo -e "${GREEN}✓${NC} ${description}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗${NC} ${description}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# Source just the function definitions we need
# Extract and evaluate the function definitions without executing the main script.
#
# End-marker for the Diff Summarization block is `# --- Non-Blocking Issue Functions`
# (NOT `# --- Preflight`) so the eval does NOT pull in the lines that follow —
# specifically the `_LIB_DIR=... && source ${_LIB_DIR}/lib-review-issues.sh` block.
# Those lines resolve `${BASH_SOURCE[0]}` to THIS test script rather than the
# production hook, so the source failed with "No such file or directory".
# We source lib-review-issues.sh explicitly below with the correct absolute path
# so `is_security_critical` is available for the test block that uses it.
eval "$(sed -n '/^# --- File Classification Functions/,/^# --- Diff Summarization Functions/p' ~/.claude/hooks/pre-merge-review.sh | grep -v '^# ---' || true)"
eval "$(sed -n '/^# --- Diff Summarization Functions/,/^# --- Non-Blocking Issue Functions/p' ~/.claude/hooks/pre-merge-review.sh | grep -v '^# ---' || true)"
# shellcheck source=hooks/lib-review-issues.sh
source ~/.claude/hooks/lib-review-issues.sh

echo "Running pre-merge-review.sh function tests..."
echo ""

# Verify safe arithmetic patterns (set -e compatible)
echo "Verifying safe arithmetic patterns (set -e compatible):"
# Inspect only the text inside ((...)) / $((...)), not the whole line: a line
# like `log_error "git config --global ... $((X * 2))"` carries `--` as a CLI
# flag, which is not arithmetic. The pattern matches `((`, then any run that
# does not contain `))`, then `))`, so one level of inner parens such as
# `$(( (a + b) * 2 ))` is still captured.
# Limitations: an expression split across lines is not seen (grep is
# line-based), and with 2+ levels of nesting the match stops at the first `))`.
# Captured into a variable rather than piped into `grep -q`: under pipefail,
# `grep -q` exiting early can SIGPIPE the producer and turn a hit into a miss.
arith_exprs="$(grep -oE '\(\(([^)]|\)[^)])*\)\)' ~/.claude/hooks/pre-merge-review.sh || true)"
if grep -qE '\+\+|--|\+=' <<<"${arith_exprs}"; then
  echo -e "${RED}✗${NC} Found unsafe arithmetic operators (++, --, +=)"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo -e "${GREEN}✓${NC} Only safe VAR=\$((VAR + 1)) pattern used"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi
echo ""

# Test data file detection
echo "Testing is_data_file():"
assert_true "package-lock.json is a data file" is_data_file "package-lock.json"
assert_true "yarn.lock is a data file" is_data_file "yarn.lock"
assert_true "pnpm-lock.yaml is a data file" is_data_file "pnpm-lock.yaml"
assert_true "data.json is a data file" is_data_file "data.json"
assert_true "config.json is a data file" is_data_file "config.json"
assert_true "Gemfile.lock is a data file" is_data_file "Gemfile.lock"
assert_true "poetry.lock is a data file" is_data_file "poetry.lock"
assert_true "app.min.js is a data file" is_data_file "app.min.js"
assert_true "styles.min.css is a data file" is_data_file "styles.min.css"
assert_true "bundle.bundle.js is a data file" is_data_file "bundle.bundle.js"
assert_true "schema.generated.ts is a data file" is_data_file "schema.generated.ts"

assert_false "index.ts is NOT a data file" is_data_file "index.ts"
assert_false "app.js is NOT a data file" is_data_file "app.js"
assert_false "README.md is NOT a data file" is_data_file "README.md"
assert_false "component.tsx is NOT a data file" is_data_file "component.tsx"

echo ""

# Test security-critical file detection
echo "Testing is_security_critical():"
assert_true "src/auth/login.ts is security-critical" is_security_critical "src/auth/login.ts"
assert_true "lib/oauth/client.js is security-critical" is_security_critical "lib/oauth/client.js"
assert_true "api/jwt/verify.ts is security-critical" is_security_critical "api/jwt/verify.ts"
assert_true "models/password.ts is security-critical" is_security_critical "models/password.ts"
assert_true "services/session.ts is security-critical" is_security_critical "services/session.ts"
assert_true "controllers/login.ts is security-critical" is_security_critical "controllers/login.ts"
assert_true "components/register.tsx is security-critical" is_security_critical "components/register.tsx"
assert_true "api/payment/stripe.ts is security-critical" is_security_critical "api/payment/stripe.ts"
assert_true "services/billing.ts is security-critical" is_security_critical "services/billing.ts"
assert_true "lib/paypal/client.js is security-critical" is_security_critical "lib/paypal/client.js"
assert_true "handlers/checkout.ts is security-critical" is_security_critical "handlers/checkout.ts"
assert_true "models/transaction.ts is security-critical" is_security_critical "models/transaction.ts"
assert_true "db/migrations/001_users.sql is security-critical" is_security_critical "db/migrations/001_users.sql"
assert_true "database/schema.ts is security-critical" is_security_critical "database/schema.ts"
assert_true "models/user.ts is security-critical" is_security_critical "models/user.ts"
assert_true "lib/security/encrypt.ts is security-critical" is_security_critical "lib/security/encrypt.ts"
assert_true "utils/crypto.ts is security-critical" is_security_critical "utils/crypto.ts"
assert_true "services/encryption.ts is security-critical" is_security_critical "services/encryption.ts"
assert_true "config/secret.ts is security-critical" is_security_critical "config/secret.ts"
assert_true "lib/vault/client.ts is security-critical" is_security_critical "lib/vault/client.ts"

assert_false "src/utils/format.ts is NOT security-critical" is_security_critical "src/utils/format.ts"
assert_false "components/Button.tsx is NOT security-critical" is_security_critical "components/Button.tsx"
assert_false "lib/helpers/string.js is NOT security-critical" is_security_critical "lib/helpers/string.js"
assert_false "tests/format.test.ts is NOT security-critical" is_security_critical "tests/format.test.ts"

echo ""

# Test has_inline_comments (requires COMMENTED_FILES to be set)
echo "Testing has_inline_comments():"
# Export for use by has_inline_comments function
export COMMENTED_FILES="src/auth/login.ts
lib/utils/format.ts"

assert_true "src/auth/login.ts has comments" has_inline_comments "src/auth/login.ts"
assert_true "lib/utils/format.ts has comments" has_inline_comments "lib/utils/format.ts"
assert_false "src/components/Button.tsx has NO comments" has_inline_comments "src/components/Button.tsx"

echo ""

# Summary
echo "======================================"
echo "Test Results:"
echo -e "${GREEN}Passed: ${TESTS_PASSED}${NC}"
if [[ ${TESTS_FAILED} -gt 0 ]]; then
  echo -e "${RED}Failed: ${TESTS_FAILED}${NC}"
  exit 1
else
  echo "All tests passed!"
  exit 0
fi
