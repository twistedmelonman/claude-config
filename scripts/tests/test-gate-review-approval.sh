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
# The buffer the _split_batch cases hand it directly. Any path works: the
# per-batch naming under batches/ is exercised through _cmd_open below.
BUF="${TMP}/buffer.txt"

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
  # The TTL constant sits above _die(), outside the sed range. Take the real
  # line rather than a copy, so the default under test is the shipped one.
  local ttl_line
  ttl_line="$(grep -m1 '^APPROVAL_TTL=' "${GATE}")" || {
    echo "no APPROVAL_TTL line in ${GATE}" >&2
    exit 1
  }
  eval "${ttl_line}"
}

_batch() {
  local status="$1" nonce="$2" body="${3:-body text}"
  cat >"${BUF}" <<EOF
# STATUS: ${status}
# BATCH: ${nonce}

=== item-one ===
${body}
EOF
}

_load
# Set by the sourced _classify; declared here so the reads below are not
# reads of an unassigned name.
CLASS=""
CLASS_WHY=""

# --- _status ----------------------------------------------------------------

_batch PENDING n1
if [[ "$(_status "${BUF}")" == "PENDING" ]]; then
  _ok "PENDING reads as PENDING"
else
  _no "PENDING reads as PENDING"
fi

_batch APPROVED n1
if [[ "$(_status "${BUF}")" == "APPROVED" ]]; then
  _ok "APPROVED reads as APPROVED"
else
  _no "APPROVED reads as APPROVED"
fi

_batch approved n1
if [[ "$(_status "${BUF}")" == "APPROVED" ]]; then
  _ok "lowercase approved is accepted"
else
  _no "lowercase approved is accepted"
fi

# A buffer with no status line must not read as approval.
printf 'no status line here\n' >"${BUF}"
if [[ "$(_status "${BUF}")" == "PENDING" ]]; then
  _ok "missing STATUS line falls back to PENDING"
else
  _no "missing STATUS line falls back to PENDING"
fi

# --- _split_batch nonce binding ---------------------------------------------

