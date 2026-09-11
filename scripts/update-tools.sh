#!/usr/bin/env bash
set -euo pipefail

# ~/Developer/claude-config/scripts/update-tools.sh
# Called by _claude_update() in bash profile.
# Maintains symlink health and audits ~/.claude/.
# Exit 0 always — must not break the update flow.

if [[ "${BASH_VERSINFO[0]}" -lt 5 ]]; then
  printf '[WARN]  update-tools.sh requires Bash 5+, found %s. Skipping.\n' "${BASH_VERSION}" >&2
  exit 0
fi

trap 'exit 0' ERR

# ── Args ────────────────────────────────────────────────
_LEARN=false
for arg in "$@"; do
  case "${arg}" in
    --learn) _LEARN=true ;;
    *) ;;
  esac
done

# ── Constants ───────────────────────────────────────────
REPO_DIR="${HOME}/Developer/claude-config"
DEPLOY_DIR="${HOME}/.claude"
KNOWN_RUNTIME_FILE="${REPO_DIR}/scripts/known-runtime.txt"

# ── Formatting helpers ──────────────────────────────────
_info() { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
_ok() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
_warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }

# ============================================================================
# 1. SYMLINK REPAIR
# ============================================================================

_info "Repairing symlinks..."

if [[ -x "${REPO_DIR}/install.sh" ]]; then
  "${REPO_DIR}/install.sh" --repair
else
  _warn "install.sh not found or not executable at ${REPO_DIR}/install.sh"
fi

# ============================================================================
# 2. AUDIT — categorize depth-1 entries in ~/.claude/
# ============================================================================

_info "Auditing ${DEPLOY_DIR}/..."

# Directories containing symlinked repo files (not symlinks themselves)
_REPO_MANAGED_DIRS=()
mapfile -t _tracked_files < <(git -C "${REPO_DIR}" ls-files 2>/dev/null || true)
for file in "${_tracked_files[@]}"; do
  dir="${file%%/*}"
  # Only add top-level dirs, skip top-level files
  [[ "${dir}" != "${file}" ]] || continue
  local_found=false
  for existing in "${_REPO_MANAGED_DIRS[@]+"${_REPO_MANAGED_DIRS[@]}"}"; do
    if [[ "${existing}" == "${dir}" ]]; then
      local_found=true
      break
    fi
  done
  "${local_found}" || _REPO_MANAGED_DIRS+=("${dir}")
done

# Files and directories that Claude Code manages at runtime.
# Loaded from a data file (not hardcoded) so new entries can be accepted
# with `update-tools.sh --learn` instead of a code edit. See known-runtime.txt.
_KNOWN_RUNTIME=()
if [[ -f "${KNOWN_RUNTIME_FILE}" ]]; then
  while IFS= read -r _line; do
    # Strip comments and blank lines
    _line="${_line%%#*}"
    _line="${_line#"${_line%%[![:space:]]*}"}"
    _line="${_line%"${_line##*[![:space:]]}"}"
    [[ -n "${_line}" ]] && _KNOWN_RUNTIME+=("${_line}")
  done <"${KNOWN_RUNTIME_FILE}"
else
  _warn "known-runtime.txt not found at ${KNOWN_RUNTIME_FILE}"
fi

# Classify a basename as directory-like or file-like for --learn section
# placement. No extension (and doesn't start with '.') => directory-like;
# has an extension or starts with '.' => file-like. This is a heuristic
# (matches the existing known-runtime.txt convention: dotfiles and
# extensioned names live under "# Files", bare names under "# Directories"),
# not a filesystem stat. The current caller always passes an already-
# basenamed value, so the internal basename call below is a forward-
# compatibility guard (not required for today's correctness) against a
# future caller passing a full path.
_entry_section() {
  local name
  name="$(basename "$1")"
  case "${name}" in
    .*) echo "Files" ;;
    *.*) echo "Files" ;;
    *) echo "Directories" ;;
  esac
}

