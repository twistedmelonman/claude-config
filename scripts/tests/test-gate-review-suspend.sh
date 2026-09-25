#!/usr/bin/env bash
# gate-review.sh suspended: a hand-written SUSPENDED file holding one date
# turns the gate off through the end of that local day, and nothing else does.
#
# Drives the real dispatcher (`gate-review.sh suspended`) against a fixture
# GATE_REVIEW_DIR, never the live one. Most cases here must NOT suspend: the
# feature fails closed, and each refusal below is an input that a looser
# parser would have read as "off".

set -uo pipefail
unset CDPATH

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gate-review.sh"
[[ -x "${GATE}" ]] || {
  echo "cannot find executable gate-review.sh at ${GATE}" >&2
  exit 1
}
TMP="$(mktemp -d)"
trap 'chmod -R u+rw "${TMP}" 2>/dev/null; rm -rf "${TMP}"' EXIT

export GATE_REVIEW_DIR="${TMP}/gate"
mkdir -p "${GATE_REVIEW_DIR}"
SUSP="${GATE_REVIEW_DIR}/SUSPENDED"

pass=0
fail=0

# Local date N days from today. BSD first: on BSD, `date -d` is not a parse
# flag at all.
_day() {
  local n="$1"
  date -v"${n}"d +%F 2>/dev/null || date -d "${n} days" +%F
}

TODAY="$(date +%F)"
YESTERDAY="$(_day -1)"
TOMORROW="$(_day +1)"

# want: 0 = suspended, 1 = armed.
_expect() {
  local desc="$1" want="$2" got
  "${GATE}" suspended >"${TMP}/out" 2>"${TMP}/err"
  got=$?
  if [[ "${got}" == "${want}" ]]; then
    echo "  PASS (${got}) ${desc}"
    pass=$((pass + 1))
  else
    echo "  FAIL (got ${got} want ${want}) ${desc}"
    fail=$((fail + 1))
  fi
}

_set() {
  printf '%s' "$1" >"${SUSP}"
}

echo "=== suspended: active ==="
_set "${TOMORROW}"$'\n'
_expect "tomorrow" 0
# The notice is the whole point of "never silent": check its text, not just
# that stderr is non-empty.
if grep -qF "[personify-gate] SUSPENDED until ${TOMORROW} (${SUSP})" "${TMP}/err"; then
  echo "  PASS notice names the expiry and the file"
  pass=$((pass + 1))
else
  echo "  FAIL notice names the expiry and the file (stderr: $(<"${TMP}/err"))"
  fail=$((fail + 1))
fi
if [[ ! -s "${TMP}/out" ]]; then
  echo "  PASS notice goes to stderr, not stdout"
  pass=$((pass + 1))
else
  echo "  FAIL notice goes to stderr, not stdout"
  fail=$((fail + 1))
fi
_set "${TODAY}"$'\n'
_expect "today (expiry is inclusive)" 0
_set "${TODAY}"
_expect "today, no trailing newline" 0
_set "${TODAY}  "$'\n\n'
_expect "today, trailing blanks and blank lines" 0
_set "2096-02-29"
_expect "leap day in a leap year" 0

echo "=== suspended: armed (fail closed) ==="
_set "${YESTERDAY}"$'\n'
_expect "yesterday (expired)" 1
if [[ ! -s "${TMP}/err" ]]; then
  echo "  PASS an expired file prints no notice"
  pass=$((pass + 1))
else
  echo "  FAIL an expired file prints no notice"
  fail=$((fail + 1))
fi
rm -f "${SUSP}"
_expect "file missing" 1
_set ""
_expect "file empty" 1
_set $'\n'
_expect "file holds only a newline" 1
_set "2099-02-31"
_expect "impossible date 2099-02-31" 1
_set "2099-04-31"
_expect "impossible date 2099-04-31" 1
_set "2097-02-29"
_expect "leap day in a non-leap year" 1
_set "2100-02-29"
_expect "leap day in a century non-leap year" 1
_set "2099-13-01"
_expect "month 13" 1
_set "2099-00-10"
_expect "month 00" 1
_set "2099-01-00"
_expect "day 00" 1
_set "2099-9-30"
_expect "unpadded month" 1
_set "2099/09/30"
_expect "slashes" 1
_set "tomorrow"
_expect "a word, not a date" 1
_set " ${TOMORROW}"
_expect "leading whitespace" 1
_set "${TOMORROW}x"
_expect "trailing junk" 1
_set "${TOMORROW}"$'\n'"${TOMORROW}"$'\n'
_expect "two lines" 1
_set "${TOMORROW}"$'\n'"extra"
_expect "a date then a second line" 1
rm -f "${SUSP}"
mkdir "${SUSP}"
_expect "SUSPENDED is a directory" 1
rmdir "${SUSP}"
_set "${TOMORROW}"
chmod 000 "${SUSP}"
if [[ -r "${SUSP}" ]]; then
  echo "  SKIP unreadable file (running as a user that can read mode 000)"
else
  _expect "unreadable file" 1
fi
chmod 600 "${SUSP}"
rm -f "${SUSP}"

echo "--- ${pass} passed, ${fail} failed"
[[ "${fail}" == "0" ]]