_batch APPROVED right-nonce
rm -f "${APPROVED:?}"/*
if _split_batch "${BUF}" right-nonce >/dev/null 2>&1 &&
  [[ -f "${APPROVED}/item-one" ]]; then
  _ok "matching batch id splits"
else
  _no "matching batch id splits"
fi

# The 2026-09-18 forged approval: a stale run splitting a batch it did not write.
# _die exits, so run the refusal in a subshell or it takes the test with it.
_batch APPROVED right-nonce
rm -f "${APPROVED:?}"/*
if (_split_batch "${BUF}" stale-nonce >/dev/null 2>&1); then
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
_split_batch "${BUF}" n2 >/dev/null 2>&1
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
  } >"${BUF}"
}

A="${TMP}/a.txt"
B="${TMP}/b.txt"
printf 'fix(one): first body\n' >"${A}"
printf 'fix(two): second body\n' >"${B}"
rm -f "${APPROVED:?}"/*
_multi_batch rt "${A}" "${B}"
_split_batch "${BUF}" rt >/dev/null 2>&1

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
} >"${BUF}"
_split_batch "${BUF}" nl >/dev/null 2>&1
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
_split_batch "${BUF}" later >/dev/null 2>&1
if [[ -f "${APPROVED}/from-an-earlier-batch" ]]; then
  _ok "a new batch leaves an earlier batch's approval standing"
else
  _no "a new batch leaves an earlier batch's approval standing"
fi

# Emptying an item in the editor is how a reviewer drops it. That must REVOKE
# a prior approval of the same name, not leave the old one in place.
rm -f "${APPROVED:?}"/*
_batch APPROVED rev1 'original body'
_split_batch "${BUF}" rev1 >/dev/null 2>&1
cat >"${BUF}" <<'EOF'
# STATUS: APPROVED
# BATCH: rev2

=== item-one ===
EOF
_split_batch "${BUF}" rev2 >/dev/null 2>&1
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

# The refusal names the INSTALLED personify, not a placeholder. The cache keeps
# old versions beside it, and on 2026-09-24 a guessed 2.0.1 (no Keychain
# lookup) reported a missing key that the installed 2.0.3 found.
PLUGINS="${TMP}/claude/plugins"
mkdir -p "${PLUGINS}/cache/personify/2.0.1/scripts" "${PLUGINS}/cache/personify/2.0.3/scripts"
touch "${PLUGINS}/cache/personify/2.0.1/scripts/pangram_check.py" \
  "${PLUGINS}/cache/personify/2.0.3/scripts/pangram_check.py"
printf '{"plugins":{"personify@personify":[{"installPath":"%s"}]}}\n' \
  "${PLUGINS}/cache/personify/2.0.3" >"${PLUGINS}/installed_plugins.json"
got="$( (CLAUDE_CONFIG_DIR="${TMP}/claude" _cmd_stage unchecked "${UNCHECKED}") 2>&1 >/dev/null || true)"
if [[ "${got}" == *"python3 ${PLUGINS}/cache/personify/2.0.3/scripts/pangram_check.py < ${UNCHECKED}"* ]]; then
  _ok "refusal names the installed pangram_check.py"
else
  _no "refusal names the installed pangram_check.py: ${got}"
fi
if [[ "${got}" != *"2.0.1"* && "${got}" != *"<personify skill dir>"* ]]; then
  _ok "refusal names no other version and no placeholder"
else
  _no "refusal names no other version and no placeholder: ${got}"
fi

# No personify entry: say so, rather than print a command that cannot run.
printf '{"plugins":{}}\n' >"${PLUGINS}/installed_plugins.json"
got="$( (CLAUDE_CONFIG_DIR="${TMP}/claude" _cmd_stage unchecked "${UNCHECKED}") 2>&1 >/dev/null || true)"
if [[ "${got}" == *"personify is not installed"* && "${got}" != *"python3 "* ]]; then
  _ok "refusal says personify is not installed when it is not"
else
  _no "refusal says personify is not installed when it is not: ${got}"
fi

# An entry whose directory is gone counts as not installed too.
printf '{"plugins":{"personify@personify":[{"installPath":"%s"}]}}\n' \
  "${PLUGINS}/cache/personify/9.9.9" >"${PLUGINS}/installed_plugins.json"
got="$( (CLAUDE_CONFIG_DIR="${TMP}/claude" _cmd_stage unchecked "${UNCHECKED}") 2>&1 >/dev/null || true)"
if [[ "${got}" == *"personify is not installed"* ]]; then
  _ok "refusal says not installed when installPath is missing"
else
  _no "refusal says not installed when installPath is missing: ${got}"
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
} >"${BUF}"
_split_batch "${BUF}" vh >/dev/null 2>&1
if _cmd_check "${V}"; then
  _ok "verdict header lines leave approved bytes unchanged"
else
  _no "verdict header lines leave approved bytes unchanged"
fi

# --- approvals expire after APPROVAL_TTL -------------------------------------

# An approval used to last until cleared by hand, so text approved days ago
# could still be replayed. Age is the approved file's mtime.
_age_minutes() {
  # UTC on both sides, so a DST change cannot shift the age by an hour.
  local now stamp
  now="$(date +%s)" || return 1
  stamp="$(TZ=UTC0 date -r "$((now - $2 * 60))" +%Y%m%d%H%M.%S 2>/dev/null ||
    TZ=UTC0 date -d "@$((now - $2 * 60))" +%Y%m%d%H%M.%S)" || return 1
  TZ=UTC0 touch -t "${stamp}" "$1"
}

TTL_BODY="${TMP}/ttl.txt"
printf 'fix(ttl): body under test\n' >"${TTL_BODY}"

rm -f "${APPROVED:?}"/*
cp "${TTL_BODY}" "${APPROVED}/fresh"
if _cmd_check "${TTL_BODY}"; then
  _ok "a fresh approval verifies"
else
  _no "a fresh approval verifies"
fi

rm -f "${APPROVED:?}"/*
cp "${TTL_BODY}" "${APPROVED}/at-29"
_age_minutes "${APPROVED}/at-29" 29
if _cmd_check "${TTL_BODY}"; then
  _ok "a 29-minute-old approval still verifies"
else
  _no "a 29-minute-old approval still verifies"
fi

rm -f "${APPROVED:?}"/*
cp "${TTL_BODY}" "${APPROVED}/at-31"
_age_minutes "${APPROVED}/at-31" 31
if _cmd_check "${TTL_BODY}"; then
  _no "a 31-minute-old approval is refused"
else
  _ok "a 31-minute-old approval is refused"
fi
if [[ -e "${APPROVED}/at-31" ]]; then
  _no "check deletes the expired approval"
else
  _ok "check deletes the expired approval"
fi

# The override goes through the real entry point, so it exercises the
# constant's own line rather than the value _load copied.
rm -f "${APPROVED:?}"/*
cp "${TTL_BODY}" "${APPROVED}/at-2"
_age_minutes "${APPROVED}/at-2" 2
if GATE_REVIEW_APPROVAL_TTL=60 bash "${GATE}" check "${TTL_BODY}"; then
  _no "GATE_REVIEW_APPROVAL_TTL=60 refuses a 2-minute-old approval"
else
  _ok "GATE_REVIEW_APPROVAL_TTL=60 refuses a 2-minute-old approval"
fi
# The run above pruned it, so put it back at the same age.
cp "${TTL_BODY}" "${APPROVED}/at-2"
_age_minutes "${APPROVED}/at-2" 2
if bash "${GATE}" check "${TTL_BODY}"; then
  _ok "the default TTL accepts the same 2-minute-old approval"
else
  _no "the default TTL accepts the same 2-minute-old approval"
fi

# stage prunes too, so approved/ stops growing even when nothing is checked.
rm -f "${APPROVED:?}"/* "${PENDING:?}"/*
printf 'stale\n' >"${APPROVED}/stale"
_age_minutes "${APPROVED}/stale" 31
printf 'fresh\n' >"${APPROVED}/fresh"
_seed_record "${TTL_BODY}" '{"status":"PASS","verdict":"Human","fraction_ai":0.0,"word_count":4}'
if bash "${GATE}" stage ttl-item "${TTL_BODY}" >/dev/null 2>&1; then
  _ok "stage succeeds with expired approvals present"
else
  _no "stage succeeds with expired approvals present"
fi
if [[ ! -e "${APPROVED}/stale" ]]; then
  _ok "stage prunes an expired approval"
else
  _no "stage prunes an expired approval"
fi
if [[ -f "${APPROVED}/fresh" ]]; then
  _ok "stage leaves a fresh approval standing"
else
  _no "stage leaves a fresh approval standing"
fi

# --- open: each batch gets its own file ------------------------------------

# Every `open` used to write and open one shared ${GATE_DIR}/batch.txt, so
# BBEdit could show or save a buffer that belonged to another batch. Each batch
# now gets a file named for the caller's repo and branch plus its nonce.
#
# Driven through _cmd_open with the GUI stubbed by executables on PATH:
# launchctl reports Aqua, pgrep finds no other open, and `open` records the
# path it was handed and then plays the human, writing the status word into
# that file. The status poll then sees it on its first pass.
export EDITOR_APP=stub-editor POLL_TIMEOUT=6
export OPENED_LOG="${TMP}/opened.log" STUB_STATUS=APPROVED
STUB_BIN="${TMP}/stub-bin"
mkdir -p "${STUB_BIN}"
printf '#!/usr/bin/env bash\necho Aqua\n' >"${STUB_BIN}/launchctl"
printf '#!/usr/bin/env bash\nexit 1\n' >"${STUB_BIN}/pgrep"
cat >"${STUB_BIN}/open" <<'STUB'
#!/usr/bin/env bash
f="${*: -1}"
printf '%s\n' "${f}" >>"${OPENED_LOG}"
sed -i.bak "s/^# STATUS: PENDING/# STATUS: ${STUB_STATUS}/" "${f}" && rm -f "${f}.bak"
# A second save, later: the reviewer fixing a word the poll did not accept.
# The redirect is load-bearing: without it the background child holds the
# caller's $(...) pipe open.
if [[ -n "${STUB_STATUS_LATER:-}" ]]; then
  (sleep 3 && sed -i.bak "s/^# STATUS: .*/# STATUS: ${STUB_STATUS_LATER}/" "${f}" &&
    rm -f "${f}.bak") >/dev/null 2>&1 &