# Insert a new entry under its section header (# Directories or # Files) in
# KNOWN_RUNTIME_FILE, preserving existing structure. The entry is placed at
# the END of its section (immediately before the next blank line, next
# section header, or EOF) rather than right after the header line, so
# repeated --learn runs append in natural order instead of reversing it.
# Appends a fresh section (with a preceding blank line) if the target
# header can't be found, so --learn never loses an entry even in a
# malformed file. Returns non-zero (and leaves the original file untouched)
# if the awk/mv rewrite fails, cleaning up its temp file either way.
# Not designed for concurrent invocation (single-user local maintenance
# tool, invoked interactively) — no file locking around the grep-then-awk
# read/rewrite. `awk -v var="${val}"` passes ${val} as a single argv
# element; it is not re-parsed as awk source, so entry/header values
# containing quotes or other shell metacharacters are safe as-is.
_append_known_runtime_entry() {
  local name="$1"
  [[ -n "${name}" ]] || return 1
  local section
  section="$(_entry_section "${name}")"
  local header="# ${section}"

  if grep -qxF "${header}" "${KNOWN_RUNTIME_FILE}"; then
    # in_section tracks whether we're inside the target section. On the
    # first line that ends the section (blank line, another '#' header, or
    # EOF via END{}) while still in_section, emit the new entry BEFORE that
    # boundary line — this lands it at the end of the target section's
    # existing entries, not before them.
    if awk -v header="${header}" -v entry="${name}" '
        function flush_if_needed() {
          if (in_section && !done) { print entry; done = 1 }
        }
        {
          if ($0 == header) { in_section = 1 }
          else if (in_section && (($0 ~ /^#/) || ($0 ~ /^[[:space:]]*$/))) {
            flush_if_needed()
            in_section = 0
          }
          print
        }
        END { flush_if_needed() }
      ' "${KNOWN_RUNTIME_FILE}" >"${KNOWN_RUNTIME_FILE}.tmp" \
      && mv "${KNOWN_RUNTIME_FILE}.tmp" "${KNOWN_RUNTIME_FILE}"; then
      return 0
    else
      rm -f "${KNOWN_RUNTIME_FILE}.tmp"
      return 1
    fi
  else
    # Section header missing (shouldn't happen with the shipped file) —
    # append a fresh section at the end rather than dropping the entry.
    # Propagate a write failure (e.g. disk full) instead of returning 0
    # implicitly, so the caller's success count stays accurate.
    {
      printf '\n%s\n' "${header}"
      printf '%s\n' "${name}"
    } >>"${KNOWN_RUNTIME_FILE}" || return 1
  fi
}

_is_known_runtime() {
  local name="$1"

  # Match *.jsonl files (Claude Code log files)
  case "${name}" in
    *.jsonl) return 0 ;;
    *) ;;
  esac

  local entry
  for entry in "${_KNOWN_RUNTIME[@]}"; do
    if [[ "${name}" == "${entry}" ]]; then
      return 0
    fi
  done

  return 1
}

symlinked_count=0
runtime_count=0
unknown_count=0
unknown_items=()

for entry in "${DEPLOY_DIR}"/* "${DEPLOY_DIR}"/.*; do
  basename="$(basename "${entry}")"

  # Skip . and ..
  case "${basename}" in
    . | ..) continue ;;
    *) ;;
  esac

  # Skip if the glob didn't match anything
  [[ -e "${entry}" || -L "${entry}" ]] || continue

  # Check if it's a repo-managed directory (contains symlinked files)
  _is_repo_managed=false
  for rdir in "${_REPO_MANAGED_DIRS[@]+"${_REPO_MANAGED_DIRS[@]}"}"; do
    if [[ "${basename}" == "${rdir}" ]]; then
      _is_repo_managed=true
      break
    fi
  done

  if [[ -L "${entry}" ]]; then
    symlinked_count=$((symlinked_count + 1))
  elif "${_is_repo_managed}"; then
    symlinked_count=$((symlinked_count + 1))
  elif _is_known_runtime "${basename}"; then
    runtime_count=$((runtime_count + 1))
  else
    unknown_count=$((unknown_count + 1))
    unknown_items+=("${entry}")
  fi
done

# ── Audit report ────────────────────────────────────────
echo ""
echo "───────────────────────────────────────────────────────"
echo " ~/.claude/ Audit Report"
echo "───────────────────────────────────────────────────────"
_ok "Symlinked (repo-managed): ${symlinked_count}"
_ok "Known runtime (Claude Code): ${runtime_count}"

if [[ "${unknown_count}" -gt 0 ]]; then
  _warn "Unknown entries: ${unknown_count}"
  for item in "${unknown_items[@]}"; do
    _warn "  ${item}"
  done
  echo ""
  if "${_LEARN}"; then
    _new_entries=()
    for item in "${unknown_items[@]}"; do
      _b="$(basename "${item}")"
      _dup=false
      for existing in "${_KNOWN_RUNTIME[@]+"${_KNOWN_RUNTIME[@]}"}"; do
        if [[ "${_b}" == "${existing}" ]]; then
          _dup=true
          break
        fi
      done
      "${_dup}" || _new_entries+=("${_b}")
    done

    if [[ "${#_new_entries[@]}" -eq 0 ]]; then
      _ok "No new entries to learn (already recorded)"
    else
      # Stop at the first write failure rather than continuing through the
      # rest of _new_entries: this is a local, single-user maintenance tool
      # (no concurrent writers to race against), so a failure here almost
      # always means a real problem with KNOWN_RUNTIME_FILE (permissions,
      # disk full) that will just repeat for every remaining entry. Halting
      # early keeps the failure mode simple: either all attempted entries up
      # to the failure landed, or none did if the very first write fails.
      _learn_added_count=0
      _learn_failed_entry=""
      for _new in "${_new_entries[@]}"; do
        if _append_known_runtime_entry "${_new}"; then
          _learn_added_count=$((_learn_added_count + 1))
        else
          _learn_failed_entry="${_new}"
          break
        fi
      done
      if [[ -n "${_learn_failed_entry}" ]]; then
        _warn "Failed to write entry '${_learn_failed_entry}' to ${KNOWN_RUNTIME_FILE} — stopped (${_learn_added_count} entries were added before the failure)"
      fi
      if [[ "${_learn_added_count}" -gt 0 ]]; then
        _ok "Added ${_learn_added_count} entries to $(basename "${KNOWN_RUNTIME_FILE}") (categorized by type)"
        _info "Review and commit: git -C ${REPO_DIR} diff scripts/known-runtime.txt"
      fi
    fi
  else
    _info "Evaluate the items above, then run:"
    _info "  ${0} --learn"
    _info "to accept them as known runtime, or bring them into the repo instead."
  fi
else
  _ok "Unknown entries: 0"
fi

echo ""
_ok "Update tools complete."

exit 0
