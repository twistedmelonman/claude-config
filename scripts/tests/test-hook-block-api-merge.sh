#!/usr/bin/env bash
# Tests for hook-block-api-merge.sh

set -euo pipefail
unset CDPATH

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hook-block-api-merge.sh"
pass=0
fail=0

check() {
  local desc="${1}" expected="${2}" input="${3}" actual
  actual=0
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

echo "=== hook-block-api-merge tests ==="

# REST API merge bypass — should BLOCK (exit 2)
inp="$(make_input 'gh api repos/owner/repo/pulls/123/merge --method PUT')"
check "REST: gh api .../pulls/N/merge --method PUT" 2 "${inp}"
inp="$(make_input 'gh api /repos/owner/repo/pulls/123/merge')"
check "REST: gh api /repos/.../merge (leading slash)" 2 "${inp}"
inp="$(make_input 'echo x && gh api repos/o/r/pulls/1/merge')"
check "REST: chained && gh api .../merge" 2 "${inp}"

# GraphQL mergePullRequest inline — should BLOCK (exit 2)
inp="$(make_input 'gh api graphql -f query="mutation { mergePullRequest(input: {pullRequestId: \"PR_abc\"}) { pullRequest { id } } }"')"
check "GraphQL: inline mergePullRequest mutation" 2 "${inp}"

# GraphQL --input bypass — should BLOCK (exit 2)
inp="$(make_input 'gh api graphql --input /tmp/mutation.json')"
check "GraphQL: --input <file>" 2 "${inp}"
inp="$(make_input 'gh api graphql --input=/tmp/mutation.json')"
check "GraphQL: --input=<file> (equals form)" 2 "${inp}"
inp="$(make_input 'gh api graphql --input -')"
check "GraphQL: --input - (stdin)" 2 "${inp}"
inp="$(make_input 'gh api graphql -F input=@mutation.json')"
check "GraphQL: -F input=@file (equivalent form)" 2 "${inp}"
inp="$(make_input 'gh api graphql --field input=@mutation.json')"
check "GraphQL: --field input=@file (long form of -F)" 2 "${inp}"
inp="$(make_input 'gh api graphql --field=input=@mutation.json')"
check "GraphQL: --field=input=@file (equals long form)" 2 "${inp}"

# -f/--field query=@file (value-from-file convention) — blocks (#133)
inp="$(make_input 'gh api graphql -f query=@mutation.txt')"
check "GraphQL: -f query=@file (value-from-file)" 2 "${inp}"
inp="$(make_input 'gh api graphql -F query=@mutation.txt')"
check "GraphQL: -F query=@file (value-from-file)" 2 "${inp}"
inp="$(make_input 'gh api graphql --field query=@mutation.txt')"
check "GraphQL: --field query=@file (long form)" 2 "${inp}"
inp="$(make_input 'gh api graphql -f mutation=@body.txt')"
check "GraphQL: -f mutation=@file (alternate field name)" 2 "${inp}"

# Negative: -f query=inline body (no @) must NOT trigger
inp="$(make_input 'gh api graphql -f query=query{viewer{login}}')"
check "GraphQL: inline -f query= body (no @) not blocked" 0 "${inp}"
inp="$(make_input 'cat mutation.json | gh api graphql --input -')"
check "GraphQL: piped to --input -" 2 "${inp}"

# Global-flag bypass — should BLOCK (exit 2)
inp="$(make_input 'gh -R owner/repo pr merge 123')"
check "Global flag: gh -R owner/repo pr merge" 2 "${inp}"
inp="$(make_input 'gh --repo owner/repo pr merge 123 --squash')"
check "Global flag: gh --repo owner/repo pr merge" 2 "${inp}"

# Global-flag-prefix api-merge bypass — the api-merge regexes previously
# required `gh api` to be adjacent; `gh --repo=... api .../merge` sailed
# past all four checks. Now each pattern accepts optional flag tokens
# between gh and api. Flagged by Seer on PR #136; the claim was misattributed
# to the exemption but digging uncovered this real gap.
inp="$(make_input 'gh --repo=o/r api repos/o/r/pulls/1/merge --method PUT')"
check "Global-flag-api: gh --repo=o/r api .../merge (equals)" 2 "${inp}"
inp="$(make_input 'gh --repo o/r api repos/o/r/pulls/1/merge')"
check "Global-flag-api: gh --repo o/r api .../merge (space)" 2 "${inp}"
inp="$(make_input 'gh -R o/r api repos/o/r/pulls/1/merge')"
check "Global-flag-api: gh -R o/r api .../merge" 2 "${inp}"
inp="$(make_input 'gh --repo=o/r api graphql -f query=@m.txt')"
check "Global-flag-api: gh --repo=o/r api graphql @file" 2 "${inp}"
inp="$(make_input 'gh --repo=o/r api graphql --input /tmp/m.json')"
check "Global-flag-api: gh --repo=o/r api graphql --input" 2 "${inp}"
inp="$(make_input 'gh --hostname github.com -R o/r api repos/o/r/pulls/1/merge')"
check "Global-flag-api: multiple flags then api merge" 2 "${inp}"

# Legitimate uses — should PASS (exit 0)
inp="$(make_input 'gh api repos/owner/repo/pulls/123')"
check "REST: gh api .../pulls/N (no /merge)" 0 "${inp}"
inp="$(make_input 'gh api repos/owner/repo/pulls/123/comments')"
check "REST: gh api .../pulls/N/comments" 0 "${inp}"
inp="$(make_input 'gh api graphql -f query="query { viewer { login } }"')"
check "GraphQL: inline query (no mergePullRequest, no --input)" 0 "${inp}"
inp="$(make_input 'gh pr merge 123 --squash --delete-branch')"
check "Legit: gh pr merge (no global flags, routes through wrapper)" 0 "${inp}"
inp="$(make_input 'gh pr list')"
check "Legit: gh pr list" 0 "${inp}"
inp="$(make_input 'gh api user')"
check "Legit: gh api user" 0 "${inp}"

# git commit/log/show/diff exemption: literal patterns in commit messages or
# diff/log text must NOT trigger the block. The hook can't distinguish "command
# text" from "quoted argument text", so these verbs are early-exempted.
inp="$(make_input 'git commit -m "explain gh api graphql --input block"')"
check "Exempt: git commit -m with trigger text" 0 "${inp}"
inp="$(make_input 'git commit -m "describes gh api .../pulls/1/merge pattern"')"
check "Exempt: git commit -m with REST merge text" 0 "${inp}"
inp="$(make_input 'git log --oneline -5')"
check "Exempt: git log" 0 "${inp}"
inp="$(make_input 'git show HEAD')"
check "Exempt: git show" 0 "${inp}"
inp="$(make_input 'git diff main...HEAD')"
check "Exempt: git diff" 0 "${inp}"

# Negative: chained git diff && gh api ... must still block gh, since the
# exemption only applies when git is the leading verb.
inp="$(make_input 'git diff && gh api repos/o/r/pulls/1/merge')"
check "Not exempt: chained git diff && gh api merge" 2 "${inp}"

# Negative: command substitution $(gh ...) or `gh ...` inside a git commit -m
# still invokes gh at runtime — exemption must NOT fire.
inp="$(make_input "git commit -m \"\$(gh api repos/o/r/pulls/1/merge --method PUT)\"")"
check "Not exempt: git commit -m \"\$(gh api .../merge)\"" 2 "${inp}"
inp="$(make_input "git commit -m \"\`gh api repos/o/r/pulls/1/merge\`\"")"
check "Not exempt: git commit -m \"\`gh api .../merge\`\"" 2 "${inp}"

# Negative: --input anchor boundary — must not false-match future --input-format
# style flags that happen to start with --input.
inp="$(make_input 'gh api graphql --input-format json -f query=q')"
check "Not blocked: --input-format (hypothetical future flag)" 0 "${inp}"

# Exempt: interposed git flags (-C, -c, --no-pager, etc.) before the verb.
# These forms are normal git usage and must still be exempted when the
# message text happens to contain a trigger pattern.
inp="$(make_input 'git -C /path commit -m "mentions gh api graphql --input"')"
check "Exempt: git -C /path commit -m with trigger text" 0 "${inp}"
inp="$(make_input 'git -c user.name=x commit -m "mentions gh api graphql --input"')"
check "Exempt: git -c key=value commit -m" 0 "${inp}"
inp="$(make_input 'git --no-pager log -5')"
check "Exempt: git --no-pager log" 0 "${inp}"
inp="$(make_input 'git -C /repo --no-pager show HEAD')"
check "Exempt: git -C /repo --no-pager show" 0 "${inp}"

# Regression: a multi-line heredoc body containing an indented gh api
# example line must not break the git-verb exemption. Previously the
# negation regex used `(^|[;&|(`])` and the `^` alternative matched at
# every line start in grep's multi-line mode, including body lines that
# happened to start with whitespace + gh. Now the negation only fires
# when a real shell-operator boundary precedes the gh call.
msg_at=$(printf 'feat: test\n\nExample:\n  gh api graphql -f query=%cmut.txt\n' 64)
cmd_multiline=$(printf "git -C /path commit -m \"\$(cat <<EOF\n%sEOF\n)\"" "${msg_at}")
inp="$(make_input "${cmd_multiline}")"
check "Exempt: git commit with indented gh api in heredoc body" 0 "${inp}"

# Exempt: gh (pr|issue) (create|edit|comment) with text args that legitimately
# mention trigger patterns.
inp="$(make_input 'gh pr create --title "feat" --body "mentions gh api graphql --input"')"
check "Exempt: gh pr create --body with trigger text" 0 "${inp}"
inp="$(make_input 'gh pr edit 42 --body "describes gh api .../pulls/1/merge"')"
check "Exempt: gh pr edit --body with REST merge text" 0 "${inp}"
inp="$(make_input 'gh issue create --title "track" --body "mentions gh api graphql --input"')"
check "Exempt: gh issue create --body with trigger text" 0 "${inp}"
inp="$(make_input 'gh pr comment 42 --body "discusses gh api graphql --input variant"')"
check "Exempt: gh pr comment --body with trigger text" 0 "${inp}"
inp="$(make_input 'gh --repo owner/name pr create --body "mentions gh api graphql --input"')"
check "Exempt: gh --repo <r> pr create with interposed flag" 0 "${inp}"

# Negative: gh pr create body is exempted BUT a chained gh api merge still blocks.
inp="$(make_input 'gh pr create --body "..." && gh api repos/o/r/pulls/1/merge')"
check "Not exempt: gh pr create && gh api merge chain" 2 "${inp}"
inp="$(make_input "gh pr create --body \"\$(gh api repos/o/r/pulls/1/merge)\"")"
check "Not exempt: gh pr create body with \$(gh api merge)" 2 "${inp}"

# Regression (#137): a literal-newline-chained gh api .../merge call must
# still be blocked even though it has no preceding shell-operator character
# on its own line. Previously the negation regex only fired on
# `[;&|(`]` immediately before gh, so `git diff\ngh api .../merge` slipped
# through the git-verb exemption (line 1 matches the primary verb check,
# line 2's unindented `gh api ...` has no operator prefix).
multiline_cmd="$(printf 'git diff\ngh api repos/o/r/pulls/1/merge --method PUT\n')"
inp="$(make_input "${multiline_cmd}")"
check "Not exempt (#137): newline-chained git diff / gh api merge" 2 "${inp}"

multiline_cmd2="$(printf 'git log --oneline -5\ngh api repos/o/r/pulls/1/merge\n')"
inp="$(make_input "${multiline_cmd2}")"
check "Not exempt (#137): newline-chained git log / gh api merge" 2 "${inp}"

# Same bypass shape for the gh pr|issue create exemption block.
multiline_cmd3="$(printf 'gh pr create --title t --body b\ngh api repos/o/r/pulls/1/merge\n')"
inp="$(make_input "${multiline_cmd3}")"
check "Not exempt (#137): newline-chained gh pr create / gh api merge" 2 "${inp}"

# Indented heredoc-body line must remain exempt (no false positive introduced).
# Reuses the pre-existing ${cmd_multiline} built above (line ~159, the
# "git commit with indented gh api in heredoc body" case) — not a new or
# undefined variable.
inp="$(make_input "${cmd_multiline}")"
check "Still exempt (#137 regression guard): indented heredoc gh api example" 0 "${inp}"

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
