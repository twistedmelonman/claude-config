#!/usr/bin/env bash

# ~/Developer/claude-config/scripts/normalize-iterm-home.sh
# Git clean filter for settings.json. Does two things on the way into the index:
#   1. canonicalizes the JSON formatting (jq -S .)
#   2. strips the per-machine home directory out of the iTerm2 cc-status paths
#
# THE FORMATTING WAR
# ------------------
# Two programs write settings.json and disagree about style. iTerm2 writes via
# NSJSONSerialization: sorted keys, " : " separators, escaped "\/". Claude Code
# writes insertion order, ": ", bare "/". Neither is wrong and neither will
# yield, so whichever wrote last reformatted the entire document -- a two-line
# change arrived as ~390 lines of churn that buried the real edit.
#
# Rather than pick a winner, normalize on the way into the index. The canonical
# committed form is "whatever the last writer produced, run through jq". Both
# keep their own style in the working tree, neither has any reason to rewrite
# anything, and git sees one stable format.
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
# Two writers touch settings.json, and they escape differently:
#
#   iTerm2 (NSJSONSerialization) escapes forward slashes. Literal bytes:
#     \/Users\/arich\/.config\/iterm2\/cc-status
#
#   Claude Code's own settings writer does not. Literal bytes:
#     /Users/arich/.config/iterm2/cc-status
#
# Both forms must be matched. An earlier version of this filter handled only
# the escaped form, so whenever Claude Code rewrote settings.json -- enabling a
# plugin, changing a model -- the filter silently no-opped and the absolute
# home directory reached the index. filter.*.required does not catch that: the
# script still exits 0, it just has nothing to do.
#
# Two sed expressions rather than one with a backreference, because -E
# backreference support differs between BSD and GNU sed.
#
# SCOPE
# -----
# The full ".config/iterm2/cc-status" tail is required in the pattern so that
# sibling paths are untouched: other /Users/... values, other tools under
# .config/iterm2/, and hooks already written in "~/" form all pass through
# unchanged. Input with no cc-status entry passes through byte-identical.
#
# JSON strings cannot contain raw newlines, so a "command" value is always on a
# single line regardless of how the JSON is indented or wrapped. The pattern is
# therefore safe against indentation and wrapping; it keys on the path, not the
# layout. It is NOT automatically safe against a serializer that escapes
# differently -- that is why both escaping forms are spelled out above.
#
# The username character class excludes "/" so it cannot span a path component
# and swallow a longer, unrelated path that happens to end in the same tail.
#
# install.sh sets filter.iterm-home.required=true. That is load-bearing: without
# it, a missing or broken filter script makes git print an error, exit 0, and
# stage the UNFILTERED content -- silently committing an absolute home directory.
#
# Reads stdin, writes stdout. Idempotent.

set -euo pipefail

# Canonicalize first, then rewrite paths.
#
# jq -S . settles the formatting war: whatever either writer produced becomes
# one sorted, 2-space-indented document, so a two-line change reads as two
# lines instead of ~390 lines of reordering. It also unescapes "\/" to "/",
# which is why it must run BEFORE the sed pass -- after jq, only the
# bare-slash rule can match. The escaped rule is kept so the filter still
# behaves correctly when run by hand on a JSON fragment.
#
# If jq is missing or the input is not valid JSON, fall back to passing the
# bytes through unchanged rather than staging an empty file. The path rewrite
# still runs, so the #507 guarantee holds even without jq.
canonicalize() {
  if command -v jq >/dev/null 2>&1; then
    local input canonical
    input="$(cat)"
    if canonical="$(printf '%s' "${input}" | jq -S . 2>/dev/null)"; then
      printf '%s\n' "${canonical}"
    else
      printf '%s' "${input}"
    fi
  else
    cat
  fi
}

canonicalize | sed -E \
  -e 's#\\/Users\\/[^\\"/]+\\/\.config\\/iterm2\\/cc-status#~\\/.config\\/iterm2\\/cc-status#g' \
  -e 's#/Users/[^\\"/]+/\.config/iterm2/cc-status#~/.config/iterm2/cc-status#g'