fi
STUB
chmod +x "${STUB_BIN}"/*

_mkrepo() {
  mkdir -p "$1"
  command git -C "$1" init -q -b "$2"
}

# Run one open from $1 with one staged item; print the path it opened.
_open_from() {
  local rc=0
  : >"${OPENED_LOG}"
  printf 'fix(x): staged from %s\n' "$1" >"${PENDING}/item"
  (cd "$1" && PATH="${STUB_BIN}:${PATH}" && _cmd_open) >"${OPEN_OUT:-/dev/null}" 2>&1 || rc=$?
  cat "${OPENED_LOG}"
  return "${rc}"
}

rm -f "${APPROVED:?}"/* "${PENDING:?}"/*
_mkrepo "${TMP}/repos/alpha" main
_mkrepo "${TMP}/repos/beta" feat/x
_mkrepo "${TMP}/repos/weird name" 'fix/a+b'
mkdir -p "${TMP}/nogit"
# A stand-in for another batch's file: cleanup must never touch it.
mkdir -p "${GATE_REVIEW_DIR}/batches"
printf 'another batch\n' >"${GATE_REVIEW_DIR}/batches/other-main-1-1.txt"

P1="$(_open_from "${TMP}/repos/alpha")" || true
P2="$(_open_from "${TMP}/repos/beta")" || true
if [[ -n "${P1}" && -n "${P2}" && "${P1}" != "${P2}" ]]; then
  _ok "batches from different repos/branches get different files"
else
  _no "batches from different repos/branches get different files (got '${P1}' and '${P2}')"
fi
if [[ "${P1}" == "${GATE_REVIEW_DIR}/batches/alpha-main-"*.txt ]]; then
  _ok "the batch file is named <repo>-<branch>-<nonce>.txt under batches/"
else
  _no "the batch file is named <repo>-<branch>-<nonce>.txt under batches/ (got '${P1}')"
fi
if [[ "${P2##*/}" == beta-feat-x-*.txt ]]; then
  _ok "a / in the branch name is sanitized"
