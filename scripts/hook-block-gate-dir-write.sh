#!/usr/bin/env bash
# Keep the two approval directories agent-unwritable from the Bash tool.
#
#   ~/.claude/merge-locks/   merge authorization
#   ~/.claude/gate-review/   commit/PR text approval
#
# THE HOLE THIS CLOSES. hook-block-merge-locks-write.sh is registered for the
# Write and Edit matchers only, and reads tool_input.file_path. A Bash `cp`
# into merge-locks/ therefore carries no file_path at all and returned exit 0
# from the full dispatcher -- measured 2026-09-18 by piping a crafted payload
# to hook-block-all.sh, and reproduced before this file was written. That was a
# pre-existing hole in merge-lock, not one the gate introduced; both dirs are
# covered here for the same reason.
#
# WRITE-ONLY, DELIBERATELY. Reading from these dirs must pass. The whole
# intended workflow is `git commit -F ~/.claude/gate-review/approved/<name>`:
# the approved bytes are what commits, so a blanket ban on naming the path
# would block the one command the gate exists to permit. Only writes are
# matched.
#
# KNOWN LIMITATION -- READ BEFORE RELYING ON THIS AS A SECURITY BOUNDARY.
# This is a regex approximation of shell syntax, not a shell parser, and it is
# BYPASSABLE in the same ways as every other matcher here: aliases, shell
# functions, variable-spelled paths (`D=~/.claude; cp x $D/merge-locks/y`), and
# any writer not named below. Both locks are forcing functions, not
# cryptographic locks -- a point accepted when this design was chosen. The
# value is that the obvious path is closed and the log records attempts.
#
# Called by: hook-block-all.sh (PreToolUse Bash hook chain)

set -euo pipefail
unset CDPATH

input=$(cat)
cmd=$(printf '%s\n' "${input}" | jq -r '.tool_input.command // empty')

[[ -n "${cmd}" ]] || exit 0

# Both the literal home and the `~` spelling reach the same directory. The
# trailing `/` is required: without it the pattern also matches
# `scripts/gate-review.sh`, the tool itself, and editing the gate became
# impossible. Only paths INSIDE the directories are approval state.
_dirs='(\.claude/(merge-locks|gate-review)/)'

# Writers that take their destination as an argument. The path may appear
# anywhere after the verb, so these match the verb and the dir in one line
# rather than trying to count arguments.
#
# `cp`/`mv` are matched only when the dir appears as the LAST token: copying
# OUT of the dir is a read and must pass.
_verb_last="(cp|mv|install)[[:space:]]+[^|;&]*[[:space:]][^[:space:]|;&]*${_dirs}[^[:space:]|;&]*[[:space:]]*($|[|;&])"

# These take the target anywhere and are never reads.
_verb_any="(rm|rmdir|touch|ln|mkdir|chmod|chown|truncate|dd|tee)[[:space:]]+[^|;&]*${_dirs}"

# In-place editors rewrite the file they are pointed at.
_inplace="(sed[[:space:]]+[^|;&]*-i|perl[[:space:]]+[^|;&]*-i|ex[[:space:]])[^|;&]*${_dirs}"

# Shell redirects: `> path`, `>> path`. The redirect operator is what makes
# this a write, so the dir must follow it.
_redirect=">>?[[:space:]]*[^[:space:]|;&]*${_dirs}"

blocked=""
if printf '%s\n' "${cmd}" | grep -qE "${_redirect}"; then
  blocked="shell redirect"
elif printf '%s\n' "${cmd}" | grep -qE "${_inplace}"; then
  blocked="in-place edit"
elif printf '%s\n' "${cmd}" | grep -qE "${_verb_any}"; then
  blocked="file write"
elif printf '%s\n' "${cmd}" | grep -qE "${_verb_last}"; then
  blocked="copy or move into the directory"
fi

[[ -n "${blocked}" ]] || exit 0

# Log the attempt by kind, not by full command text: the command may carry a
# secret, and hook-block-secret-leak.sh runs before this one precisely so a
# name-only log wins. Keep it that way.
printf '%s BLOCKED GATE-DIR WRITE (%s)\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${blocked}" \
  >>"${HOME}/.claude/blocked-commands.log" || true

{
  echo '🛑 BLOCKED: writing to an approval directory is forbidden.'
  echo ''
  echo "  kind: ${blocked}"
  echo ''
  echo 'merge-locks/ and gate-review/ hold decisions only Andrew makes. An'
  echo 'agent that can write them can approve its own text or its own merge,'
  echo 'which is the single thing both locks exist to prevent.'
  echo ''
  echo 'Reading from these directories is allowed and is the normal path:'
  echo '  git commit -F ~/.claude/gate-review/approved/<name>'
  echo ''
  echo 'To get something approved, stage it and ask him to review:'
  echo '  gate-review.sh stage <label> <file> && gate-review.sh open'
} >&2
exit 2
