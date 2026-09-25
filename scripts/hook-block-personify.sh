#!/usr/bin/env bash
# Block commit/PR/issue text that Andrew has not visually approved.
#
# Approval lives on disk, in gate-review's approved/ directory, and is bound to
# the exact bytes he saw. The hook extracts the file the command will read its
# text from, and asks gate-review whether those bytes hash to something
# approved. No name is inferred: `check` matches on content, so a body approved
# under any label satisfies it.
#
# An earlier version read PERSONIFY_OK from the environment. That channel is
# DEAD and must not be reintroduced: the Bash tool runs in a process that does
# not inherit the interactive shell's environment, so an env-var ack is
# unsatisfiable by the human, not merely strict. Measured 2026-09-18, along
# with `$EDITOR` (no TTY on stdin or stdout). `open -a` is the one channel that
# reaches a human from here, and gate-review.sh owns it.
#
# WHY THE INPUT FORM IS CONSTRAINED. The hook sees a raw command string and
# nothing else. It can verify text only if that text is in a file it can read,
# at a path it can resolve without a shell:
#
#   -F/--file, --body-file  with an ABSOLUTE path  -> verifiable, checked
#   -m/--body "quoted text"                        -> blocked, nothing to hash
#   a RELATIVE path                                -> blocked: with `git -C`,
#       git resolves it against the repo and this hook against the tool's cwd,
#       and the two disagree silently
#   ~/... or $VAR/...                              -> blocked, same reason
#   no message flag at all                         -> blocked; editor mode has
#       no TTY here anyway, so it could never succeed
#
# PR and issue TITLES stay ungated -- one line by nature. `gh pr edit` is
# gated only when it carries a body flag, so label and title edits pass.
# `gh pr review` follows the same rule: `--approve` alone passes, a review
# body is gated.
#
# `gh api` is gated when it sends a field named `body` or runs a GraphQL
# mutation with a body argument (claude-config#548). The one verifiable form
# is `-F body=@/absolute/path`; every inline value, and every GraphQL body,
# blocks. NOT covered: `--input <json>`, which carries the body inside a JSON
# document; blocking it outright would also block ruleset and protection
# writes that carry no prose.
#
# Covers the Bash-tool path; gh-wrapper.sh covers manual gh calls. The two are
# deliberately redundant, so neither being bypassed lets text through.
# Called by: hook-block-all.sh

set -euo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${SCRIPT_DIR}/gate-review.sh"

input=$(cat)
cmd=$(printf '%s\n' "${input}" | jq -r '.tool_input.command // empty')

[[ -n "${cmd}" ]] || exit 0

# KNOWN LIMITATION -- READ BEFORE RELYING ON THIS AS A SECURITY BOUNDARY.
# This is a regex approximation of shell syntax, not a shell parser, and it is
# BYPASSABLE, in the same ways and for the same reasons as the equivalent
# matcher in hook-block-main-commit.sh (see its note).
#
# Handled: command separators (`&&`, `||`, `;`, `|`, `&`, `(`, `{`, backtick),
# the `then`/`do` keywords, an opening quote of any kind, `env`/`command`/
# `sudo` wrappers, a leading path on the binary, global options before the
# subcommand, and backslash-continued lines (_join_continuations, below).
#
# NOT handled, and not closeable at this layer: aliases and shell functions,
# obfuscation through variables (`G=git; $G commit`), and any construction that
# spells the binary without those literal characters. A PreToolUse hook sees the
# raw, unexpanded string with no alias, function, or variable table to consult.
# These are properties of where the check runs, not a to-do.
#
# ${bt} avoids a literal backtick, which reads to shellcheck as SC2016.
bt=$(printf '\140')
readonly bt
_sep="(^|&&|\\|\\||;|\\||&|\\(|\\{|${bt}|'|\"|[[:space:]]then|[[:space:]]do)[[:space:]]*"
_wrap="((env|command|sudo)[[:space:]]+)*"
_path="([^[:space:]|;&(){${bt}]*/)?"
_optval="(\"[^\"]*\"[[:space:]]+|'[^']*'[[:space:]]+|[^-][^|;&${bt}[:space:]]*[[:space:]]+)?"

