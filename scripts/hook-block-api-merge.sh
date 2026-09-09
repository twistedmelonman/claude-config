#!/usr/bin/env bash
# Hook: Block direct REST API calls to the GitHub PR merge endpoint
#
# Purpose:
#   The gh() wrapper in ~/.config/bash/functions.sh intercepts `gh pr merge`
#   and routes it through pre-merge-review.sh + merge-lock authorization.
#   However, `gh api .../pulls/NNN/merge --method PUT` bypasses the wrapper
#   entirely, circumventing all code quality gates.
#
#   This hook closes that gap by blocking the merge endpoint at the Claude
#   Code PreToolUse layer, before any Bash command is executed.
#
# Root cause documented in post-mortems:
#   - PR #813: gh pr merge failed silently → gh api used as workaround
#   - v1.11.0: pattern reused → 9-second unauthorized production merge
#
# If gh pr merge fails: report the failure, ask the human to merge manually.
# NEVER use gh api .../merge as a workaround.
#
# Called by: hook-block-all.sh (PreToolUse Bash hook chain)

set -euo pipefail

input=$(cat)
cmd=$(printf '%s\n' "${input}" | jq -r '.tool_input.command // empty')

# Early-exempt: git commit/log/show/diff invocations without a chained gh
# call. Their arguments (commit messages, log output, diff text) may
# legitimately contain the literal patterns matched below — a commit
# message explaining that `gh api graphql --input` is blocked must be
# allowed. This hook can't separate command text from quoted argument
# text, so it relies on two conditions:
#   1. The primary verb is git (commit|log|show|diff) at cmd start.
#   2. No gh invocation appears after a shell-operator boundary — start
#      of command, ; & |, or the command-substitution openers ( and `.
#      A literal mention of gh inside quoted text is not preceded by
#      any of these, so it doesn't trigger the guard, but $(gh ...) or
#      `gh ...` substitution does (and must still be blocked).
# Net: `git commit -m "... gh api ..."` is exempted, but
# `git diff && gh api .../merge` is NOT (the gh after && is a real call).
# `git diff` followed by a literal-newline-chained `gh api .../merge` (no
# leading shell operator on its own line) is ALSO not exempted (#137): an
# unindented line 2+ that starts with `gh` is a real statement, not quoted
# argument text. Indented lines (e.g. inside a heredoc body) don't match,
# so the exemption for quoted commit-message text is preserved. Line 1 is
# excluded from this check (via `tail -n +2`) because for this exemption
# block the primary verb is `git`, not `gh`, so line 1 never legitimately
# starts with `gh` anyway — but excluding it keeps the check symmetric
# with the gh-pr|issue-create exemption below.
if printf '%s\n' "${cmd}" | grep -qE '^[[:space:]]*git[[:space:]]+(-[^[:space:]]+[[:space:]]+([^-][^|;&[:space:]]*[[:space:]]+)?)*(commit|log|show|diff)([[:space:]]|$)' \
  && ! printf '%s\n' "${cmd}" | grep -qE '[;&|(`][[:space:]]*gh[[:space:]]+' \
  && ! printf '%s\n' "${cmd}" | tail -n +2 | grep -qE '^gh[[:space:]]+'; then
  exit 0
fi

# Early-exempt: gh pr|issue create|edit|comment invocations whose text args
# (--body, --title, --message) may legitimately contain trigger patterns
# (discovered during Batch D — I had to reword a PR body to avoid false-
# positive on the literal gh api graphql --input mention). Fires only when:
#   1. The primary verb is gh (pr|issue) (create|edit|comment), with optional
#      interposed flags (-R owner/repo, --repo owner/repo, etc.) between gh
#      and the subcommand.
#   2. No OTHER gh call appears after a shell-operator boundary (; & | ( `).
#      The leading gh is at command start and is not preceded by an operator,
#      so only chained follow-on gh calls match the negation regex.
# Net: `gh pr create --body "... gh api graphql --input ..."` is exempted,
# but `gh pr create --body "..." && gh api .../merge` is NOT.
# `gh pr create ...` followed by a literal-newline-chained `gh api .../merge`
# is ALSO not exempted (#137). Line 1 (the primary `gh pr|issue ...`
# invocation itself, which legitimately starts with `gh`) is excluded from
# the unindented-line check via `tail -n +2`, so only genuine follow-on
# lines starting with `gh` at column 0 trip the negation.
if printf '%s\n' "${cmd}" | grep -qE '^[[:space:]]*gh[[:space:]]+(-[^[:space:]]+[[:space:]]+([^-][^|;&[:space:]]*[[:space:]]+)?)*(pr|issue)[[:space:]]+(create|edit|comment)([[:space:]]|$)' \
  && ! printf '%s\n' "${cmd}" | grep -qE '[;&|(`][[:space:]]*gh[[:space:]]+' \
  && ! printf '%s\n' "${cmd}" | tail -n +2 | grep -qE '^gh[[:space:]]+'; then
  exit 0
