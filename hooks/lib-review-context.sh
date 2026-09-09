#!/usr/bin/env bash
# =========================================================
# lib-review-context.sh — Shared review-prompt context helpers
# =========================================================
#
# Extracted from run-review.sh so file-scope-context extraction and
# round-over-round feedback tracking can be unit tested independently
# of the full hook script.
#
# SOURCE GUARD:
#   Safe to source multiple times; second source is a no-op.
#
# USAGE:
#   source ~/.claude/hooks/lib-review-context.sh
#   extract_file_header_context "path/to/file.sh"
#
# =========================================================

[[ -n "${_LIB_REVIEW_CONTEXT_LOADED:-}" ]] && return 0
_LIB_REVIEW_CONTEXT_LOADED=1

# Reads a file's leading comment block (shebang line excluded) so review
# prompts can see stated scope/intent (e.g. "macOS-only, not intended for
# Linux/CI") that may not appear in the diff hunk itself. Reads from the
# working tree, not git blob — pre-commit review runs against files that
# already exist on disk with the staged changes applied to the index but
# also present as regular files (this is always true for a normal `git
# commit` invocation; the hook never runs against a bare/detached tree).
#
# Args: $1 = file path (relative to repo root or absolute)
#       $2 = max lines to extract (default 15)
# Echoes: the leading comment block, one line per output line, with the
#         leading '#' and exactly one following space stripped. Empty
#         output (no lines) if the file doesn't exist, is not readable,
#         or has no leading comment block.
extract_file_header_context() {
  local file="$1"
  local max_lines="${2:-15}"

  [[ -r "${file}" ]] || return 0

  awk -v max="${max_lines}" '
    NR == 1 && /^#!/ { next }               # skip shebang
    /^[[:space:]]*$/ { next }               # skip blank lines while still in header
    /^[[:space:]]*#/ {
      count++
      if (count > max) exit
      line = $0
      sub(/^[[:space:]]*#[[:space:]]?/, "", line)
      print line
      next
    }
    { exit }                                 # first non-comment, non-blank line ends header
  ' "${file}" 2>/dev/null || true
}

# Derive a stable cache key for round-over-round feedback tracking. Diff
# hashes change on every retry (the developer edits the code), so DIFF_HASH
# can't key this — key on the more stable "which branch, which files are
# in flight" identity instead. Args: $1 = CHANGED_FILES (newline-separated).
# Captures the hash before falling back, since a pipeline's exit status is
# the LAST command's (awk, which exits 0 even on empty stdin) — `|| echo`
# on the pipeline itself would never fire on a shasum failure.
round_history_key() {
  local changed_files="$1"
  local branch hash
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached")
  # The `|| true` below satisfies SC2312 and changes nothing: the fallback
  # here is value-based (`${hash:-noround}`), not status-based, exactly as
  # the comment above describes.
  hash=$(printf '%s\n%s\n' "${branch}" "$(sort <<<"${changed_files}" || true)" \
    | { shasum -a 256 2>/dev/null || true; } | awk '{print $1}')
  printf '%s\n' "${hash:-noround}"
}

# Append a FAIL round's raw output to the history file, capped at the last
# 2 rounds (oldest dropped). Args: $1 = history file path, $2 = round output.
# NOTE: uses a plain "---ROUND---" line delimiter. CODE_REVIEWER_OUTPUT is
# Claude CLI text output, not untrusted/adversarial input this codebase
# defends against, so a literal-string collision is out of scope here.
#
# Rounds are collected into an explicitly INDEXED array (rounds[0] is the
# oldest round found on disk, rounds[-1] is the newest) so "keep the last
# N" is a plain array-slice operation, not something inferred from which
# scratch variable held what after a loop exits.
write_round_feedback() {
  local history_file="$1"
  local round_output="$2"

  local existing=""
  [[ -f "${history_file}" ]] && existing=$(cat "${history_file}")

  local -a rounds=()
  if [[ -n "${existing}" ]]; then
    local current=""
    while IFS= read -r line; do
      if [[ "${line}" == "---ROUND---" ]]; then
        rounds+=("${current}")
        current=""
      else
        current+="${line}"$'\n'
      fi
    done <<<"${existing}"
    # Trailing content after the last delimiter (or the whole file, if no
    # delimiter was ever seen) is one more round — always non-empty here
    # since write_round_feedback never writes a file ending in a bare
    # delimiter with nothing after it.
    rounds+=("${current}")
  fi

  # This round is about to be appended, so keep at most 1 prior round
  # (rounds[-1], the newest already on disk) — combined with the new
  # round below, that caps total retained rounds at 2. An empty element
  # (a history file that was all delimiters, no content) is discarded
  # rather than treated as a real round.
  local keep=""
  if [[ ${#rounds[@]} -ge 1 && -n "${rounds[-1]}" ]]; then
    keep="${rounds[-1]}"
  fi

  {
    [[ -n "${keep}" ]] && printf '%s---ROUND---\n' "${keep}"
    printf '%s\n' "${round_output}"
  } >"${history_file}.tmp" && mv "${history_file}.tmp" "${history_file}"
}

# Echo a history file's contents verbatim; empty string if missing.
read_round_feedback() {
  local history_file="$1"
  [[ -f "${history_file}" ]] && cat "${history_file}" || true
}

# Remove a round-history file (called on PASS to reset for future runs).
clear_round_feedback() {
  local history_file="$1"
  rm -f "${history_file}"
}
