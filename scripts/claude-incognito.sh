#!/usr/bin/env bash

# ~/Developer/claude-config/scripts/claude-incognito.sh
# One-shot `claude -p` run that leaves no local session trace: no transcript
# under ~/.claude/projects, no /resume entry, no history.jsonl line.
#
# Installed on PATH as ~/.local/bin/claude-incognito by install.sh.
#
# HOW
# ---
# `--no-session-persistence` stops claude from writing the transcript and the
# history entry, but it only works with --print/-p, so this is a print-mode
# wrapper and nothing else. Even with that flag, claude still creates an empty
# ${CLAUDE_CONFIG_DIR:-~/.claude}/session-env/<session-id>/ directory. Passing
# our own --session-id tells us exactly which directory that is, so the EXIT
# trap can remove it.
#
# The cleanup is deliberately `rmdir`, never `rm -rf`: if claude ever starts
# putting files there, deleting them silently would hide the change. A
# non-empty directory is left in place and named on stderr instead.
#
# All user arguments are passed to `claude -p` verbatim, as separate args.
#
# PERMISSIONS
# -----------
# Print mode has nobody to answer a permission prompt, so in the default mode
# every tool call that would prompt (MCP tools included) is denied. The model
# then tends to misreport that as "needs authentication". Unless the caller
# passes --permission-mode or --dangerously-skip-permissions, this wrapper
# adds `--permission-mode bypassPermissions`, the same as the `clauded` alias.
# PreToolUse hooks still run in that mode.
#
# CONNECTORS
# ----------
# In print mode the claude.ai Slack connector and the Slack plugin's MCP
# server suppress each other as duplicates, so neither loads (claude 2.1.281,
# visible in --debug-file output). Turning claude.ai connectors off keeps the
# plugin server. The cost is the claude.ai-only connectors (Claude Docs).
# Set ENABLE_CLAUDEAI_MCP_SERVERS=true to get them back and lose Slack.
#
# CLAUDE_BIN overrides the claude binary (default: claude). Tests use it to
# substitute a stub.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: claude-incognito [claude -p args...] "prompt"
       echo "prompt" | claude-incognito [claude -p args...]

Runs `claude -p --no-session-persistence` with a throwaway session id and
removes the empty session-env directory afterwards, so the run leaves no
transcript, no /resume entry, and no history.jsonl entry.

Print mode only. Every argument is passed through to `claude -p`.

Runs with --permission-mode bypassPermissions unless you pass
--permission-mode or --dangerously-skip-permissions yourself.
Sets ENABLE_CLAUDEAI_MCP_SERVERS=false unless already set, so the Slack
plugin loads; set it to true to keep claude.ai connectors instead.
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  *) ;;
esac

# With no args and a terminal on stdin there is no prompt at all; claude -p
# would sit waiting for input. Piped stdin is a real prompt, so let it through.
if [[ $# -eq 0 && -t 0 ]]; then
  usage >&2
  exit 2
fi

sid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
session_env_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/session-env/${sid}"

cleanup() {
  # Every command here is guarded: an unguarded failure inside an EXIT trap
  # under `set -e` would replace claude's exit code with the trap's.
  if [[ -d "${session_env_dir}" ]]; then
    if ! rmdir "${session_env_dir}" 2>/dev/null; then
      printf 'claude-incognito: session-env directory not empty, left in place: %s\n' \
        "${session_env_dir}" >&2 || true
    fi
  fi
}
# The trap covers interrupts and errexit. The normal path below disarms it and
# calls cleanup directly, so cleanup runs exactly once either way.
trap cleanup EXIT

perm_args=(--permission-mode bypassPermissions)
for arg in "$@"; do
  case "${arg}" in
    --permission-mode | --permission-mode=* | --dangerously-skip-permissions)
      perm_args=()
      break
      ;;
    *) ;;
  esac
done

export ENABLE_CLAUDEAI_MCP_SERVERS="${ENABLE_CLAUDEAI_MCP_SERVERS:-false}"

rc=0
"${CLAUDE_BIN:-claude}" -p --no-session-persistence --session-id "${sid}" \
  "${perm_args[@]}" "$@" || rc=$?
trap - EXIT
cleanup
exit "${rc}"
