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
#   gate-review.sh stage <name> <file>   queue one artifact for review (needs a Pangram check record)
#   gate-review.sh open                  open the batch, wait for save
#   gate-review.sh hash <file>           print the approved-bytes hash
#   gate-review.sh check <file>          exit 0 if file matches ANY approval
#   gate-review.sh suspended             exit 0 if the gate is suspended today
#
# `check` takes no name. It hashes the input and accepts if any approved
# artifact hashes the same, which dissolves the "which approval does this
# commit correspond to" question rather than answering it: the hook sees only a
# command string, and a name it had to infer from that string would be a guess
# the human never made. The batch names are labels for reading the buffer, not
# a mapping anything depends on.

set -euo pipefail
unset CDPATH

GATE_DIR="${GATE_REVIEW_DIR:-${HOME}/.claude/gate-review}"
PENDING="${GATE_DIR}/pending"
APPROVED="${GATE_DIR}/approved"
EDITOR_APP="${GATE_REVIEW_EDITOR:-BBEdit}"
POLL_TIMEOUT="${GATE_REVIEW_TIMEOUT:-1800}"
APPROVAL_TTL="${GATE_REVIEW_APPROVAL_TTL:-1800}"

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
#
# The `$(...)` is load-bearing: it strips ALL trailing newlines, which the sed
# alone does not. _cmd_open writes a blank line before each `=== name ===`
# header, so every artifact but the last came back from _split_batch carrying
# one extra newline, and `check <the file that was staged>` failed for all of
# them. Measured 2026-09-18: staged bytes ended `body\n`, approved bytes ended
# `body\n\n`, and only the last item in a batch ever verified. Both sides must
# normalize identically or the round trip this tool exists to perform does not
# close.
_hash() {
  printf '%s' "$(sed -e 's/[[:space:]]*$//' "$1")" | sha256sum | cut -d' ' -f1
}

# Where personify's pangram_check.py records every result. Mirrors its
# config_root: an empty XDG_CONFIG_HOME falls through to ~/.config. Computed
# per call, not at load, so a test can point it at a fixture dir.
_checks_dir() {
  printf '%s/personify/checks' "${XDG_CONFIG_HOME:-${HOME}/.config}"
}

# The record key is the sha256 of the RAW bytes, which is what the check hashed
# from stdin. Not _hash: stripping trailing whitespace here would miss every
# record for a file that ends in a blank line.
_raw_sha() {
  sha256sum "$1" | cut -d' ' -f1
}

# The command that writes a check record, with the path of the personify
# version Claude Code has installed. The plugin cache keeps every past version
# side by side, and a guessed one can predate a feature the check now needs:
# 2.0.1 has no Keychain lookup, so on 2026-09-24 it reported "no Pangram API
# key found" on a machine whose key was in the Keychain. Computed per call so a
# test can point CLAUDE_CONFIG_DIR at a fixture.
_check_hint() {
  local file="$1" plugins install_path
  plugins="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/plugins/installed_plugins.json"
  install_path="$(jq -er '.plugins["personify@personify"][0].installPath // empty' \
    "${plugins}" 2>/dev/null)" || install_path=""
  if [[ -n "${install_path}" && -f "${install_path}/scripts/pangram_check.py" ]]; then
    printf 'python3 %s/scripts/pangram_check.py < %s\n' "${install_path}" "${file}"
  else
    printf 'personify is not installed (no personify@personify with scripts/pangram_check.py in %s); install it with: claude plugin install personify@personify\n' \
      "${plugins}"
  fi
}

_record_path() {
  local dir sha
  dir="$(_checks_dir)"
  sha="$(_raw_sha "$1")"
  printf '%s/%s.json' "${dir}" "${sha}"
}