# Join backslash-continued lines into one logical line, as bash does, before
# anything else looks at the command (claude-config#595). The hook judges one
# line at a time, so without this `gh pr create --title t \` followed by
# `--body x` put the body flag on a line with no verb, and it was never checked.
#
# The join follows bash: `\<newline>` is removed outright (no space), outside
# quotes and inside double quotes. It is NOT a continuation, and the newline
# stays, inside single quotes or $'...', in a heredoc body (quoted delimiter
# or not -- heredoc text is prose, and joining it would put its words in
# command position), at the end of a comment, or when the backslash is itself
# escaped (`\\<newline>`). A plain newline still ends the line: only
# continuations join, so an approved path on one line cannot vouch for a
# command on another.
#
# Heredocs: `<<WORD`, `<<-WORD` and the quoted spellings open a body on the
# next line, up to a line that is exactly WORD (leading tabs removed for
# `<<-`). Several on one line are read in order. Same caveat as below: a
# character scanner, not a parser, so `$(...)` nesting and the like are
# approximated.
_join_continuations() {
  awk '
    function flush() { print buf; buf = "" }
    BEGIN { q = 0; hd = 0; np = 0; buf = ""; joined = 0 }
    {
      line = $0
      if (hd) {
        print line
        chk = line
        if (hstrip[hd]) sub(/^\t+/, "", chk)
        if (chk == hdelim[hd]) { hd++; if (hd > np) { hd = 0; np = 0 } }
        next
      }
      n = length(line); joined = 0; i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (q == 1) { buf = buf c; if (c == "\047") q = 0; i++; continue }
        if (q == 3) {
          if (c == "\\") { buf = buf substr(line, i, 2); i += 2; continue }
          buf = buf c; if (c == "\047") q = 0; i++; continue
        }
        if (c == "\\") {
          if (i == n) { joined = 1; i++; continue }
          buf = buf substr(line, i, 2); i += 2; continue
        }
        if (q == 2) { buf = buf c; if (c == "\"") q = 0; i++; continue }
        prev = (buf == "") ? "" : substr(buf, length(buf), 1)
        if (c == "#" && (prev == "" || prev ~ /[[:space:];&|()<>]/)) {
          buf = buf substr(line, i); break
        }
        if (c == "\047") { q = 1; buf = buf c; i++; continue }
        if (c == "\"") { q = 2; buf = buf c; i++; continue }
        nx = substr(line, i + 1, 1)
        if (c == "$" && nx == "\047") { q = 3; buf = buf "$\047"; i += 2; continue }
        if (c == "<" && nx == "<" && prev != "<" && substr(line, i + 2, 1) != "<") {
          rest = substr(line, i + 2); strip = 0
          if (substr(rest, 1, 1) == "-") { strip = 1; rest = substr(rest, 2) }
          sub(/^[ \t]+/, "", rest)
          if (match(rest, /^[^ \t;&|()<>]+/)) {
            w = substr(rest, 1, RLENGTH)
            gsub(/[\047"\\]/, "", w)
            if (w != "") { np++; hdelim[np] = w; hstrip[np] = strip }
          }
          buf = buf "<<"; i += 2; continue
        }
        buf = buf c; i++
      }
      if (joined) next
      flush()
      if (q == 0 && np > 0) hd = 1
    }
    END { if (joined || buf != "") flush() }
  '
}

_joined=$(printf '%s\n' "${cmd}" | _join_continuations)

# `env FOO=1 git commit` puts an assignment between the wrapper and the binary,
# which the wrapper arm does not consume. Normalize it to the bare keyword.
_scan=$(printf '%s\n' "${_joined}" | sed -E 's/(^|[[:space:]])env[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*/\1env /g')

# A leading assignment sits between the separator and the binary and defeats
# the match. Without this pass, measured 2026-09-18, `PERSONIFY_OK=1 git
# commit -m x` returned 0 with the variable unset -- the gate was bypassable by
# typing its own name. Re-run that case against any matcher change.
_scan=$(printf '%s\n' "${_scan}" | sed -E 's/(^|&&|\|\||;|\||&|\(|\{)[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+/\1 /g')

# The whole command on one line, for checks that must see past the per-line
# segments _segments produces (see _gql_has_body).
_scan_flat=$(printf '%s\n' "${_scan}" | tr '\n' ' ')
readonly _scan_flat

commit_re="${_sep}${_wrap}${_path}git[[:space:]]+(-[^[:space:]]+[[:space:]]+${_optval})*commit([[:space:]]|$)"
gh_re="${_sep}${_wrap}${_path}gh[[:space:]]+(-[^[:space:]]+[[:space:]]+${_optval})*(pr[[:space:]]+(create|comment|edit|review)|issue[[:space:]]+(create|comment|edit))([[:space:]]|$)"
api_re="${_sep}${_wrap}${_path}gh[[:space:]]+(-[^[:space:]]+[[:space:]]+${_optval})*api([[:space:]]|$)"

# A `gh api` field named exactly `body`, in every spelling gh accepts:
# `-f body=`, `-fbody=`, `--field body=`, `--field=body=`, `--raw-field body=`,
# with the key=value optionally quoted. The leading space keeps `nobody=` and
# the like out; the value runs to the next space.
_api_body_re="[[:space:]](-f|-F|--field|--raw-field)(=|[[:space:]]+)?[\"']?body=[^[:space:]]*"

# A GraphQL mutation that sets a body argument (addComment, addPullRequestReview
# and friends) carries its text inside the query string. There is no file form
# to verify: `-F query=@file` is already refused by hook-block-api-merge.sh.
_gql_body_re="mutation.*[^[:alnum:]_]body[[:space:]]*:"

# Split the line into segments at command separators, so each gated invocation
# is judged on its own flags. Checking the line as a whole would let an
# unapproved second command ride along on the first command's approved path.
_segments() {
  printf '%s\n' "${_scan}" | sed -E 's/(&&|\|\||;|\|)/\n/g'
}

_deny() {
  local reason="$1" surface="$2"
  {
    echo '🛑 BLOCKED: this text has not been visually approved.'
    echo ''
    echo "  surface: ${surface}"
    echo "  reason:  ${reason}"
    echo ''
    echo 'Every commit message and PR body must be read and approved in the'
    echo 'editor before it is written. To do that:'
    echo ''
    echo '  1. Write the text to a file.'
    echo "  2. ${GATE} stage <label> <file>"
    echo "  3. ${GATE} open"
    echo '  4. Andrew reads the batch and types APPROVED in the STATUS line.'
    echo '  5. Re-run the command against the APPROVED file, absolute path:'
    echo "       git commit -F ${HOME}/.claude/gate-review/approved/<label>"
    echo "       gh pr create --title t --body-file ${HOME}/.claude/gate-review/approved/<label>"
    echo ''
    echo '     Use the approved copy, not the file you staged: if he edited the'
    echo '     text in the editor, his edits are what he approved and the'
    echo '     original no longer matches.'
    echo ''
    echo 'Approval is his to give. Staging and opening on his behalf is fine;'
    echo 'typing the word for him is not.'
  } >&2
  exit 2
}

# Pull the argument of a file flag out of one segment. Handles `-F path`,
# `--file=path`, `--body-file path` and the quoted forms of each.
_extract_path() {
  local seg="$1" flags="$2" p
  # `--flag=value`
  p=$(printf '%s\n' "${seg}" | sed -En "s/.*[[:space:]](${flags})=\"([^\"]*)\".*/\\2/p" | head -1)
  [[ -n "${p}" ]] && { printf '%s\n' "${p}"; return 0; }
  p=$(printf '%s\n' "${seg}" | sed -En "s/.*[[:space:]](${flags})='([^']*)'.*/\\2/p" | head -1)
  [[ -n "${p}" ]] && { printf '%s\n' "${p}"; return 0; }
  p=$(printf '%s\n' "${seg}" | sed -En "s/.*[[:space:]](${flags})=([^[:space:]]+).*/\\2/p" | head -1)
  [[ -n "${p}" ]] && { printf '%s\n' "${p}"; return 0; }
  # `--flag value`
  p=$(printf '%s\n' "${seg}" | sed -En "s/.*[[:space:]](${flags})[[:space:]]+\"([^\"]*)\".*/\\2/p" | head -1)
  [[ -n "${p}" ]] && { printf '%s\n' "${p}"; return 0; }
  p=$(printf '%s\n' "${seg}" | sed -En "s/.*[[:space:]](${flags})[[:space:]]+'([^']*)'.*/\\2/p" | head -1)
  [[ -n "${p}" ]] && { printf '%s\n' "${p}"; return 0; }
  printf '%s\n' "${seg}" | sed -En "s/.*[[:space:]](${flags})[[:space:]]+([^[:space:]]+).*/\\2/p" | head -1
}

# Verify one gated segment: find its text-bearing flag, resolve the path, and
# ask gate-review. Every exit from here is a decision; falling through the end
# without one would be a silent pass.
_verify_segment() {
  local seg="$1" surface="$2" inline_flags="$3" file_flags="$4" path

  # An inline string cannot be hashed from the command line at all.
  if printf '%s\n' "${seg}" | grep -qE "[[:space:]](${inline_flags})([[:space:]]|=)"; then
    _deny "text given inline; only a file can be verified" "${surface}"
  fi

  path="$(_extract_path "${seg}" "${file_flags}")"

  if [[ -z "${path}" ]]; then
    _deny "no message file named" "${surface}"
  fi

  _verify_path "${path}" "${surface}"
}

# The shared tail of every file form: the path must be absolute, exist, and
# hash to something approved.
_verify_path() {
  local path="$1" surface="$2"
  case "${path}" in
    /*) ;;
    *) _deny "path '${path}' is not absolute; git and this hook would resolve it differently" "${surface}" ;;
  esac

  [[ -f "${path}" ]] || _deny "no such file: ${path}" "${surface}"

  [[ -x "${GATE}" ]] || _deny "gate-review.sh missing at ${GATE}; cannot verify" "${surface}"

  "${GATE}" check "${path}" ||
    _deny "the bytes in ${path} do not match anything approved" "${surface}"
}

# Is this `gh api` segment writing prose? A `body` field or a GraphQL mutation
# with a body argument. Anything else (GETs, state/label/title fields, read-only
# queries) is not a text surface.
_api_is_gated() {
  printf '%s\n' "$1" | grep -qE -- "${_api_body_re}" || _gql_has_body "$1"
}

# A GraphQL query is usually written across several lines inside a quoted
# string (plain newlines, not continuations, so _join_continuations leaves
# them), and _segments puts each line in its own segment, so the mutation and
# its `body:` sit on lines with no `gh api` on them. Measured 2026-09-25: a two-line addComment passed.
# For a graphql segment, test the whole command (_scan_flat, set once at the
# top) rather than the segment. Testing only the segment is the bug this
# fixes. A match elsewhere on the line blocks too, which is the safe direction.
_gql_has_body() {
  printf '%s\n' "$1" | grep -qE 'graphql' || return 1
  printf '%s\n' "${_scan_flat}" | grep -qE -- "${_gql_body_re}"
}

# Verify every body field in one `gh api` segment. Only `-F/--field body=@<abs>`
# can pass: that form makes gh read the value from the file, so the file's bytes
# are what gets posted. `-f/--raw-field` never expands `@`, so `-f body=@/x`
# posts the literal string and is inline text like any other value.
_verify_api_segment() {
  local seg="$1" surface="API body" m flag val matches
  if _gql_has_body "${seg}"; then
    _deny "GraphQL mutation carries its body inline; use gh pr/issue comment --body-file" "${surface}"
  fi
  matches="$(printf '%s\n' "${seg}" | grep -oE -- "${_api_body_re}" || true)"
  while IFS= read -r m; do
    [[ -n "${m}" ]] || continue
    flag="$(printf '%s\n' "${m}" | sed -E 's/^[[:space:]]*(--raw-field|--field|-f|-F).*/\1/')"
    val="${m#*body=}"
    val="${val//\"/}"
    val="${val//\'/}"
    case "${flag}" in
      -F | --field) ;;
      *) _deny "text given inline (${flag} never reads a file); use -F body=@<absolute path>" "${surface}" ;;
    esac
    [[ "${val}" == @* ]] ||
      _deny "text given inline; only -F body=@<absolute path> can be verified" "${surface}"
    _verify_path "${val#@}" "${surface}"
  done <<<"${matches}"
}

