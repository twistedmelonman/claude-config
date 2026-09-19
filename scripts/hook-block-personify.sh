#!/usr/bin/env bash
# Block commit/PR/issue text unless PERSONIFY_OK is exported.
#
# Read from the environment, never from argv: an agent can type
# `PERSONIFY_OK=1 git commit` but cannot export into the session. Same property
# as merge-lock.
#
# Covers the Bash-tool path; gh-wrapper.sh covers manual gh calls.
# Called by: hook-block-all.sh

set -euo pipefail
unset CDPATH

input=$(cat)
cmd=$(printf '%s\n' "${input}" | jq -r '.tool_input.command // empty')

[[ -n "${cmd}" ]] || exit 0

# Subcommand-position matching, same shape and same limits as
# hook-block-main-commit.sh: a regex approximation of shell syntax, bypassable
# through aliases and variables. ${bt} avoids a literal backtick, which reads
# to shellcheck as SC2016.
bt=$(printf '\140')
readonly bt
_sep="(^|&&|\\|\\||;|\\||&|\\(|\\{|${bt}|'|\"|[[:space:]]then|[[:space:]]do)[[:space:]]*"
_wrap="((env|command|sudo)[[:space:]]+)*"
_path="([^[:space:]|;&(){${bt}]*/)?"
_optval="(\"[^\"]*\"[[:space:]]+|'[^']*'[[:space:]]+|[^-][^|;&${bt}[:space:]]*[[:space:]]+)?"

# `env FOO=1 git commit` puts an assignment between the wrapper and the binary,
# which the wrapper arm does not consume. Normalize it to the bare keyword.
_scan=$(printf '%s\n' "${cmd}" | sed -E 's/(^|[[:space:]])env[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*/\1env /g')

# A leading assignment sits between the separator and the binary and defeats
# the match. Without this pass, measured 2026-09-18, `PERSONIFY_OK=1 git
# commit -m x` returned 0 with the variable unset -- the gate was bypassable by
# typing its own name. Re-run that case against any matcher change.
_scan=$(printf '%s\n' "${_scan}" | sed -E 's/(^|&&|\|\||;|\||&|\(|\{)[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+/\1 /g')

commit_re="${_sep}${_wrap}${_path}git[[:space:]]+(-[^[:space:]]+[[:space:]]+${_optval})*commit([[:space:]]|$)"
gh_re="${_sep}${_wrap}${_path}gh[[:space:]]+(-[^[:space:]]+[[:space:]]+${_optval})*(pr|issue)[[:space:]]+(create|comment|edit)([[:space:]]|$)"

surface=""
if printf '%s\n' "${_scan}" | grep -qE "${commit_re}"; then
  surface="commit message and code comments"
elif printf '%s\n' "${_scan}" | grep -qE "${gh_re}"; then
  surface="PR/issue body"
fi

[[ -n "${surface}" ]] || exit 0

if [[ -n "${PERSONIFY_OK:-}" ]]; then
  exit 0
fi

{
  echo '🛑 BLOCKED: text not acknowledged as edited for length.'
  echo ''
  echo "  surface: ${surface}"
  echo ''
  echo 'Before sending:'
  echo '  1. Run /personify on the text.'
  echo '  2. Cut it to the claim and its consequence. Drop the narration, the'
  echo '     restatement of the diff, and anything the reader can see by'
  echo '     looking at the change.'
  echo '  3. A one-line change gets about one line of description.'
  echo ''
  echo 'Then, in your own shell:'
  echo '  export PERSONIFY_OK=1'
  echo ''
  echo 'Set it yourself. An agent setting it inline does not satisfy this.'
} >&2
exit 2