fi

# COMMAND-POSITION ANCHOR (claude-config#405). The four api matchers below
# require the tool name at a command position -- start of line, or
# immediately after a shell operator, backtick, or command substitution --
# rather than anywhere in the string. `^` covers the line case on its own:
# grep matches per line and the command is piped through printf '%s\n'.
# Without it the endpoint matched inside a quoted argument being written to
# a file, so writing a test fixture for this hook was blocked by this hook.
# Same idiom the pr-merge matcher further down already used.
#
# KNOWN GAP, accepted: a heredoc body starts at a line boundary, so a
# heredoc containing the endpoint still matches. Distinguishing a heredoc
# body from a command needs real tokenization, which a PreToolUse hook
# operating on an unexpanded string cannot do. This is the same
# regex-is-not-a-shell-parser limit recorded for the false-NEGATIVE
# direction in #349, and it fails safe: the cost is a blocked write, not a
# permitted merge.
# Block: gh api .../pulls/{number}/merge  (REST endpoint)
# Suffix boundary ([[:space:]]|$|[^[:alnum:]_]) prevents false positives on
# hypothetical paths like pulls/NNN/merge_status while still matching:
#   gh api repos/owner/repo/pulls/123/merge --method PUT
#   gh api /repos/owner/repo/pulls/123/merge
#   gh api "repos/owner/repo/pulls/123/merge"
#   echo x && gh api repos/o/r/pulls/1/merge --method PUT
if printf '%s\n' "${cmd}" | grep -qE '(^|&&[[:space:]]*|\|\|[[:space:]]*|;[[:space:]]*|[|&][[:space:]]*|\`|\$\()[[:space:]]*gh[[:space:]]+(-[^[:space:]]+[[:space:]]+([^-][^|;&[:space:]]*[[:space:]]+)?)*api[[:space:]].*pulls/[0-9]+/merge([[:space:]]|$|[^[:alnum:]_])'; then
  printf '%s BLOCKED API MERGE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log" || true
  printf '🛑 BLOCKED: Direct REST API PR merge bypasses code quality gates.\n' >&2
  printf '\n' >&2
  printf 'This endpoint skips pre-merge review and merge authorization.\n' >&2
  printf '\n' >&2
  printf "Use \`gh pr merge <number>\` instead — it routes through pre-merge-review.sh.\n" >&2
  printf '\n' >&2
  printf 'If gh pr merge is failing, report the failure and ask the human to merge manually.\n' >&2
  printf 'Do NOT use the REST API as a workaround.\n' >&2
  exit 2
fi

# Block: gh api graphql with mergePullRequest mutation
# GraphQL offers the same merge capability as the REST endpoint above.
# Covers inline mutations passed via -f query=... or --field query=...
if printf '%s\n' "${cmd}" | grep -qE '(^|&&[[:space:]]*|\|\|[[:space:]]*|;[[:space:]]*|[|&][[:space:]]*|\`|\$\()[[:space:]]*gh[[:space:]]+(-[^[:space:]]+[[:space:]]+([^-][^|;&[:space:]]*[[:space:]]+)?)*api[[:space:]].*graphql.*mergePullRequest'; then
  printf '%s BLOCKED GRAPHQL MERGE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log" || true
  printf '🛑 BLOCKED: GraphQL mergePullRequest mutation bypasses code quality gates.\n' >&2
  printf '\n' >&2
  printf "Use \`gh pr merge <number>\` instead — it routes through pre-merge-review.sh.\n" >&2
  printf '\n' >&2
  printf 'If gh pr merge is failing, report the failure and ask the human to merge manually.\n' >&2
  exit 2
fi