# A time-boxed suspension (gate-review.sh suspended; Andrew writes the file by
# hand) lets every gated segment through. It is asked only once a segment is
# actually gated, so ungated commands neither pay for the call nor print the
# notice. A missing or non-executable gate-review.sh is not a suspension: that
# case falls through to _verify_segment, which blocks.
_suspended() {
  [[ -x "${GATE}" ]] && "${GATE}" suspended
}

# `git commit --amend --no-edit` and `-C <sha>` reuse an existing message and
# author no new text, but they name no file either, so they fall to the
# no-message-file branch and block. That is the decided behaviour (2026-09-18):
# the simple rule first, revisit if it fires repeatedly on genuinely unchanged
# text.
while IFS= read -r seg; do
  [[ -n "${seg}" ]] || continue
  if printf '%s\n' "${seg}" | grep -qE "${commit_re}"; then
    _suspended && exit 0
    _verify_segment "${seg}" "commit message" '-m|--message' '-F|--file'
  elif printf '%s\n' "${seg}" | grep -qE "${gh_re}"; then
    # Titles and labels carry no body text. Gate only when a body flag is
    # present, per the locked decision that PR titles stay ungated.
    if printf '%s\n' "${seg}" | grep -qE '[[:space:]](-b|--body|-F|--body-file)([[:space:]]|=)'; then
      _suspended && exit 0
      _verify_segment "${seg}" "PR/issue body" '-b|--body' '-F|--body-file'
    fi
  elif printf '%s\n' "${seg}" | grep -qE "${api_re}"; then
    if _api_is_gated "${seg}"; then
      _suspended && exit 0
      _verify_api_segment "${seg}"
    fi
  fi
done < <(_segments)

exit 0