else
  _no "a / in the branch name is sanitized (got '${P2##*/}')"
fi
P3="$(_open_from "${TMP}/repos/weird name")" || true
if [[ "${P3##*/}" =~ ^[A-Za-z0-9._-]+\.txt$ && "${P3##*/}" == weird-name-fix-a-b-* ]]; then
  _ok "spaces and / in repo and branch are sanitized"
else
  _no "spaces and / in repo and branch are sanitized (got '${P3##*/}')"
fi
P4="$(_open_from "${TMP}/nogit")" || true
if [[ "${P4}" == "${GATE_REVIEW_DIR}/batches/batch-"*.txt ]]; then
  _ok "outside a git repo the file falls back to batch-<nonce>.txt"
else
  _no "outside a git repo the file falls back to batch-<nonce>.txt (got '${P4}')"
fi
if [[ -f "${APPROVED}/item" ]] && grep -q 'nogit' "${APPROVED}/item"; then
  _ok "an approved open still splits its own batch"
else
  _no "an approved open still splits its own batch"
fi
if [[ -n "${P1}" && ! -e "${P1}" && -n "${P4}" && ! -e "${P4}" ]]; then
  _ok "a split batch's file is removed"
else
  _no "a split batch's file is removed"
fi
if [[ -f "${GATE_REVIEW_DIR}/batches/other-main-1-1.txt" ]]; then
  _ok "cleanup leaves other batches' files alone"