# Block: gh api graphql --input (any form)
# --input reads the GraphQL mutation from a file or stdin, so the command-line
# scanners above cannot inspect the mutation body. Since the only reason to
# use --input for Claude-initiated gh calls is to hide the payload from
# linting, block this pattern unconditionally. Legitimate data queries
# rarely need --input; they can be expressed inline via -f query=.
# Previously documented as a known gap (Protocol 6 in CLAUDE.md) — now closed.
if printf '%s\n' "${cmd}" | grep -qE '(^|&&[[:space:]]*|\|\|[[:space:]]*|;[[:space:]]*|[|&][[:space:]]*|\`|\$\()[[:space:]]*gh[[:space:]]+(-[^[:space:]]+[[:space:]]+([^-][^|;&[:space:]]*[[:space:]]+)?)*api[[:space:]].*graphql.*(--input([[:space:]=]|$)|(-F|--field)[[:space:]=]*input)'; then
  printf '%s BLOCKED GRAPHQL --input: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log" || true
  printf '🛑 BLOCKED: gh api graphql --input reads the mutation from a file,\n' >&2
  printf '   hiding its contents from the command-line merge-bypass scanners.\n' >&2
  printf '\n' >&2
  printf "If you are trying to merge a PR, use \`gh pr merge <number>\` instead.\n" >&2
  printf 'If you need a legitimate GraphQL query, pass it inline via -f query=.\n' >&2
  printf 'If gh pr merge is failing, report the failure and ask the human to merge manually.\n' >&2
  exit 2
fi

# Block: gh api graphql with -f/-F/--field name=@file  (value-from-file)
# gh'"'"'s @<filename> convention for -f / --field reads the value from a file,
# which lets a mutation body live on disk and still get executed. Covers the
# gap left by the --input check above. Issue #133.
if printf '%s\n' "${cmd}" | grep -qE '(^|&&[[:space:]]*|\|\|[[:space:]]*|;[[:space:]]*|[|&][[:space:]]*|\`|\$\()[[:space:]]*gh[[:space:]]+(-[^[:space:]]+[[:space:]]+([^-][^|;&[:space:]]*[[:space:]]+)?)*api[[:space:]].*graphql.*(-[fF]|--field)[[:space:]=]*(query|mutation)[[:space:]]*=[[:space:]]*@'; then
  printf '%s BLOCKED GRAPHQL @file: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log" || true
  printf '🛑 BLOCKED: gh api graphql with -f/-F query=@<file> (or mutation=@<file>)\n' >&2
  printf '   reads the payload body from a file via gh'"'"'s @<filename> convention,\n' >&2
  printf '   hiding its contents from the command-line merge-bypass scanners.\n' >&2
  printf '\n' >&2
  printf "If you are trying to merge a PR, use \`gh pr merge <number>\` instead.\n" >&2
  printf 'If you need a legitimate GraphQL query, pass it inline via -f query=<body> (no @).\n' >&2
  printf 'If gh pr merge is failing, report the failure and ask the human to merge manually.\n' >&2
  exit 2
fi

# Block: gh [global-flags] pr merge (global-flag prefix bypass)
# When global flags like -R/--repo appear before the subcommand, the gh() bash
# wrapper's positional check ($1=='pr' && $2=='merge') is skipped entirely,
# allowing a merge without pre-merge review or merge-lock authorization.
#
# The leading anchor requires 'gh' to appear at the start of a line or after an
# explicit shell operator (&&, ||, ;, |, &), so 'gh -R' text embedded in commit
# messages or quoted strings does not produce false positives.
# Operators are matched explicitly (&&, ||) or as single characters (;, |, &)
# to avoid the brittleness of relying on accidental single-character matching.
if printf '%s\n' "${cmd}" | grep -qE '(^|&&[[:space:]]*|\|\|[[:space:]]*|;[[:space:]]*|[|&][[:space:]]*)gh[[:space:]]+-[^[:space:]].*[[:space:]]pr[[:space:]]+merge([[:space:]]|$)'; then
  printf '%s BLOCKED GLOBAL FLAG MERGE BYPASS: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log" || true
  printf '🛑 BLOCKED: gh pr merge with global flags (e.g. -R repo) bypasses shell wrapper routing.\n' >&2
  printf '\n' >&2
  printf 'Placing global flags before the subcommand skips pre-merge review and merge authorization.\n' >&2
  printf '\n' >&2
  printf "Use \`gh pr merge <number>\` (no global flags before the subcommand) instead.\n" >&2
  printf '\n' >&2
  printf 'If gh pr merge is failing, report the failure and ask the human to merge manually.\n' >&2
  printf 'Do NOT use global flag placement as a workaround.\n' >&2
  exit 2
fi
