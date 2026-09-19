#!/usr/bin/env bash
# Hook: Wrapper that runs all block hooks
# Keeps settings.json clean by consolidating block checks

set -euo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read input once and pass to each hook
input=$(cat)

# hook-block-secret-leak.sh runs FIRST, deliberately. Every other hook here
# logs the full command text to blocked-commands.log when it blocks, and this
# loop stops at the first hook that does. If a command carries a live secret
# AND trips another rule, running that other hook first would write the secret
# to disk before the secret-leak hook ever saw it. First position means the
# name-only log wins.
for hook in \
  "${SCRIPT_DIR}/hook-block-secret-leak.sh" \
  "${SCRIPT_DIR}/hook-block-gate-dir-write.sh" \
  "${SCRIPT_DIR}/hook-block-no-verify.sh" \
  "${SCRIPT_DIR}/hook-block-short-no-verify.sh" \
  "${SCRIPT_DIR}/hook-block-main-commit.sh" \
  "${SCRIPT_DIR}/hook-block-personify.sh" \
  "${SCRIPT_DIR}/hook-check-commit-message.py" \
  "${SCRIPT_DIR}/hook-block-merge-lock-authorize.sh" \
  "${SCRIPT_DIR}/hook-block-api-merge.sh" \
  "${SCRIPT_DIR}/hook-block-git-worktree.sh"; do
  if [[ -x "${hook}" ]]; then
    printf '%s\n' "${input}" | "${hook}" || exit $?
  fi
done
