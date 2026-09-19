#!/usr/bin/env bash
# Hook: Block Write/Edit operations to the approval directories
# Prevents unauthorized modification of merge locks and text approvals
#
# Covers the Write and Edit matchers. The Bash path -- `cp`, `tee`, `sed -i`,
# redirects -- carries no file_path and is not visible here; it is covered by
# hook-block-gate-dir-write.sh in the Bash chain. Both are needed: this file
# alone returned exit 0 for a Bash `cp` into merge-locks/ (measured
# 2026-09-18).

set -euo pipefail

input=$(cat)
file_path=$(printf '%s\n' "${input}" | jq -r '.tool_input.file_path // empty')

# Block any write to an approval DIRECTORY. The trailing `/` is required, not
# decorative: without it the name also matches files that merely start with it,
# and `scripts/gate-review.sh` -- the tool itself -- became uneditable. The
# older merge-locks-only pattern got away with an optional separator because
# nothing is named `merge-locks.sh`; `gate-review.sh` exists, so the directory
# form has to be spelled out.
# Pattern catches: /merge-locks/, ./merge-locks/, ~/merge-locks/, ../merge-locks/
# and the same forms of gate-review/.
if printf '%s\n' "${file_path}" | grep -qE '(^|[^a-zA-Z0-9_-])(merge-locks|gate-review)/'; then
  printf '%s BLOCKED WRITE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${file_path}" >>"${HOME}/.claude/blocked-commands.log" || true
  printf '🛑 BLOCKED: Writing to an approval directory is forbidden.\n' >&2
  printf '\n' >&2
  printf 'merge-locks/ and gate-review/ hold decisions only Andrew makes.\n' >&2
  printf 'Reading from them is allowed; writing them is not.\n' >&2
  exit 2
fi