else
  _no "cleanup leaves other batches' files alone"
fi
if [[ ! -e "${GATE_REVIEW_DIR}/batch.txt" ]]; then
  _ok "no shared batch.txt is written"
else
  _no "no shared batch.txt is written"
fi

# ABORT still wipes every approval, and its batch file goes too.
printf 'keep?\n' >"${APPROVED}/earlier"
STUB_STATUS=ABORT
rc5=0
P5="$(_open_from "${TMP}/repos/alpha")" || rc5=$?
if [[ "${rc5}" != 0 ]] && ! compgen -G "${APPROVED}/*" >/dev/null; then
  _ok "ABORT approves nothing and wipes approved/"
else
  _no "ABORT approves nothing and wipes approved/"
fi
if [[ -n "${P5}" && ! -e "${P5}" ]]; then
  _ok "an aborted batch's file is removed"
else
  _no "an aborted batch's file is removed (got '${P5}')"
fi
STUB_STATUS=APPROVED

# The nonce still binds the file to its process: a buffer carrying another
# batch's id is refused even under the new per-batch path.
rm -f "${APPROVED:?}"/*
FOREIGN="${GATE_REVIEW_DIR}/batches/alpha-main-9-9.txt"
printf '# STATUS: APPROVED\n# BATCH: 9-9\n\n=== item ===\nforeign\n' >"${FOREIGN}"
if (_split_batch "${FOREIGN}" 1-1 >/dev/null 2>&1); then
  _no "a per-batch file with a foreign nonce is refused"
else
  _ok "a per-batch file with a foreign nonce is refused"
fi
if [[ ! -e "${APPROVED}/item" ]]; then
  _ok "the refused foreign buffer approves nothing"
else
  _no "the refused foreign buffer approves nothing"
fi

# --- near-miss status words (claude-config#559) -----------------------------

# The distance arithmetic, against hand-computed values. A swap of two
# adjacent letters is one edit; UNAPPROVED is two insertions.
for row in APPORVED:APPROVED:1 APPROVDE:APPROVED:1 APROVED:APPROVED:1 \
  APPROVEDD:APPROVED:1 APPRVOED:APPROVED:1 UNAPPROVED:APPROVED:2 \
  APPROVAL:APPROVED:2 ABOUT:ABORT:1 ABORTED:ABORT:2 APPROVED:APPROVED:0; do
  IFS=: read -r a b want <<<"${row}"
  got="$(_edit_distance "${a}" "${b}")"
  if [[ "${got}" == "${want}" ]]; then
    _ok "distance ${a} -> ${b} is ${want}"
  else
    _no "distance ${a} -> ${b} is ${want} (got ${got})"
  fi
done

# Forms that approve. Each is one edit or trailing . or ! from APPROVED.
for w in APPROVED APPROVED. 'APPROVED!!' APPORVED APPROVDE APROVED APPROVEDD \
  APPROVES APPROVER PAPROVED; do
  _classify "${w}"
  if [[ "${CLASS}" == "APPROVED" ]]; then
    _ok "'${w}' reads as APPROVED"
  else
    _no "'${w}' reads as APPROVED (got ${CLASS}: ${CLASS_WHY})"
  fi
done

# Forms that must NOT approve. Near-ABORT words abort; everything else is
# unrecognized (or PENDING), which approves nothing.
for row in ABORT:ABORT ABROT:ABORT ABOT:ABORT ABORT.:ABORT \
  PENDING:PENDING PENDIGN:PENDING PENDNG:PENDING \
  UNAPPROVED:UNRECOGNIZED DISAPPROVED:UNRECOGNIZED NOTAPPROVED:UNRECOGNIZED \
  'NOT APPROVED':UNRECOGNIZED 'APPROVED NOT':UNRECOGNIZED \
  'APPROVED?':UNRECOGNIZED 'APPROVED - BUT':UNRECOGNIZED \
  'APPROVED,':UNRECOGNIZED APPROVAL:UNRECOGNIZED \
  APRVOED:UNRECOGNIZED APPRVD:UNRECOGNIZED PPROVE:UNRECOGNIZED \
  APPROVEDXYZ:UNRECOGNIZED ABORTED:UNRECOGNIZED YES:UNRECOGNIZED \
  OK:UNRECOGNIZED LGTM:UNRECOGNIZED XYZZY:UNRECOGNIZED :UNRECOGNIZED \
  ...:UNRECOGNIZED APPROVEDAPPROVED:UNRECOGNIZED; do
  w="${row%:*}"
  want="${row##*:}"
  _classify "${w}"
  if [[ "${CLASS}" == "${want}" ]]; then
    _ok "'${w}' reads as ${want}, not APPROVED"
  else
    _no "'${w}' reads as ${want}, not APPROVED (got ${CLASS}: ${CLASS_WHY})"
  fi
done

# Through open: a transposition approves, and the output names the word read.
rm -f "${APPROVED:?}"/* "${PENDING:?}"/*
STUB_STATUS=APPORVED
OUT="${TMP}/open-out.txt"
export OPEN_OUT="${OUT}"
rc6=0
P6="$(_open_from "${TMP}/repos/alpha")" || rc6=$?
if [[ "${rc6}" == 0 && -f "${APPROVED}/item" && -n "${P6}" && ! -e "${P6}" ]]; then
  _ok "open: STATUS APPORVED approves the batch"
else
  _no "open: STATUS APPORVED approves the batch (rc ${rc6})"
fi
if grep -q "STATUS read as 'APPORVED'" "${OUT}"; then
  _ok "open: a fuzzy approve prints the word it read"
else
  _no "open: a fuzzy approve prints the word it read"
fi

# Through open: a garbage word approves nothing, keeps the batch file, and
# says why, instead of ending the wait at once.
rm -f "${APPROVED:?}"/* "${PENDING:?}"/*
STUB_STATUS=APROVDE
POLL_TIMEOUT=4
rc7=0
P7="$(_open_from "${TMP}/repos/alpha")" || rc7=$?
if [[ "${rc7}" != 0 ]] && ! compgen -G "${APPROVED}/*" >/dev/null && [[ -f "${PENDING}/item" ]]; then
  _ok "open: a 2-edit word (APROVDE) approves nothing and leaves the item pending"
else
  _no "open: a 2-edit word (APROVDE) approves nothing and leaves the item pending (rc ${rc7})"
fi
n_reported="$(grep -c "read STATUS 'APROVDE'; not understood" "${OUT}" || true)"
if [[ "${n_reported}" == 1 ]]; then
  _ok "open: an unrecognized word is reported once, with the reason"
else
  _no "open: an unrecognized word is reported once, with the reason"
fi
if [[ -n "${P7}" && -e "${P7}" ]]; then
  _ok "open: an unrecognized timeout keeps the batch file"
else
  _no "open: an unrecognized timeout keeps the batch file"
fi

# Through open: fixing the word and saving again approves the same batch.
rm -f "${APPROVED:?}"/* "${PENDING:?}"/*
STUB_STATUS=XYZZY
export STUB_STATUS_LATER=APPROVED
POLL_TIMEOUT=10
rc8=0
P8="$(_open_from "${TMP}/repos/alpha")" || rc8=$?
if [[ "${rc8}" == 0 && -f "${APPROVED}/item" && -n "${P8}" && ! -e "${P8}" ]] &&
  grep -q "not understood" "${OUT}"; then
  _ok "open: a garbage word keeps waiting, and a corrected save approves"
else
  _no "open: a garbage word keeps waiting, and a corrected save approves (rc ${rc8})"
fi
unset STUB_STATUS_LATER OPEN_OUT
STUB_STATUS=APPROVED
POLL_TIMEOUT=6

echo "--- ${pass} passed, ${fail} failed"
[[ "${fail}" == "0" ]]
