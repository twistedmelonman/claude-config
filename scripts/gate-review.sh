#!/usr/bin/env bash
# Present proposed commit/PR text for human review in a GUI editor, and record
# what was actually saved as the approval.
#
# The approval is the saved bytes, not a yes/no: edits in the editor are what
# gets committed. Hashing those bytes is what binds one approval to one text --
# any later drift re-blocks.
#
# GUI only, by design. `open -a` reaches the window server from a process with
# no TTY, which is what makes this work from an agent's tool call. Over SSH
# there is no window server, so this fails closed rather than waving text
# through ungated. See claude-config#509 for the same unsolved remote case.
#
# Usage:
#   gate-review.sh stage <name> <file>   queue one artifact for review
#   gate-review.sh open                  open the batch, wait for save
#   gate-review.sh hash <file>           print the approved-bytes hash
#   gate-review.sh check <name> <file>   exit 0 if file matches its approval

set -euo pipefail
unset CDPATH

GATE_DIR="${GATE_REVIEW_DIR:-${HOME}/.claude/gate-review}"
PENDING="${GATE_DIR}/pending"
APPROVED="${GATE_DIR}/approved"
EDITOR_APP="${GATE_REVIEW_EDITOR:-BBEdit}"
POLL_TIMEOUT="${GATE_REVIEW_TIMEOUT:-1800}"

mkdir -p "${PENDING}" "${APPROVED}"

_die() {
  printf 'gate-review: %s\n' "$1" >&2
  exit 1
}

# Aqua means a window server exists. Anything else -- SSH, a headless daemon --
# cannot open an editor, and must not silently pass.
_require_gui() {
  local mgr
  mgr="$(launchctl managername 2>/dev/null || echo unknown)"
  [[ "${mgr}" == "Aqua" ]] && return 0
  {
    echo "gate-review: no GUI session (launchctl managername = ${mgr})."
    echo "gate-review: text cannot be reviewed from here, so it is not approved."
    echo "gate-review: run this from a desktop session on the machine."
  } >&2
  exit 1
}

# Normalize before hashing so a trailing-newline difference between what the
# editor saved and what git receives does not read as tampering.
_hash() {
  sed -e 's/[[:space:]]*$//' "$1" | sha256sum | cut -d' ' -f1
}

# Approval is any save, not a content change: approving text as-written is a
# normal outcome, and a content hash cannot see an unchanged save. Watching
# mtime means ⌘S is the approval whether or not anything was edited.
_mtime() {
  stat -f '%m' "$1" 2>/dev/null || echo 0
}

_cmd_stage() {
  local name="$1" file="$2"
  [[ -f "${file}" ]] || _die "no such file: ${file}"
  [[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || _die "bad artifact name: ${name}"
  cp "${file}" "${PENDING}/${name}"
  printf 'staged: %s\n' "${name}"
}

_cmd_open() {
  local batch count before after waited=0
  batch="${GATE_DIR}/batch.txt"

  count=$(find "${PENDING}" -type f | wc -l | tr -d ' ')
  ((count > 0)) || _die "nothing staged"

  _require_gui

  # One buffer for the whole set: the reviewer reads and edits everything in a
  # single pass, which is the point of batching.
  {
    echo "# REVIEW THESE ${count} ITEM(S), EDIT FREELY, THEN SAVE."
    echo "#"
    echo "# Saving IS the approval -- editing is optional, approving as-written"
    echo "# is fine. What you save is what gets committed."
    echo "#"
    echo "# To abort EVERYTHING: put ABORT on a line by itself (with the #)."
    echo "# To abort ONE item: delete its body."
    echo "#"
    echo "# Do not rely on closing without saving: some editors autosave."
    echo "# Lines starting with # are stripped."
    echo "#"
    for f in "${PENDING}"/*; do
      echo ""
      echo "=== ${f##*/} ==="
      cat "${f}"
    done
  } >"${batch}"

  # Second-granularity mtime means a save within the same second as the write
  # would not register. Settle past that boundary before recording the
  # baseline, so the first poll cannot miss a fast save.
  sleep 1
  before="$(_mtime "${batch}")"

  printf 'opening %s item(s) in %s\n' "${count}" "${EDITOR_APP}" >&2
  open -a "${EDITOR_APP}" "${batch}" || _die "could not open ${EDITOR_APP}"

  # `open` returns as soon as the request is dispatched, so wait on the file
  # rather than on the editor. Polling keeps this from hanging forever on a
  # window left open; the timeout reports rather than silently approving.
  printf 'waiting for save (timeout %ss)...\n' "${POLL_TIMEOUT}" >&2
  while ((waited < POLL_TIMEOUT)); do
    sleep 2
    waited=$((waited + 2))
    after="$(_mtime "${batch}")"
    [[ "${after}" != "${before}" ]] && break
  done

  after="$(_mtime "${batch}")"
  if [[ "${after}" == "${before}" ]]; then
    _die "no save detected within ${POLL_TIMEOUT}s; nothing approved"
  fi

  # An explicit abort marker, not "closed without saving": some editors
  # autosave on close, which would turn an intended abort into approval.
  if grep -qE '^#[[:space:]]*ABORT[[:space:]]*$' "${batch}"; then
    rm -f "${APPROVED:?}"/*
    _die "ABORT found; nothing approved"
  fi

  _split_batch "${batch}"
  printf 'approved %s item(s)\n' "$(find "${APPROVED}" -type f | wc -l | tr -d ' ')"
}

# Split the saved buffer back into per-artifact approvals, so each commit is
# checked against its own text rather than the batch as a whole.
_split_batch() {
  local batch="$1" name="" body=""
  rm -f "${APPROVED:?}"/*

  while IFS= read -r line; do
    case "${line}" in
      '=== '*' ===')
        [[ -n "${name}" ]] && _write_approved "${name}" "${body}"
        name="${line#=== }"
        name="${name% ===}"
        body=""
        ;;
      '#'*) ;;
      *) [[ -n "${name}" ]] && body+="${line}"$'\n' ;;
    esac
  done <"${batch}"
  [[ -n "${name}" ]] && _write_approved "${name}" "${body}"
  return 0
}

_write_approved() {
  local name="$1" body="$2" trimmed
  # An item emptied in the editor is a deliberate abort, not an approval.
  trimmed="$(printf '%s' "${body}" | sed -e '/^[[:space:]]*$/d')"
  [[ -n "${trimmed}" ]] || return 0
  printf '%s' "${body}" >"${APPROVED}/${name}"
  rm -f "${PENDING:?}/${name}"
}

_cmd_check() {
  local name="$1" file="$2"
  [[ -f "${APPROVED}/${name}" ]] || return 1
  [[ "$(_hash "${file}")" == "$(_hash "${APPROVED}/${name}")" ]]
}

case "${1:-}" in
  stage) shift; _cmd_stage "$@" ;;
  open) _cmd_open ;;
  hash) shift; _hash "$1" ;;
  check) shift; _cmd_check "$@" ;;
  *) _die "usage: gate-review.sh {stage <name> <file>|open|hash <file>|check <name> <file>}" ;;
esac
