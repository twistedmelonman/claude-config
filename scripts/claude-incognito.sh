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
# The session-env cleanup is deliberately `rmdir`, never `rm -rf`: if claude
# ever starts putting files there, deleting them silently would hide the
# change. A non-empty directory is left in place and named on stderr instead.
#
# Two other per-session directories do hold content, so they get `rm -rf`,
# matched only by our own session id:
#   ${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<cwd-slug>/<session-id>/
#     Large tool results spill to tool-results/ here even with
#     --no-session-persistence (a 65 KB Slack search did, claude 2.1.281).
#   ${CLAUDE_CODE_TMPDIR:-/tmp}/claude-<uid>/<cwd-slug>/<session-id>/
#     Per-session scratch and task output.
# The cwd slug is claude's internal encoding, so both are globbed as */<id>.
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
# visible in --debug-file output). Unless the caller passes --settings, this
# wrapper adds a --settings value that denies only the claude.ai Slack
# connector, so the plugin's Slack server loads and the other claude.ai
# connectors (Claude Docs) stay available. claude prints "claude.ai MCP server
# blocked by enterprise policy: claude.ai Slack" on stderr each run; that is
# the deny working. deniedMcpServers needs the {"serverName": ...} object
# form: a bare string is silently ignored (tested on 2.1.281).
#
# CLAUDE_BIN overrides the claude binary (default: claude). Tests use it to
# substitute a stub.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: claude-incognito [claude -p args...] "prompt"
       echo "prompt" | claude-incognito [claude -p args...]

Runs `claude -p --no-session-persistence` with a throwaway session id and
removes that session's session-env, spilled tool results, and tmp directory
afterwards, so the run leaves no transcript, no /resume entry, no
history.jsonl entry, and no tool output on disk.

Print mode only. Every argument is passed through to `claude -p`.

Runs with --permission-mode bypassPermissions unless you pass
--permission-mode or --dangerously-skip-permissions yourself.
Denies the claude.ai Slack connector with --settings unless you pass
--settings yourself, so the Slack plugin and Claude Docs both load. If you
pass --settings, include that deny in it to keep Slack.
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
# The rm -rf below is keyed on this value, so refuse anything but a full UUID.
if [[ ! "${sid}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  printf 'claude-incognito: uuidgen returned an unexpected value: %s\n' "${sid}" >&2
  exit 1
fi
config_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
session_env_dir="${config_dir}/session-env/${sid}"
tmp_root="${CLAUDE_CODE_TMPDIR:-/tmp}/claude-$(id -u)"

cleanup() {
  # Every command here is guarded: an unguarded failure inside an EXIT trap
  # under `set -e` would replace claude's exit code with the trap's.
  if [[ -d "${session_env_dir}" ]]; then
    if ! rmdir "${session_env_dir}" 2>/dev/null; then
      printf 'claude-incognito: session-env directory not empty, left in place: %s\n' \
        "${session_env_dir}" >&2 || true
    fi
  fi
  local d
  for d in "${config_dir}/projects/"*/"${sid}" "${tmp_root}/"*/"${sid}"; do
    if [[ -e "${d}" || -L "${d}" ]]; then
      if ! rm -rf -- "${d}" 2>/dev/null; then
        printf 'claude-incognito: could not remove: %s\n' "${d}" >&2 || true
      fi
    fi
  done
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

settings_args=(--settings '{"deniedMcpServers":[{"serverName":"claude.ai Slack"}]}')
for arg in "$@"; do
  case "${arg}" in
    --settings | --settings=*)
      settings_args=()
      break
      ;;
    *) ;;
  esac
done

rc=0
"${CLAUDE_BIN:-claude}" -p --no-session-persistence --session-id "${sid}" \
  "${perm_args[@]}" "${settings_args[@]}" "$@" || rc=$?
trap - EXIT
cleanup
exit "${rc}"
