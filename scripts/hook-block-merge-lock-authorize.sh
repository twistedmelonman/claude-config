#!/usr/bin/env bash
# Hook: Block Bash execution of "merge-lock.sh authorize"
# Merge authorization is a human-only action.
#
# The Write/Edit hooks already block direct file writes to merge-locks/.
# This hook blocks the higher-level authorization command via the Bash tool.
#
# Both spellings are matched. `merge-lock` without the extension is the
# symlink installed at ~/.local/bin/merge-lock, and it is the form a human
# actually types; matching only `merge-lock.sh` left the shorter name as an
# unguarded path to the same script.
#
# `enroll` is blocked for the same reason as `authorize`: it adds a public key
# whose holder can then mint authorizations, so enrolling a key the agent
# generated would hand the agent exactly the power this hook withholds.
#
# `redeem` is deliberately NOT blocked. It consumes a token the human signed
# on another device, and the agent cannot forge one without the private key.
# There, the signature is the security boundary; blocking the command would
# only break the courier step that makes mobile authorization work (#509).

set -euo pipefail

input=$(cat)
cmd=$(printf '%s\n' "$input" | jq -r '.tool_input.command // empty')

# `tui` is blocked for the same reason: it grants locks through the same
# authorize_batch call, and piped stdin drives its selection without a
# terminal, so it needs no TTY to be driven by an agent.
if printf '%s\n' "$cmd" | grep -qE 'merge-lock(\.sh)?[[:space:]]+(authorize|auth|enroll|tui)([[:space:]]|$)'; then
  printf '%s BLOCKED MERGE-LOCK AUTHORIZE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "$cmd" >>"${HOME}/.claude/blocked-commands.log" || true
  printf '🛑 BLOCKED: merge-lock.sh authorize is a human-only action.\n' >&2
  printf '\n' >&2
  printf 'Merge authorization must be granted by the human, not Claude.\n' >&2
  printf 'Ask the human to run: ~/.claude/hooks/merge-lock.sh authorize <PR> "<reason>"\n' >&2
  printf '\n' >&2
  printf 'If the human is away from the laptop, they can sign a token on their\n' >&2
  printf 'phone and paste it back; you may then run:\n' >&2
  printf '  ~/.claude/hooks/merge-lock.sh redeem <token>\n' >&2
  exit 2
fi
