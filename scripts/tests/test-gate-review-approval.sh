#!/usr/bin/env bash
# gate-review.sh: approval is an explicit STATUS word bound to one batch id.
#
# Drives _split_batch and _status directly rather than _cmd_open, which needs a
# GUI. The cases that matter are the ones that must NOT approve: every bug this
# file covers was a path that reported success without a human.

set -uo pipefail

# CDPATH makes `cd` search its entries and land elsewhere: with ~/Developer on
# it, `cd scripts/tests/..` resolved to ~/Developer/scripts. The sourced
# functions then did not exist, and the two cases that assert a REFUSAL
# "passed" -- a false green on the tests that matter most here.
unset CDPATH

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gate-review.sh"
[[ -f "${GATE}" ]] || {
  echo "cannot find gate-review.sh at ${GATE}" >&2
  exit 1
}
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

export GATE_REVIEW_DIR="${TMP}/gate"
mkdir -p "${GATE_REVIEW_DIR}/pending" "${GATE_REVIEW_DIR}/approved"

pass=0
fail=0

_ok() {
  echo "  PASS  $1"
  pass=$((pass + 1))
}

_no() {
  echo "  FAIL  $1"
  fail=$((fail + 1))
}

# Source the script's functions without running its dispatcher.
_load() {
  eval "$(sed -n '/^_die()/,$p' "${GATE}" | sed '/^case "${1:-}"/,$d')"
  GATE_DIR="${GATE_REVIEW_DIR}"
  APPROVED="${GATE_DIR}/approved"
  # _write_approved clears the staged copy via ${PENDING:?}, which aborts under
  # set -u if unset. Shellcheck flags it unused because only sourced code reads
  # it; export keeps both satisfied.
  export PENDING="${GATE_DIR}/pending"
}

_batch() {
  local status="$1" nonce="$2" body="${3:-body text}"
  cat >"${GATE_REVIEW_DIR}/batch.txt" <<EOF
# STATUS: ${status}
# BATCH: ${nonce}

=== item-one ===
${body}
EOF
}

_load

# --- _status ----------------------------------------------------------------

_batch PENDING n1
if [[ "$(_status "${GATE_REVIEW_DIR}/batch.txt")" == "PENDING" ]]; then
  _ok "PENDING reads as PENDING"
else
  _no "PENDING reads as PENDING"
fi

_batch APPROVED n1
if [[ "$(_status "${GATE_REVIEW_DIR}/batch.txt")" == "APPROVED" ]]; then
  _ok "APPROVED reads as APPROVED"
else
  _no "APPROVED reads as APPROVED"
fi

_batch approved n1
if [[ "$(_status "${GATE_REVIEW_DIR}/batch.txt")" == "APPROVED" ]]; then
  _ok "lowercase approved is accepted"
else
  _no "lowercase approved is accepted"
fi

# A buffer with no status line must not read as approval.
printf 'no status line here\n' >"${GATE_REVIEW_DIR}/batch.txt"
if [[ "$(_status "${GATE_REVIEW_DIR}/batch.txt")" == "PENDING" ]]; then
  _ok "missing STATUS line falls back to PENDING"
else
  _no "missing STATUS line falls back to PENDING"
fi

# --- _split_batch nonce binding ---------------------------------------------

_batch APPROVED right-nonce
rm -f "${APPROVED:?}"/*
if _split_batch "${GATE_REVIEW_DIR}/batch.txt" right-nonce >/dev/null 2>&1 &&
  [[ -f "${APPROVED}/item-one" ]]; then
  _ok "matching batch id splits"
else
  _no "matching batch id splits"
fi

# The 2026-09-18 forged approval: a stale run splitting a batch it did not write.
# _die exits, so run the refusal in a subshell or it takes the test with it.
_batch APPROVED right-nonce
rm -f "${APPROVED:?}"/*
if (_split_batch "${GATE_REVIEW_DIR}/batch.txt" stale-nonce >/dev/null 2>&1); then
  _no "mismatched batch id is refused"
elif [[ -f "${APPROVED}/item-one" ]]; then
  _no "mismatched batch id is refused (wrote anyway)"
else
  _ok "mismatched batch id is refused"
fi

# --- _split_batch content fidelity ------------------------------------------

# `#` lines inside a body are content, not framing: stripping them rewrote the
# approved bytes so `check` failed against text that had been approved.
_batch APPROVED n2 '# A markdown heading
Body text.

Closes #123'
rm -f "${APPROVED:?}"/*
_split_batch "${GATE_REVIEW_DIR}/batch.txt" n2 >/dev/null 2>&1
if grep -q '^# A markdown heading$' "${APPROVED}/item-one" 2>/dev/null &&
  grep -q '^Closes #123$' "${APPROVED}/item-one" 2>/dev/null; then
  _ok "body keeps its # lines"
else
  _no "body keeps its # lines"
fi

if grep -q 'STATUS' "${APPROVED}/item-one" 2>/dev/null; then
  _no "framing header is stripped"
else
  _ok "framing header is stripped"
fi

echo "--- ${pass} passed, ${fail} failed"
[[ "${fail}" == "0" ]]
