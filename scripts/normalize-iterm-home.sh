#!/usr/bin/env bash

# ~/Developer/claude-config/scripts/normalize-iterm-home.sh
# Git clean filter: strip the per-machine home directory out of settings.json's
# iTerm2 cc-status hook paths before they reach the git index.
#
# WHY THIS EXISTS
# ---------------
# iTerm2's Claude Code integration rewrites its cc-status hook entries in
# ~/.claude/settings.json on every launch. It finds its own entry by matching
# the "/cc-status" suffix, then forces the path to an absolute one built from
# NSHomeDirectory() -- see ClaudeCodeOnboarding.swift, whose log string reads
# "hook for <path> already present, ensured path is current".
#
# Because ~/.claude/settings.json is a symlink into this repo, and because the
# machines use different usernames (andrewrich on asiago/tilsit/mimolette,
# arich on arich-mac), every launch dirties the tracked file with a home
# directory that is correct locally and wrong everywhere else.
#
# A "~/" path in the tracked file does NOT solve this: Claude Code accepts it,
# but iTerm2 treats it as stale and rewrites it to absolute on the next launch.
# Uninstalling the integration is also not an option -- the single menu item
# removes the workgroup and the Enter/Exit triggers along with the hook.
#
# So instead of fighting the write, this filter normalizes it on the way into
# the index. The working tree keeps whatever absolute path iTerm2 wrote (so the
# integration keeps working and iTerm2 has no reason to touch anything), while
# the committed content stays machine-neutral.
#
# ESCAPING
# --------
# settings.json is NSJSONSerialization output, so forward slashes arrive
# backslash-escaped. The literal bytes are:
#     \/Users\/arich\/.config\/iterm2\/cc-status
# The pattern therefore matches \/ pairs, not bare slashes.
#
# SCOPE
# -----
# The full ".config/iterm2/cc-status" tail is required in the pattern so that
# sibling paths are untouched: other /Users/... values, other tools under
# .config/iterm2/, and hooks already written in "~/" form all pass through
# unchanged. Input with no cc-status entry passes through byte-identical.
#
# Reads stdin, writes stdout. Idempotent.

set -euo pipefail

sed -E 's#\\/Users\\/[^\\"]+\\/\.config\\/iterm2\\/cc-status#~\\/.config\\/iterm2\\/cc-status#g'
