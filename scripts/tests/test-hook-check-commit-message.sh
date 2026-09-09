#!/usr/bin/env bash
# Tests for hook-check-commit-message.py

set -euo pipefail
unset CDPATH

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hook-check-commit-message.py"
pass=0
fail=0

check() {
  local desc="${1}" expected="${2}" input="${3}" actual=0
  printf '%s\n' "${input}" | "${HOOK}" >/dev/null 2>&1 || actual=$?
  if [[ "${actual}" -eq "${expected}" ]]; then
    echo "  PASS: ${desc}"
    ((pass += 1))
  else
    echo "  FAIL: ${desc} (expected exit ${expected}, got ${actual})"
    ((fail += 1))
  fi
}

make_input() {
  jq -n --arg cmd "$1" '{"tool_input":{"command":$cmd}}'
}

echo "=== hook-check-commit-message tests ==="

# === VALID messages — should PASS (exit 0) ===
inp="$(make_input 'git commit -m "feat: add login"')"
check "Valid: feat: add login" 0 "${inp}"
inp="$(make_input 'git commit -m "fix(api): null check"')"
check "Valid: fix(api): null check" 0 "${inp}"
inp="$(make_input 'git commit -m "feat!: breaking change"')"
check "Valid: feat!: breaking change" 0 "${inp}"
inp="$(make_input 'git commit -m "feat(api)!: scoped breaking"')"
check "Valid: feat(api)!: scoped breaking" 0 "${inp}"
inp="$(make_input 'git commit -m "chore(deps)!: upgrade major"')"
check "Valid: chore(deps)!: upgrade major" 0 "${inp}"
inp="$(make_input "git commit -m 'docs: update README'")"
check "Valid: single-quoted docs: update README" 0 "${inp}"

# Heredoc form (what Claude Code typically uses for multi-line messages)
heredoc_cmd="git commit -m \"\$(cat <<'EOF'
feat(hook): extend gh api scan

Longer description in body.
EOF
)\""
inp="$(make_input "${heredoc_cmd}")"
check "Valid: heredoc with conventional-commits summary" 0 "${inp}"

heredoc_bad="git commit -m \"\$(cat <<'EOF'
not a conventional message
body text
EOF
)\""
inp="$(make_input "${heredoc_bad}")"
check "Blocked: heredoc with malformed summary" 2 "${inp}"

# Git with interposed flags
inp="$(make_input 'git -C /path commit -m "fix: path-commit"')"
check "Valid: git -C /path commit -m" 0 "${inp}"
inp="$(make_input 'git --no-pager commit -m "chore: no-pager commit"')"
check "Valid: git --no-pager commit -m" 0 "${inp}"

# --message long form
inp="$(make_input 'git commit --message "feat: long-flag form"')"
check "Valid: --message long form" 0 "${inp}"
inp="$(make_input 'git commit --message="feat: equals form"')"
check "Valid: --message=VALUE equals form" 0 "${inp}"

# === MALFORMED messages — should BLOCK (exit 2) ===
inp="$(make_input 'git commit -m "fix something without colon"')"
check "Blocked: missing colon / type" 2 "${inp}"
inp="$(make_input 'git commit -m "FEAT: uppercase type"')"
check "Blocked: uppercase type" 2 "${inp}"
inp="$(make_input 'git commit -m "random summary line"')"
check "Blocked: no conventional prefix" 2 "${inp}"
inp="$(make_input 'git commit -m "feat:"')"
check "Blocked: empty description" 2 "${inp}"
inp="$(make_input 'git commit -m "Feat(api): capital type"')"
check "Blocked: capitalized type" 2 "${inp}"
inp="$(make_input 'git commit -m "feat: "')"
check "Blocked: only whitespace description" 2 "${inp}"

# === NOT a git commit — should PASS (exit 0) ===
inp="$(make_input 'git status')"
check "Pass-through: git status" 0 "${inp}"
inp="$(make_input 'git commit')"
check "Pass-through: git commit (editor mode, no -m)" 0 "${inp}"
inp="$(make_input 'echo "feat: not a commit"')"
check "Pass-through: echo with conventional-looking text" 0 "${inp}"
inp="$(make_input 'git log --oneline')"
check "Pass-through: git log" 0 "${inp}"
inp="$(make_input 'npm run commit -- -m "feat: via npm"')"
check "Pass-through: npm run (not git commit)" 0 "${inp}"

# === AMBIGUOUS — should PASS (fail-open, let commit-msg gate) ===
# Command substitution that isn't a heredoc: can't extract cleanly.
inp="$(make_input "git commit -m \"\$(some_command_without_heredoc)\"")"
check "Fail-open: \$(cmd) without heredoc" 0 "${inp}"
inp="$(make_input "git commit -m \"\`some_backtick_sub\`\"")"
check "Fail-open: backtick substitution" 0 "${inp}"

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