# One header line per item. Never fails: a missing or unreadable record is
# shown, not fatal, because stage already enforced that the check ran.
_verdict_line() {
  local name="$1" file="$2" record line
  record="$(_record_path "${file}")"
  if [[ ! -f "${record}" ]]; then
    printf '# %s: NO RECORD\n' "${name}"
    return 0
  fi
  if line="$(jq -er --arg n "${name}" '
      if .status == "SKIPPED"
      then "# \($n): SKIPPED (\(.word_count) words, under the floor)"
      else "# \($n): \(.status) (\(.verdict), fraction_ai \(.fraction_ai), \(.word_count) words)"
      end' "${record}" 2>/dev/null)"; then
    printf '%s\n' "${line}"
  else
    printf '# %s: UNREADABLE RECORD\n' "${name}"
  fi
}

_cmd_stage() {
  local name="$1" file="$2" record
  [[ -f "${file}" ]] || _die "no such file: ${file}"
  [[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || _die "bad artifact name: ${name}"
  # The reviewer should see what Pangram said before approving, so a text the
  # check never saw is not staged. Any result counts, FAIL and SKIPPED
  # included: this proves the check ran, it does not require a pass.
  _prune_expired
  record="$(_record_path "${file}")"
  if [[ ! -f "${record}" ]]; then
    local hint
    hint="$(_check_hint "${file}")"
    {
      echo "gate-review: no Pangram check record for ${file}."
      echo "gate-review: run the personify check on this exact file, then stage again:"
      echo "gate-review:   ${hint}"
      echo "gate-review: PASS, FAIL, and SKIPPED all leave a record; an error does not."
    } >&2
    exit 1
  fi
  cp "${file}" "${PENDING}/${name}"
  printf 'staged: %s\n' "${name}"
}

# Where this batch's buffer lives: one file per batch, named for the caller's
# repo and branch so the BBEdit window title says whose text it is. Every
# batch used to share ${GATE_DIR}/batch.txt, so BBEdit could show, or save
# over, a buffer that belonged to another batch.
#
# No PR number: finding one means a network call (`gh pr view`) inside the
# approval path, which can hang or prompt for auth. The branch already names
# the PR, and the nonce makes the name unique.
#
# Every component is reduced to [A-Za-z0-9._-]: branch names carry `/`, and a
# repo directory can hold spaces.
_batch_path() {
  local nonce="$1" dir top repo branch
  dir="${GATE_DIR}/batches"
  mkdir -p "${dir}"
  nonce="${nonce//[^A-Za-z0-9._-]/-}"
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
  if [[ -z "${top}" ]]; then
    printf '%s/batch-%s.txt\n' "${dir}" "${nonce}"
    return 0
  fi
  repo="${top##*/}"
  repo="${repo//[^A-Za-z0-9._-]/-}"
  branch="$(git branch --show-current 2>/dev/null)" || branch=""
  if [[ -z "${branch}" ]]; then
    branch="$(git rev-parse --short HEAD 2>/dev/null)" || branch="unborn"
    branch="detached-${branch}"
  fi
  branch="${branch//[^A-Za-z0-9._-]/-}"
  printf '%s/%s-%s-%s.txt\n' "${dir}" "${repo}" "${branch}" "${nonce}"
}

_cmd_open() {
  local batch count waited=0 nonce status

  count=$(find "${PENDING}" -type f | wc -l | tr -d ' ')
  ((count > 0)) || _die "nothing staged"

  _require_gui

  # A per-batch file keeps two batches out of one editor buffer, but pending/
  # and approved/ are still shared by every session. A second `open` running
  # at the same time would batch the same staged items and could approve them
  # first. Measured 2026-09-18, back when both also shared one batch.txt: a
  # stale poller from an interrupted session split a newer batch and reported
  # it approved, with no human involved at all.
  _refuse_if_open

  # Bound this batch to this process. _split_batch refuses a buffer carrying a
  # different id, so a stale poller cannot approve text it never wrote.
  nonce="$$-$(date +%s)"
  batch="$(_batch_path "${nonce}")"

  # One buffer for the whole set: the reviewer reads and edits everything in a
  # single pass, which is the point of batching.
  {
    echo "# STATUS: PENDING"
    echo "#"
    echo "# REVIEW THESE ${count} ITEM(S), EDIT FREELY."
    echo "#"
    echo "# PANGRAM (proof the check ran; the verdict is information):"
    for f in "${PENDING}"/*; do
      _verdict_line "${f##*/}" "${f}"
    done
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
  #
  # A word that is neither keyword nor a near-miss of one does not end the
  # wait. It used to: a typo like APPORVED died as "unrecognized", and the
  # whole batch had to be staged and opened again (claude-config#559). Now the
  # word is reported once, and the reviewer fixes it and saves again.
  printf 'waiting for APPROVED or ABORT (timeout %ss)...\n' "${POLL_TIMEOUT}" >&2
  local reported=""
  CLASS=PENDING
  CLASS_WHY=""
  while ((waited < POLL_TIMEOUT)); do
    sleep 2
    waited=$((waited + 2))
    status="$(_status "${batch}")"
    _classify "${status}"
    [[ "${CLASS}" == "APPROVED" || "${CLASS}" == "ABORT" ]] && break
    if [[ "${CLASS}" == "UNRECOGNIZED" && "${status}" != "${reported}" ]]; then
      printf "gate-review: read STATUS '%s'; not understood (%s). Nothing approved. Still waiting: fix the word and save again.\n" \
        "${status}" "${CLASS_WHY}" >&2
      reported="${status}"
    fi
  done

  case "${CLASS}" in
    APPROVED) ;;
    ABORT)
      rm -f "${APPROVED:?}"/*
      rm -f "${batch}"
      _die "ABORT (STATUS read as '${status}'); nothing approved"
      ;;
    PENDING)
      _die "still PENDING after ${POLL_TIMEOUT}s; nothing approved"
      ;;
    *)
      _die "unrecognized status '${status}' after ${POLL_TIMEOUT}s (${CLASS_WHY}); nothing approved"
      ;;
  esac

  _split_batch "${batch}" "${nonce}"
  # Only this batch's own file, and only once it is consumed, so batches/ does
  # not grow without bound. A PENDING timeout or a refused split leaves the
  # file in place: the reviewer may still have it open, and its unique name
  # means no later batch can pick it up.
  rm -f "${batch}"
  # The word actually read, so a fuzzy accept is visible rather than silent.
  local approved_count
  approved_count="$(find "${APPROVED}" -type f | wc -l | tr -d ' ')"
  printf "approved %s item(s) (STATUS read as '%s'%s)\n" \
    "${approved_count}" "${status}" "${CLASS_WHY:+; ${CLASS_WHY}}"
}

# Optimal-string-alignment distance: Levenshtein plus one edit for swapping
# two adjacent letters. That swap is the common typo (APPORVED, APPROVDE), and
# counting it as one edit lets the approve threshold stay at 1, which plain
# Levenshtein could not: it scores the swap as 2, and at 2 it also accepts
# UNAPPROVED, which is two insertions from APPROVED.
_edit_distance() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = length(a); m = length(b)
    for (i = 0; i <= n; i++) d[i, 0] = i
    for (j = 0; j <= m; j++) d[0, j] = j
    for (i = 1; i <= n; i++) {
      for (j = 1; j <= m; j++) {
        cost = (substr(a, i, 1) == substr(b, j, 1)) ? 0 : 1
        v = d[i - 1, j] + 1
        if (d[i, j - 1] + 1 < v) v = d[i, j - 1] + 1
        if (d[i - 1, j - 1] + cost < v) v = d[i - 1, j - 1] + cost
        if (i > 1 && j > 1 && substr(a, i, 1) == substr(b, j - 1, 1) &&
            substr(a, i - 1, 1) == substr(b, j, 1) && d[i - 2, j - 2] + 1 < v)
          v = d[i - 2, j - 2] + 1
        d[i, j] = v
      }
    }
    print d[n, m]
  }'
}

# Map a raw STATUS word to exactly one of APPROVED, ABORT, PENDING, or
# UNRECOGNIZED. Sets CLASS, and CLASS_WHY to a reason fit for the terminal.
#
# A false approve is the expensive direction, so every rule here leans toward
# UNRECOGNIZED, which approves nothing and keeps the batch waiting:
#   - Only trailing . and ! are dropped. Anything else that is not a letter --
#     a space, a second word, a ? -- makes the word unrecognized, so
#     "APPROVED?", "NOT APPROVED" and "APPROVED - BUT" never approve.
#   - A word with a negating prefix never approves, whatever its distance.
#   - A near-miss counts only at distance 1 (one wrong, missing, extra, or
#     swapped letter). Distance 2 or more is unrecognized.
#   - A near-miss that is also within 2 of another keyword is ambiguous, and
#     unrecognized. The keywords are far enough apart that no distance-1 word
#     trips this today; it is here so a future keyword cannot make it happen.
_classify() {
  local raw="$1" word kw d best="" best_d=99 near=0
  CLASS=UNRECOGNIZED
  CLASS_WHY=""
  word="${raw}"
  while [[ "${word}" == *[.!] ]]; do word="${word%?}"; done
  if [[ -z "${word}" ]]; then
    CLASS_WHY="empty status word"
    return 0
  fi
  if [[ ! "${word}" =~ ^[A-Z]+$ ]]; then
    CLASS_WHY="only letters, optionally followed by . or !, can match"
    return 0
  fi
  if ((${#word} > 12)); then
    CLASS_WHY="too long to be APPROVED, ABORT, or PENDING"
    return 0
  fi
  case "${word}" in
    APPROVED | ABORT | PENDING)
      CLASS="${word}"
      [[ "${word}" == "${raw}" ]] || CLASS_WHY="trailing punctuation ignored"
      return 0
      ;;
    UN* | DIS* | NO* | DE*)
      CLASS_WHY="negating prefix; never read as a keyword"
      return 0
      ;;
    *) ;;
  esac
  for kw in APPROVED ABORT PENDING; do
    d="$(_edit_distance "${word}" "${kw}")"
    ((d <= 2)) && near=$((near + 1))
    if ((d < best_d)); then
      best_d="${d}"
      best="${kw}"
    fi
  done
  if ((best_d > 1)); then
    CLASS_WHY="${best_d} edits from ${best}; only 1 is accepted"
    return 0
  fi
  if ((near > 1)); then
    CLASS_WHY="close to more than one of APPROVED, ABORT, PENDING"
    return 0
  fi
  CLASS="${best}"
  CLASS_WHY="1 edit from ${best}"
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

  # Deliberately NOT `rm -f approved/*` here. Clearing the whole directory made
  # each batch silently revoke the last one: approve a PR body now and a commit
  # message an hour later, and the PR body's approval was gone by push time,
  # with nothing to show it had ever been granted. Each name is instead cleared
  # by _write_approved as it is rewritten, so a batch revokes only what it
  # restates, and anything older than APPROVAL_TTL expires on its own. ABORT
  # still wipes everything -- that is the safe direction.

  # `|| [[ -n "${line}" ]]` catches a final line with no trailing newline.
  # Without it `read` returns false on that last line and the loop discards it,
  # so an editor saving without a trailing newline silently truncated the
  # approved body -- the bytes that would commit were not the bytes he read.
  # Measured 2026-09-18: a two-line body came back as one line.
  while IFS= read -r line || [[ -n "${line}" ]]; do
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
  # Clear this name's prior approval BEFORE deciding whether to write a new
  # one. Emptying an item in the editor is how a reviewer drops it from the
  # set, so it must revoke; returning early without this rm would leave the
  # previous approval standing and read as "still approved".
  rm -f "${APPROVED:?}/${name}"
  # An item emptied in the editor is a deliberate abort, not an approval.
  trimmed="$(printf '%s' "${body}" | sed -e '/^[[:space:]]*$/d')"
  [[ -n "${trimmed}" ]] || return 0
  printf '%s' "${body}" >"${APPROVED}/${name}"
  rm -f "${PENDING:?}/${name}"
}

# Age comes from mtime, not a TIMESTAMP line as in merge-lock: the approved
# file IS the hashed body, so any line added to it would break `check`.
# A file whose mtime cannot be read is left alone rather than guessed at.
_prune_expired() {
  local now approval mtime
  now="$(date +%s)"
  for approval in "${APPROVED}"/*; do
    [[ -f "${approval}" ]] || continue
    # GNU first: GNU `stat -f %m` fails but still prints filesystem info to stdout.
    mtime="$(stat -c %Y "${approval}" 2>/dev/null || stat -f %m "${approval}" 2>/dev/null)" || continue
    if ((now - mtime > APPROVAL_TTL)); then
      rm -f "${approval}"
    fi
  done
}

# Accept if the bytes match ANY approval. A match is not consumed: re-posting
# the same approved body (a `gh pr edit` after a `gh pr create`) is legitimate
# and must not require a second review of identical text, and consuming a match
# would block a retry after a transient push failure. What bounds the replay is
# age instead: an approval expires APPROVAL_TTL (30 minutes) after it was
# written, the same window merge-lock gives a lock.
_cmd_check() {
  local file="$1" want
  _prune_expired
  [[ -f "${file}" ]] || return 1
  want="$(_hash "${file}")"
  local approval
  for approval in "${APPROVED}"/*; do
    [[ -f "${approval}" ]] || continue
    [[ "$(_hash "${approval}")" == "${want}" ]] && return 0
  done
  return 1
}

# A real calendar date, checked in bash rather than by date(1): BSD `date -j -f`
# rolls 2026-02-31 over to 2026-03-03 with exit 0, and GNU `date -d` parses a
# different set of inputs. Plain arithmetic behaves the same on both.
_valid_date() {
  local d="$1" y m day max
  [[ "${d}" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || return 1
  y=$((10#${BASH_REMATCH[1]}))
  m=$((10#${BASH_REMATCH[2]}))
  day=$((10#${BASH_REMATCH[3]}))
  ((m >= 1 && m <= 12)) || return 1
  case "${m}" in
    4 | 6 | 9 | 11) max=30 ;;
    2)
      if ((y % 4 == 0 && (y % 100 != 0 || y % 400 == 0))); then
        max=29
      else
        max=28
      fi
      ;;
    *) max=31 ;;
  esac
  ((day >= 1 && day <= max))
}

# Time-boxed suspension of the whole gate. Andrew creates SUSPENDED by hand,
# containing one date (YYYY-MM-DD); the gate is off through the end of that
# local day and re-arms on its own the day after. Nothing here writes the file:
# both write hooks (Write/Edit and the Bash chain) keep agents out of GATE_DIR.
#
# Fails CLOSED. A missing, empty, unreadable, malformed, impossible (02-31) or
# past date means the gate stays armed. Only trailing whitespace is stripped,
# so a second line of content makes the file invalid rather than ignored.
#
# Active suspension is never silent: it prints one line to stderr each time a
# gated command is let through by it.
_cmd_suspended() {
  local file="${GATE_DIR}/SUSPENDED" content today
  [[ -f "${file}" && -r "${file}" ]] || return 1
  content="$(sed -e 's/[[:space:]]*$//' "${file}" 2>/dev/null)" || return 1
  _valid_date "${content}" || return 1
  today="$(date +%F)"
  [[ "${content}" < "${today}" ]] && return 1
  printf '[personify-gate] SUSPENDED until %s (%s)\n' "${content}" "${file}" >&2
  return 0
}

case "${1:-}" in
  stage) shift; _cmd_stage "$@" ;;
  open) _cmd_open ;;
  hash) shift; _hash "$1" ;;
  check) shift; _cmd_check "$@" ;;
  suspended) _cmd_suspended ;;
  *) _die "usage: gate-review.sh {stage <name> <file>|open|hash <file>|check <file>|suspended}" ;;
esac
