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

# --- round trip: stage -> split -> check the ORIGINAL file -------------------

# The workflow the tool exists for. Neither suite covered it, and it was
# broken: _cmd_open writes a blank line before each `=== name ===`, so every
# artifact but the LAST came back with one extra trailing newline and failed
# its own check. Two items, because a one-item batch passes either way.
_multi_batch() {
  local nonce="$1" a="$2" b="$3"
  {
    echo "# STATUS: APPROVED"
    echo "# BATCH: ${nonce}"
    echo ""
    echo "=== item-a ==="
    cat "${a}"
    echo ""
    echo "=== item-b ==="
    cat "${b}"
  } >"${GATE_REVIEW_DIR}/batch.txt"
}

A="${TMP}/a.txt"
B="${TMP}/b.txt"
printf 'fix(one): first body\n' >"${A}"
printf 'fix(two): second body\n' >"${B}"
rm -f "${APPROVED:?}"/*
_multi_batch rt "${A}" "${B}"
_split_batch "${GATE_REVIEW_DIR}/batch.txt" rt >/dev/null 2>&1

if _cmd_check "${A}" && _cmd_check "${B}"; then
  _ok "both staged files verify against their approvals"
else
  _no "both staged files verify against their approvals"
fi

# A body whose last line has no trailing newline must keep that line. `read`
# returns false on it, and without the `|| [[ -n ... ]]` guard the loop dropped
# it: he would approve two lines and one would commit.
printf 'line one\nline two no newline' >"${TMP}/c.txt"
rm -f "${APPROVED:?}"/*
{
  echo "# STATUS: APPROVED"
  echo "# BATCH: nl"
  echo ""
  echo "=== item-c ==="
  cat "${TMP}/c.txt"
} >"${GATE_REVIEW_DIR}/batch.txt"
_split_batch "${GATE_REVIEW_DIR}/batch.txt" nl >/dev/null 2>&1
if grep -q 'line two no newline' "${APPROVED}/item-c" 2>/dev/null; then
  _ok "a body with no trailing newline keeps its last line"
else
  _no "a body with no trailing newline keeps its last line"
fi

# --- check matches on content, not on name -----------------------------------

# `check` takes no name: the hook cannot infer one from a command string.
# A body approved under any label must satisfy it.
rm -f "${APPROVED:?}"/*
printf 'some approved text\n' >"${APPROVED}/label-does-not-matter"
printf 'some approved text\n' >"${TMP}/same-bytes.txt"
printf 'different text\n' >"${TMP}/other-bytes.txt"
if _cmd_check "${TMP}/same-bytes.txt"; then
  _ok "matching bytes verify regardless of artifact name"
else
  _no "matching bytes verify regardless of artifact name"
fi
if _cmd_check "${TMP}/other-bytes.txt"; then
  _no "non-matching bytes are refused"
else
  _ok "non-matching bytes are refused"
fi

# --- a batch revokes only what it restates -----------------------------------

# _split_batch used to `rm -f approved/*`, so approving a commit message an
# hour after a PR body silently revoked the PR body. Each name is now cleared
# as it is rewritten.
rm -f "${APPROVED:?}"/*
printf 'earlier approval\n' >"${APPROVED}/from-an-earlier-batch"
_batch APPROVED later 'a later body'
_split_batch "${GATE_REVIEW_DIR}/batch.txt" later >/dev/null 2>&1
if [[ -f "${APPROVED}/from-an-earlier-batch" ]]; then
  _ok "a new batch leaves an earlier batch's approval standing"
else
  _no "a new batch leaves an earlier batch's approval standing"
fi

# Emptying an item in the editor is how a reviewer drops it. That must REVOKE
# a prior approval of the same name, not leave the old one in place.
rm -f "${APPROVED:?}"/*
_batch APPROVED rev1 'original body'
_split_batch "${GATE_REVIEW_DIR}/batch.txt" rev1 >/dev/null 2>&1
cat >"${GATE_REVIEW_DIR}/batch.txt" <<'EOF'
# STATUS: APPROVED
# BATCH: rev2

=== item-one ===
EOF
_split_batch "${GATE_REVIEW_DIR}/batch.txt" rev2 >/dev/null 2>&1
if [[ -f "${APPROVED}/item-one" ]]; then
  _no "emptying an item revokes its earlier approval"
else
  _ok "emptying an item revokes its earlier approval"
fi

# --- check records: stage requires one, open shows it -----------------------

export XDG_CONFIG_HOME="${TMP}/xdg"
CHECKS="${XDG_CONFIG_HOME}/personify/checks"
mkdir -p "${CHECKS}"

_seed_record() {
  local file="$1" json="$2" sha
  sha="$(sha256sum "${file}" | cut -d' ' -f1)"
  printf '%s\n' "${json}" >"${CHECKS}/${sha}.json"
}

UNCHECKED="${TMP}/unchecked.txt"
printf 'fix(x): nobody ran the check on this\n' >"${UNCHECKED}"
rm -f "${PENDING:?}"/*
if (_cmd_stage unchecked "${UNCHECKED}") >/dev/null 2>&1; then
  _no "stage refuses a file with no check record"
else
  _ok "stage refuses a file with no check record"
fi
if [[ ! -e "${PENDING}/unchecked" ]]; then
  _ok "a refused stage leaves nothing pending"
else
  _no "a refused stage leaves nothing pending"
fi

CHECKED="${TMP}/checked.txt"
printf 'fix(x): trailing whitespace is part of the key   \n\n' >"${CHECKED}"
_seed_record "${CHECKED}" '{"status":"FAIL","verdict":"AI","fraction_ai":0.97,"word_count":212}'
if (_cmd_stage checked "${CHECKED}") >/dev/null 2>&1 && cmp -s "${CHECKED}" "${PENDING}/checked"; then
  _ok "stage accepts a FAIL record keyed by the raw bytes"
else
  _no "stage accepts a FAIL record keyed by the raw bytes"
fi

got="$(_verdict_line checked "${CHECKED}")"
if [[ "${got}" == "# checked: FAIL (AI, fraction_ai 0.97, 212 words)" ]]; then
  _ok "verdict line for a classified record"
else
  _no "verdict line for a classified record: ${got}"
fi

SHORT="${TMP}/short.txt"
printf 'fix(x): short\n' >"${SHORT}"
_seed_record "${SHORT}" '{"status":"SKIPPED","verdict":null,"fraction_ai":null,"word_count":2}'
got="$(_verdict_line short "${SHORT}")"
if [[ "${got}" == "# short: SKIPPED (2 words, under the floor)" ]]; then
  _ok "verdict line for a skipped record"
else
  _no "verdict line for a skipped record: ${got}"
fi

got="$(_verdict_line unchecked "${UNCHECKED}")"
if [[ "${got}" == "# unchecked: NO RECORD" ]]; then
  _ok "verdict line when the record is gone"
else
  _no "verdict line when the record is gone"
fi

BROKEN="${TMP}/broken.txt"
printf 'fix(x): record is not json\n' >"${BROKEN}"
_seed_record "${BROKEN}" 'not json {'
got="$(_verdict_line broken "${BROKEN}")"
if [[ "${got}" == "# broken: UNREADABLE RECORD" ]]; then
  _ok "verdict line for a malformed record"
else
  _no "verdict line for a malformed record"
fi

# An empty XDG_CONFIG_HOME falls back to ~/.config, as pangram_check.py does.
got="$(XDG_CONFIG_HOME='' _checks_dir)"
if [[ "${got}" == "${HOME}/.config/personify/checks" ]]; then
  _ok "empty XDG_CONFIG_HOME falls back to ~/.config"
else
  _no "empty XDG_CONFIG_HOME falls back to ~/.config"
fi

# Verdict lines sit in the framing header and must not reach approved bytes.
V="${TMP}/v.txt"
printf 'fix(v): body under a verdict header\n' >"${V}"
rm -f "${APPROVED:?}"/*
{
  echo "# STATUS: APPROVED"
  echo "# PANGRAM (proof the check ran; the verdict is information):"
  echo "# item-v: FAIL (AI, fraction_ai 1.0, 212 words)"
  echo "# BATCH: vh"
  echo ""
  echo "=== item-v ==="
  cat "${V}"
} >"${GATE_REVIEW_DIR}/batch.txt"
_split_batch "${GATE_REVIEW_DIR}/batch.txt" vh >/dev/null 2>&1
if _cmd_check "${V}"; then
  _ok "verdict header lines leave approved bytes unchanged"
else
  _no "verdict header lines leave approved bytes unchanged"
fi

echo "--- ${pass} passed, ${fail} failed"
[[ "${fail}" == "0" ]]
