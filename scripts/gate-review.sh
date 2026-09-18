#!/usr/bin/env bash
# Present proposed commit/PR text for human review in a GUI editor, and record
# what was actually saved as the approval.
#
# The approval is the saved bytes, not a yes/no: edits in the editor are what
# gets committed. Hashing those bytes is what binds one approval to one text --
# any later drift re-blocks.
#
# Approval is an explicit STATUS word, not the act of saving. Saving looked
# like the lighter-weight signal, but BBEdit does not write an unmodified
# document, so "save without editing" -- the common case, approving text as
# written -- produced no event at all. Watching mtime instead meant any write
# counted, and a concurrent run's write counted as this run's approval
# (measured 2026-09-18: a stale poller approved a batch no human had read).
# Typing one word is both detectable and unambiguous.
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

_cmd_stage() {
  local name="$1" file="$2"
  [[ -f "${file}" ]] || _die "no such file: ${file}"
  [[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || _die "bad artifact name: ${name}"
  cp "${file}" "${PENDING}/${name}"
  printf 'staged: %s\n' "${name}"
}

_cmd_open() {
  local batch count waited=0 nonce status
  batch="${GATE_DIR}/batch.txt"

  count=$(find "${PENDING}" -type f | wc -l | tr -d ' ')
  ((count > 0)) || _die "nothing staged"

  _require_gui

  # A second `open` sharing this GATE_DIR races on one batch.txt: whichever
  # process polls first splits whatever the other one wrote. Measured
  # 2026-09-18 -- a stale poller from an interrupted session split a newer
  # batch and reported it approved, with no human involved at all.
  _refuse_if_open

  # Bound this batch to this process. _split_batch refuses a buffer carrying a
  # different id, so a stale poller cannot approve text it never wrote.
  nonce="$$-$(date +%s)"

  # One buffer for the whole set: the reviewer reads and edits everything in a
  # single pass, which is the point of batching.
  {
    echo "# STATUS: PENDING"
    echo "#"
    echo "# REVIEW THESE ${count} ITEM(S), EDIT FREELY."
    echo "#"
    echo "# TO APPROVE: change PENDING above to APPROVED, then save."
    echo "# TO ABORT:   change PENDING above to ABORT, then save."
    echo "#"
    echo "# An explicit word, not a bare save: BBEdit does not write an"
    echo "# unmodified document, so there is no save to detect. Leaving this"
    echo "# PENDING approves nothing, which is also what an editor autosaving"
    echo "# on close leaves behind."
    echo "#"
    echo "# To drop ONE item from the set: delete its body."
    echo "# Lines starting with # are stripped from the approved text."
    echo "#"
    echo "# BATCH: ${nonce}"
    for f in "${PENDING}"/*; do
      echo ""
      echo "=== ${f##*/} ==="
      cat "${f}"
    done
  } >"${batch}"

  printf 'opening %s item(s) in %s\n' "${count}" "${EDITOR_APP}" >&2
  open -a "${EDITOR_APP}" "${batch}" || _die "could not open ${EDITOR_APP}"

  # `open` returns as soon as the request is dispatched, so wait on the file
  # rather than on the editor. Poll the status word: it is written only by a
  # human typing it, whereas mtime moves for reasons that are not approval.
  printf 'waiting for APPROVED or ABORT (timeout %ss)...\n' "${POLL_TIMEOUT}" >&2
  while ((waited < POLL_TIMEOUT)); do
    sleep 2
    waited=$((waited + 2))
    status="$(_status "${batch}")"
    [[ "${status}" != "PENDING" ]] && break
  done

  status="$(_status "${batch}")"
  case "${status}" in
    APPROVED) ;;
    ABORT)
      rm -f "${APPROVED:?}"/*
      _die "ABORT; nothing approved"
      ;;
    PENDING)
      _die "still PENDING after ${POLL_TIMEOUT}s; nothing approved"
      ;;
    *)
      _die "unrecognized status '${status}'; nothing approved"
      ;;
  esac

  _split_batch "${batch}" "${nonce}"
  printf 'approved %s item(s)\n' "$(find "${APPROVED}" -type f | wc -l | tr -d ' ')"
}

# The status word, or PENDING if the line is missing or unreadable: an
# unparseable buffer must not read as approval.
_status() {
  local line
  line="$(grep -m1 -E '^#[[:space:]]*STATUS:' "$1" 2>/dev/null || true)"
  [[ -n "${line}" ]] || { printf 'PENDING\n'; return 0; }
  printf '%s\n' "${line}" |
    sed -E 's/^#[[:space:]]*STATUS:[[:space:]]*//; s/[[:space:]]*$//' |
    tr '[:lower:]' '[:upper:]'
}

# Refuse to open while another gate-review is polling this same GATE_DIR.
_refuse_if_open() {
  local others
  others="$(pgrep -f 'gate-review(\.sh)? open' | grep -v "^$$\$" || true)"
  [[ -z "${others}" ]] && return 0
  {
    echo "gate-review: another review is already open (pid(s): ${others//$'\n'/ })."
    echo "gate-review: two reviews sharing one batch approve each other's text."
    echo "gate-review: finish or kill that one first."
  } >&2
  exit 1
}

# Split the saved buffer back into per-artifact approvals, so each commit is
# checked against its own text rather than the batch as a whole.
_split_batch() {
  local batch="$1" want_nonce="${2:-}" name="" body="" got_nonce
  # Only split the buffer this process wrote. Without this, a concurrent or
  # stale run splits whatever it finds and reports it approved.
  if [[ -n "${want_nonce}" ]]; then
    got_nonce="$(sed -n -E 's/^#[[:space:]]*BATCH:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "${batch}" | head -1)"
    [[ "${got_nonce}" == "${want_nonce}" ]] ||
      _die "batch id mismatch (saw '${got_nonce}', expected '${want_nonce}'); nothing approved"
  fi
  rm -f "${APPROVED:?}"/*

  while IFS= read -r line; do
    case "${line}" in
      '=== '*' ===')
        [[ -n "${name}" ]] && _write_approved "${name}" "${body}"
        name="${line#=== }"
        name="${name% ===}"
        body=""
        ;;
      # Strip `#` lines only in the framing header, before the first artifact.
      # Inside a body they are content: a markdown heading, a shebang, a
      # `Closes #N` trailer. Stripping those silently rewrote the approved
      # bytes, so `check` then failed against text that WAS approved.
      '#'*) [[ -z "${name}" ]] || body+="${line}"$'\n' ;;
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
