#!/usr/bin/env bash
# Hook: Block commands that would print a live secret into the transcript.
#
# Two distinct leak shapes, measured across 9 transcript files (12 hits):
#
#   1. The secret's VALUE appears literally in the command text.
#      e.g. `GH_TOKEN="ghp_real..." gh api user`
#
#   2. The command text is clean, but the shell EXPANDS a secret when it runs.
#      e.g. `echo "${GH_TOKEN:-NO}"` -- the `:-` fallback prints the value
#      when the variable IS set. This is the shape that leaked GH_TOKEN twice
#      in two weeks, and no scan of the command text alone can catch it.
#
# Why not a token-pattern regex (`ghp_[A-Za-z0-9]{36}` and friends): measured
# against real transcripts it catches only shape 1, and most of its hits are
# FAKE fixture tokens in test files -- false positives on exactly the code that
# exists to test this. Matching the live environment's actual values has no
# such failure mode: a fixture token is not in the environment, so it cannot
# match.
#
# This hook must run BEFORE the command does. A PostToolUse hook cannot help:
# its exit code is non-blocking and the output is already in the transcript by
# the time it sees it. There is no un-leaking.
#
# Exit 0 = allow, exit 2 = block (PreToolUse contract).

set -euo pipefail

input=$(cat)
cmd=$(printf '%s\n' "${input}" | jq -r '.tool_input.command // empty')

[[ -n "${cmd}" ]] || exit 0

# The detector needs the live environment to compare against, so it runs as a
# child of this hook (which the Bash tool invokes with the same env the command
# would get). The command text is passed on stdin, never as an argument -- an
# argument would be visible in `ps` to any local process.
verdict=$(printf '%s' "${cmd}" | python3 "$(dirname "${BASH_SOURCE[0]}")/hook-block-secret-leak.py") || {
  # Detector failure must not wedge every Bash call, but it must not be silent
  # either -- a guard that quietly stops guarding is the worst outcome. Exit 1
  # is non-blocking (the command still runs) AND surfaces stderr, unlike exit 0
  # whose stderr is discarded.
  printf '⚠️  secret-leak hook: detector failed to run; command allowed UNCHECKED.\n' >&2
  printf '   Secrets in this command would not have been caught.\n' >&2
  exit 1
}

[[ -n "${verdict}" ]] || exit 0

# Log the variable NAME and a short hash of the value -- never the value.
# hook-block-no-verify.sh logs the full command; copying that idiom here would
# write the secret to disk on every block, turning the guard into a new leak.
while IFS=$'\t' read -r varname _label; do
  [[ -n "${varname}" ]] || continue
  printf '%s BLOCKED SECRET LEAK: var=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${varname}" \
    >>"${HOME}/.claude/blocked-commands.log" || true
done <<<"${verdict}"

printf '🛑 BLOCKED: this command would print a live secret into the transcript.\n' >&2
printf '\n' >&2
while IFS=$'\t' read -r varname label; do
  [[ -n "${varname}" ]] || continue
  printf '  %-32s %s\n' "${varname}" "${label}" >&2
done <<<"${verdict}"
printf '\n' >&2
printf 'A transcript is durable. Once a secret is written to one, rotating it is\n' >&2
printf 'the only remedy -- so this is blocked before it runs, not after.\n' >&2
printf '\n' >&2
printf 'To check whether a variable is set, use a form that cannot print it:\n' >&2
# `D` holds a dollar sign so these examples can be written without single
# quotes; they are documentation text and must never be expanded.
D='$'
printf '  %s        marker only, never the value\n' "${D}{VAR:+SET}" >&2
printf '  %s            length only\n' "${D}{#VAR}" >&2
printf '  %s    test only\n' "[[ -n \"${D}VAR\" ]]" >&2
printf '\n' >&2
printf 'To list variable NAMES without their values:\n' >&2
printf "  env | cut -d= -f1\n" >&2
printf '\n' >&2
printf 'If you genuinely need the value, ask the human to read it from 1Password.\n' >&2
exit 2
