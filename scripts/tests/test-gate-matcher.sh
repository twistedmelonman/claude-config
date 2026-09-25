#!/usr/bin/env bash
# Regression suite for the two Bash-path gate hooks:
#   hook-block-personify.sh    -- gates commit/PR text on an approved artifact
#   hook-block-gate-dir-write.sh -- keeps the approval dirs agent-unwritable
#
# Cases are base64-encoded so this file's own source carries no literal
# VCS-command text. A literal `git commit` here trips hook-block-main-commit.sh
# whenever the tool cwd sits in a repo on main, which makes the suite
# unrunnable from exactly the state it is most often run in.
#
# Promoted from dev-env's git-excluded scratch (claude-config#545, second item):
# a matcher with no committed coverage is how the bypass it now tests got in.

set -uo pipefail
unset CDPATH

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERSONIFY="${SCRIPTS}/hook-block-personify.sh"
DIRWRITE="${SCRIPTS}/hook-block-gate-dir-write.sh"

for h in "${PERSONIFY}" "${DIRWRITE}"; do
  [[ -x "${h}" ]] || {
    echo "missing or not executable: ${h}" >&2
    exit 1
  }
done

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Drive the hooks against a fixture dir, not the real one: the suite must not
# depend on what happens to be approved on this machine, and must never write
# into the dir it is testing the protection of.
export GATE_REVIEW_DIR="${TMP}/gate"
mkdir -p "${GATE_REVIEW_DIR}/pending" "${GATE_REVIEW_DIR}/approved"

APPROVED_TEXT="${TMP}/approved-body.txt"
UNAPPROVED_TEXT="${TMP}/unapproved-body.txt"
printf 'fix(gate): a body that was approved\n' >"${APPROVED_TEXT}"
printf 'fix(gate): a body nobody reviewed\n' >"${UNAPPROVED_TEXT}"
# Seed the approval directly. `gate-review open` needs a GUI and a human, so
# the suite writes the approved bytes itself -- this is the fixture, not a
# bypass of the real gate.
cp "${APPROVED_TEXT}" "${GATE_REVIEW_DIR}/approved/commit-1"

pass=0
fail=0

_case() {
  local hook="$1" desc="$2" b64="$3" want="$4" cmd got
  cmd="$(printf '%s' "${b64}" | base64 -d)"
  printf '{"tool_input":{"command":%s}}' "$(printf '%s' "${cmd}" | jq -Rs .)" |
    "${hook}" >/dev/null 2>&1
  got=$?
  if [[ "${got}" == "${want}" ]]; then
    echo "  PASS (${got}) ${desc}"
    pass=$((pass + 1))
  else
    echo "  FAIL (got ${got} want ${want}) ${desc}"
    fail=$((fail + 1))
  fi
}

_b64() { printf '%s' "$1" | base64; }

echo "=== personify: unverifiable text must BLOCK (exit 2) ==="
_case "${PERSONIFY}" "inline -m message" \
  "$(_b64 'git commit -m "x"')" 2
_case "${PERSONIFY}" "INLINE ASSIGNMENT BYPASS (the 2026-09-18 hole)" \
  "$(_b64 'PERSONIFY_OK=1 git commit -m "x"')" 2
_case "${PERSONIFY}" "env-wrapped assignment" \
  "$(_b64 'env PERSONIFY_OK=1 git commit -m x')" 2
_case "${PERSONIFY}" "after &&" \
  "$(_b64 'cd /tmp && git commit -m "x"')" 2
_case "${PERSONIFY}" "absolute path binary" \
  "$(_b64 '/usr/bin/git commit -m x')" 2
_case "${PERSONIFY}" "no message flag at all (editor mode, no TTY)" \
  "$(_b64 'git commit')" 2
_case "${PERSONIFY}" "amend --no-edit reuses text but names no file" \
  "$(_b64 'git commit --amend --no-edit')" 2
_case "${PERSONIFY}" "gh pr create with inline --body" \
  "$(_b64 'gh pr create --body "x"')" 2
_case "${PERSONIFY}" "gh issue comment with inline --body" \
  "$(_b64 'gh issue comment 5 --body "x"')" 2

echo "=== personify: -F path forms ==="
_case "${PERSONIFY}" "relative -F path (git and hook resolve it differently)" \
  "$(_b64 'git commit -F ./msg.txt')" 2
_case "${PERSONIFY}" "tilde -F path (unresolvable from the command string)" \
  "$(_b64 'git commit -F ~/msg.txt')" 2
# The `${MSG}` here is test data, not an expansion this script wants: the point
# is that the hook cannot resolve a variable-spelled path. Built from a literal
# `$` so shellcheck sees no unexpanded expression (SC2016), which disable
# directives are not permitted to silence.
_dollar=$(printf '\044')
_case "${PERSONIFY}" "variable -F path (unresolvable from the command string)" \
  "$(_b64 "git commit -F ${_dollar}{MSG}/x.txt")" 2
_case "${PERSONIFY}" "absolute -F path, text NOT approved" \
  "$(_b64 "git commit -F ${UNAPPROVED_TEXT}")" 2
_case "${PERSONIFY}" "absolute -F path, text APPROVED" \
  "$(_b64 "git commit -F ${APPROVED_TEXT}")" 0
_case "${PERSONIFY}" "--file= form, APPROVED" \
  "$(_b64 "git commit --file=${APPROVED_TEXT}")" 0
_case "${PERSONIFY}" "quoted absolute -F path, APPROVED" \
  "$(_b64 "git commit -F \"${APPROVED_TEXT}\"")" 0
_case "${PERSONIFY}" "commit from the approved dir itself, APPROVED" \
  "$(_b64 "git commit -F ${GATE_REVIEW_DIR}/approved/commit-1")" 0
_case "${PERSONIFY}" "gh pr create --body-file, APPROVED" \
  "$(_b64 "gh pr create --title t --body-file ${APPROVED_TEXT}")" 0
_case "${PERSONIFY}" "gh pr create --body-file, NOT approved" \
  "$(_b64 "gh pr create --title t --body-file ${UNAPPROVED_TEXT}")" 2

echo "=== personify: ungated surfaces must ALLOW (exit 0) ==="
_case "${PERSONIFY}" "status" "$(_b64 'git status')" 0
_case "${PERSONIFY}" "log" "$(_b64 'git log --oneline -1')" 0
_case "${PERSONIFY}" "gh pr view" "$(_b64 'gh pr view 12')" 0
_case "${PERSONIFY}" "gh pr edit --add-label (no body flag)" \
  "$(_b64 'gh pr edit 12 --add-label ready')" 0
_case "${PERSONIFY}" "gh pr edit --title only (titles stay ungated)" \
  "$(_b64 'gh pr edit 12 --title "a new title"')" 0
_case "${PERSONIFY}" "gh pr edit --body-file, NOT approved" \
  "$(_b64 "gh pr edit 12 --body-file ${UNAPPROVED_TEXT}")" 2

echo "=== personify: multiple gated commands on one line ==="
# Every extracted path must verify, or the line blocks. Checking only the
# first would let an unapproved second command ride along on the first's
# approval.
_case "${PERSONIFY}" "approved then unapproved" \
  "$(_b64 "git commit -F ${APPROVED_TEXT} && gh pr create --body-file ${UNAPPROVED_TEXT}")" 2
_case "${PERSONIFY}" "approved then approved" \
  "$(_b64 "git commit -F ${APPROVED_TEXT} && gh pr create --body-file ${APPROVED_TEXT}")" 0

echo "=== personify: gh pr review carries a body (claude-config#548) ==="
# Review bodies reach another person exactly as a PR comment does. The event
# flags (--approve, --request-changes, --comment) carry no text; only a body
# flag makes the call gated, as with `gh pr edit`.
_case "${PERSONIFY}" "pr review --comment with inline --body" \
  "$(_b64 'gh pr review 5 --comment --body "x"')" 2
_case "${PERSONIFY}" "pr review with inline -b" \
  "$(_b64 'gh pr review 5 -b x')" 2
_case "${PERSONIFY}" "pr review --body-file, NOT approved" \
  "$(_b64 "gh pr review 5 --request-changes --body-file ${UNAPPROVED_TEXT}")" 2
_case "${PERSONIFY}" "pr review -F, NOT approved" \
  "$(_b64 "gh pr review 5 --comment -F ${UNAPPROVED_TEXT}")" 2
_case "${PERSONIFY}" "pr review with global -R before the subcommand, inline" \
  "$(_b64 'gh -R o/r pr review 5 --body x')" 2
_case "${PERSONIFY}" "pr review --body-file, APPROVED" \
  "$(_b64 "gh pr review 5 --request-changes --body-file ${APPROVED_TEXT}")" 0
_case "${PERSONIFY}" "pr review --approve (no body) passes" \
  "$(_b64 'gh pr review 5 --approve')" 0
_case "${PERSONIFY}" "pr review --request-changes (no body) passes" \
  "$(_b64 'gh pr review 5 --request-changes')" 0
# Verbs need command position: the words inside prose must not gate.
_case "${PERSONIFY}" "prose 'pr review --body' inside a grep pattern" \
  "$(_b64 'gh pr view 5 --comments | grep "pr review --body"')" 0
_case "${PERSONIFY}" "prose 'gh pr review --body' mid-sentence in echo" \
  "$(_b64 'echo "then run gh pr review --body x to reply"')" 0

echo "=== personify: gh api with a body field (claude-config#548) ==="
# `-F/--field key=@path` reads the value from a file; that is the one form the
# hook can verify. `-f/--raw-field` never expands @, so `-f body=@/abs` posts
# the literal string and is inline text like any other.
_case "${PERSONIFY}" "api -f body= inline" \
  "$(_b64 "gh api repos/o/r/issues/5/comments -f body='hi there'")" 2
_case "${PERSONIFY}" "api --field body= inline" \
  "$(_b64 'gh api repos/o/r/issues/5/comments --field body=hi')" 2
_case "${PERSONIFY}" "api --raw-field body= inline" \
  "$(_b64 'gh api repos/o/r/issues/5/comments --raw-field body=hi')" 2
_case "${PERSONIFY}" "api -F body= typed but inline" \
  "$(_b64 'gh api repos/o/r/issues/5/comments -F body=hi')" 2
_case "${PERSONIFY}" "api attached -fbody= inline" \
  "$(_b64 'gh api repos/o/r/issues/5/comments -fbody=hi')" 2
_case "${PERSONIFY}" "api --field=body= inline" \
  "$(_b64 'gh api repos/o/r/issues/5/comments --field=body=hi')" 2
_case "${PERSONIFY}" "api quoted \"body=...\" inline" \
  "$(_b64 'gh api repos/o/r/pulls/5/comments -f "body=hi there"')" 2
_case "${PERSONIFY}" "api after && with inline body" \
  "$(_b64 'echo x && gh api repos/o/r/issues/5/comments -f body=hi')" 2
_case "${PERSONIFY}" "api with a global flag before it, inline body" \
  "$(_b64 'gh --hostname github.com api repos/o/r/issues/5/comments -f body=hi')" 2
_case "${PERSONIFY}" "api -F body=@file, NOT approved" \
  "$(_b64 "gh api repos/o/r/issues/5/comments -F body=@${UNAPPROVED_TEXT}")" 2
_case "${PERSONIFY}" "api -F body=@relative path" \
  "$(_b64 'gh api repos/o/r/issues/5/comments -F body=@./msg.txt')" 2
_case "${PERSONIFY}" "api -F body=@- (stdin, nothing to hash)" \
  "$(_b64 'gh api repos/o/r/issues/5/comments -F body=@-')" 2
_case "${PERSONIFY}" "api -f body=@abs (raw field posts the literal string)" \
  "$(_b64 "gh api repos/o/r/issues/5/comments -f body=@${APPROVED_TEXT}")" 2
_case "${PERSONIFY}" "api approved -F body plus a second inline body field" \
  "$(_b64 "gh api repos/o/r/issues/5/comments -F body=@${APPROVED_TEXT} -f body=x")" 2
_case "${PERSONIFY}" "api -F body=@file, APPROVED" \
  "$(_b64 "gh api repos/o/r/issues/5/comments -F body=@${APPROVED_TEXT}")" 0
_case "${PERSONIFY}" "api --field body=@file, APPROVED" \
  "$(_b64 "gh api repos/o/r/issues/5/comments --field body=@${APPROVED_TEXT}")" 0
_case "${PERSONIFY}" "api quoted -F \"body=@file\", APPROVED" \
  "$(_b64 "gh api repos/o/r/issues/5/comments -F \"body=@${APPROVED_TEXT}\"")" 0
_case "${PERSONIFY}" "api --field=body=@file, APPROVED" \
  "$(_b64 "gh api repos/o/r/issues/5/comments --field=body=@${APPROVED_TEXT}")" 0
_case "${PERSONIFY}" "api GET, no fields" \
  "$(_b64 'gh api repos/o/r/pulls/5')" 0
_case "${PERSONIFY}" "api with a non-body field" \
  "$(_b64 'gh api repos/o/r/issues/5 -X PATCH -f state=closed')" 0
_case "${PERSONIFY}" "api with a title field (titles stay ungated)" \
  "$(_b64 'gh api repos/o/r/issues -f title=t')" 0
_case "${PERSONIFY}" "api with a field whose name only ends in body" \
  "$(_b64 'gh api repos/o/r/x -f nobody=1')" 0
_case "${PERSONIFY}" "api --jq .body reads, does not write" \
  "$(_b64 'gh api repos/o/r/issues/5 --jq .body')" 0
_case "${PERSONIFY}" "api graphql query with no body field" \
  "$(_b64 "gh api graphql -f query='{ viewer { login } }'")" 0
_case "${PERSONIFY}" "api graphql query READING comment bodies" \
  "$(_b64 "gh api graphql -f query='{ repository(owner:\"o\",name:\"r\") { issue(number:5) { comments(first:5) { nodes { body } } } } }'")" 0
_case "${PERSONIFY}" "api graphql addComment mutation with inline body" \
  "$(_b64 "gh api graphql -f query='mutation { addComment(input: {subjectId: \"X\", body: \"hi\"}) { clientMutationId } }'")" 2
# The usual way to write a mutation puts the query on its own lines. The hook
# splits a command into per-line segments, so the mutation and `body:` sit on
# lines that carry no `gh api`. Verified 2026-09-25: these returned 0.
_case "${PERSONIFY}" "api graphql mutation on the line after gh api" \
  "$(_b64 "gh api graphql -f query='
mutation { addComment(input: {subjectId: \"X\", body: \"hi\"}) { clientMutationId } }'")" 2
_case "${PERSONIFY}" "api graphql mutation spread across lines" \
  "$(_b64 "gh api graphql -f query='
mutation {
  addComment(input: {
    subjectId: \"X\"
    body: \"hi\"
  }) { clientMutationId }
}'")" 2
_case "${PERSONIFY}" "multi-line read-only graphql query selecting body" \
  "$(_b64 "gh api graphql -f query='
{ repository(owner: \"o\", name: \"r\") {
    issue(number: 5) { comments(first: 5) { nodes { body } } }
} }'")" 0
_case "${PERSONIFY}" "api graphql mutation with body from a variable" \
  "$(_b64 "gh api graphql -f query='mutation(\$b: String!) { addComment(input: {subjectId: \"X\", body: \$b}) { clientMutationId } }' -f b=hi")" 2
# Verbs need command position: the words inside prose must not gate.
_case "${PERSONIFY}" "prose 'gh api -F body=' mid-sentence in echo" \
  "$(_b64 'echo "the gh api -F body=x form is gated now"')" 0
_case "${PERSONIFY}" "prose 'gh api body' in an approved PR title" \
  "$(_b64 "gh pr create --title \"gate gh api -f body= fields\" --body-file ${APPROVED_TEXT}")" 0

echo "=== personify: backslash continuation lines (claude-config#595) ==="
# The hook splits a command into one segment per line. Before #595 it did so
# before joining `\<newline>`, so a body flag on a continuation line sat in a
# segment with no verb and was never checked. Each block case below returned
# 0 on origin/main at 866377f.
_case "${PERSONIFY}" "continued commit: approved -F, then -m on the next line" \
  "$(_b64 "git commit -F ${APPROVED_TEXT} \\
  -m x")" 2
_case "${PERSONIFY}" "continued commit: -F unapproved on the next line" \
  "$(_b64 "git commit \\
  -F ${UNAPPROVED_TEXT}")" 2
_case "${PERSONIFY}" "continued gh pr create: --body on the next line" \
  "$(_b64 'gh pr create --title t \
  --body x')" 2
_case "${PERSONIFY}" "continued gh pr review: --body on the next line" \
  "$(_b64 'gh pr review 5 --comment \
  --body x')" 2
_case "${PERSONIFY}" "continued gh issue comment: --body on the next line" \
  "$(_b64 'gh issue comment 5 \
  --body x')" 2
_case "${PERSONIFY}" "continued gh pr comment: --body on the next line" \
  "$(_b64 'gh pr comment 5 \
  --body x')" 2
_case "${PERSONIFY}" "continued gh issue create: --body on the next line" \
  "$(_b64 'gh issue create --title t \
  --body x')" 2
_case "${PERSONIFY}" "continued gh issue edit: --body-file unapproved on the next line" \
  "$(_b64 "gh issue edit 5 \\
  --body-file ${UNAPPROVED_TEXT}")" 2
_case "${PERSONIFY}" "continued gh pr edit: --body-file unapproved on the next line" \
  "$(_b64 "gh pr edit 5 \\
  --body-file ${UNAPPROVED_TEXT}")" 2
_case "${PERSONIFY}" "continued gh pr create: approved --body-file, then --body" \
  "$(_b64 "gh pr create --title t --body-file ${APPROVED_TEXT} \\
  --body x")" 2
_case "${PERSONIFY}" "continued gh api: -f body= on the next line" \
  "$(_b64 'gh api repos/o/r/issues/5/comments \
  -f body=hi')" 2
_case "${PERSONIFY}" "continued gh api over three lines" \
  "$(_b64 'gh api repos/o/r/issues/5/comments \
  -X POST \
  -f body=hi')" 2
_case "${PERSONIFY}" "continued gh api: approved -F body, then inline -f body" \
  "$(_b64 "gh api repos/o/r/issues/5/comments -F body=@${APPROVED_TEXT} \\
  -f body=x")" 2
_case "${PERSONIFY}" "leading assignment on its own continued line" \
  "$(_b64 'PERSONIFY_OK=1 \
git commit -m x')" 2
_case "${PERSONIFY}" "continuation splitting the verb itself" \
  "$(_b64 'gh pr cre\
ate --body x')" 2
_case "${PERSONIFY}" "continuation inside double quotes joins, as bash does" \
  "$(_b64 'bash -c "gh pr create --title t \
  --body x"')" 2
# The join is real, not "any backslash blocks": approved file forms split
# across lines pass.
_case "${PERSONIFY}" "continued commit: -F approved on the next line" \
  "$(_b64 "git commit \\
  -F ${APPROVED_TEXT}")" 0
_case "${PERSONIFY}" "continued gh pr create: --body-file approved on the next line" \
  "$(_b64 "gh pr create --title t \\
  --body-file ${APPROVED_TEXT}")" 0
_case "${PERSONIFY}" "continued gh api: -F body=@approved on the next line" \
  "$(_b64 "gh api repos/o/r/issues/5/comments \\
  -F body=@${APPROVED_TEXT}")" 0
_case "${PERSONIFY}" "continuation right after --body-file=" \
  "$(_b64 "gh pr create --title t --body-file=\\
${APPROVED_TEXT}")" 0
# Plain newlines still separate commands: an approved path on a second line
# must not satisfy an unapproved first line.
_case "${PERSONIFY}" "plain newline: unapproved commit, then approved commit" \
  "$(_b64 "git commit -F ${UNAPPROVED_TEXT}
git commit -F ${APPROVED_TEXT}")" 2
# Verbs need command position, and quoted or heredoc prose is not joined.
# The verb sits right after the quote on purpose: an opening quote counts as
# command position, and the one-line form `echo 'gh pr create --title t
# --body x'` blocks. So these two pass only because the scanner kept the
# newline, not because the matcher missed the verb.
_case "${PERSONIFY}" "control: one-line single-quoted verb and body blocks" \
  "$(_b64 "echo 'gh pr create --title t --body x'")" 2
_case "${PERSONIFY}" "prose: continuation inside single quotes is not joined" \
  "$(_b64 "echo 'gh pr create --title t \\
--body x'")" 0
_case "${PERSONIFY}" "prose: continuation inside \$'...' is not joined" \
  "$(_b64 "echo \$'gh pr create --title t \\
--body x'")" 0
_case "${PERSONIFY}" "here-string <<< opens no heredoc" \
  "$(_b64 "cat <<< EOF
gh pr create --title t \\
  --body x")" 2
_case "${PERSONIFY}" "prose: joined double-quoted text stays mid-sentence" \
  "$(_b64 'echo "see gh pr create --title t \
  --body x to do it"')" 0
_case "${PERSONIFY}" "prose: continued lines in a quoted heredoc are not joined" \
  "$(_b64 "cat <<'EOF' >/tmp/body.md
gh pr create --title t \\
  --body x
EOF")" 0
_case "${PERSONIFY}" "prose: continued lines in an unquoted heredoc are not joined" \
  "$(_b64 'cat <<EOF >/tmp/body.md
gh api repos/o/r/issues/5/comments \
  -f body=hi
EOF')" 0
_case "${PERSONIFY}" "prose: <<- heredoc with a tab-indented delimiter" \
  "$(_b64 "cat <<-EOF >/tmp/body.md
	gh pr create --title t \\
	  --body x
	EOF")" 0
_case "${PERSONIFY}" "heredoc ends, then a continued command after it still blocks" \
  "$(_b64 "cat <<'EOF' >/tmp/body.md
prose
EOF
gh pr create --title t \\
  --body x")" 2
_case "${PERSONIFY}" "escaped backslash at line end is not a continuation" \
  "$(_b64 "git commit -F ${APPROVED_TEXT} \\\\
  -m x")" 0
_case "${PERSONIFY}" "backslash at the end of a comment is not a continuation" \
  "$(_b64 "# run it \\
gh pr create --title t --body x")" 2

echo "=== personify: time-boxed suspension ==="
# gate-review.sh suspended reads SUSPENDED from the fixture GATE_REVIEW_DIR.
# The file is written straight into the fixture here, as Andrew would write
# the real one by hand; nothing in the tool writes it.
SUSP="${GATE_REVIEW_DIR}/SUSPENDED"
_day() {
  date -v"$1"d +%F 2>/dev/null || date -d "$1 days" +%F
}
printf '%s\n' "$(_day +1)" >"${SUSP}"
_case "${PERSONIFY}" "suspended through tomorrow: inline -m passes" \
  "$(_b64 'git commit -m "x"')" 0
_case "${PERSONIFY}" "suspended through tomorrow: unapproved -F passes" \
  "$(_b64 "git commit -F ${UNAPPROVED_TEXT}")" 0
_case "${PERSONIFY}" "suspended through tomorrow: inline PR body passes" \
  "$(_b64 'gh pr create --body "x"')" 0
_case "${PERSONIFY}" "suspended through tomorrow: inline review body passes" \
  "$(_b64 'gh pr review 5 --comment --body "x"')" 0
_case "${PERSONIFY}" "suspended through tomorrow: inline api body passes" \
  "$(_b64 'gh api repos/o/r/issues/5/comments -f body=hi')" 0
_case "${PERSONIFY}" "suspended through tomorrow: continued inline PR body passes" \
  "$(_b64 'gh pr create --title t \
  --body x')" 0
printf '%s\n' "$(date +%F)" >"${SUSP}"
_case "${PERSONIFY}" "suspended through today: unapproved -F passes" \
  "$(_b64 "git commit -F ${UNAPPROVED_TEXT}")" 0
# The notice is printed only when suspension is what let a gated command
# through, so ungated commands stay quiet.
_notice_err="$(printf '{"tool_input":{"command":"ls"}}' | "${PERSONIFY}" 2>&1 >/dev/null)"
if [[ -z "${_notice_err}" ]]; then
  echo "  PASS ungated command prints no suspension notice"
  pass=$((pass + 1))
else
  echo "  FAIL ungated command prints no suspension notice (got: ${_notice_err})"
  fail=$((fail + 1))
fi
_notice_err="$(printf '{"tool_input":{"command":%s}}' "$(printf '%s' 'git commit -m x' | jq -Rs .)" |
  "${PERSONIFY}" 2>&1 >/dev/null)"
if [[ "${_notice_err}" == *"[personify-gate] SUSPENDED until"* ]]; then
  echo "  PASS a suspended gated command prints the notice"
  pass=$((pass + 1))
else
  echo "  FAIL a suspended gated command prints the notice (got: ${_notice_err})"
  fail=$((fail + 1))
fi
printf '%s\n' "$(_day -1)" >"${SUSP}"
_case "${PERSONIFY}" "expired yesterday: inline -m BLOCKS" \
  "$(_b64 'git commit -m "x"')" 2
_case "${PERSONIFY}" "expired yesterday: unapproved -F BLOCKS" \
  "$(_b64 "git commit -F ${UNAPPROVED_TEXT}")" 2
printf '2099-02-31\n' >"${SUSP}"
_case "${PERSONIFY}" "impossible date: unapproved -F BLOCKS" \
  "$(_b64 "git commit -F ${UNAPPROVED_TEXT}")" 2
# Known-bad control: with no SUSPENDED file the gate is armed again, so the
# cases above that passed must block. Proves no state leaked out of them.
rm -f "${SUSP}"
_case "${PERSONIFY}" "no SUSPENDED file: unapproved -F BLOCKS (control)" \
  "$(_b64 "git commit -F ${UNAPPROVED_TEXT}")" 2
_case "${PERSONIFY}" "no SUSPENDED file: inline PR body BLOCKS (control)" \
  "$(_b64 'gh pr create --body "x"')" 2
_case "${PERSONIFY}" "no SUSPENDED file: inline review body BLOCKS (control)" \
  "$(_b64 'gh pr review 5 --comment --body "x"')" 2
_case "${PERSONIFY}" "no SUSPENDED file: inline api body BLOCKS (control)" \
  "$(_b64 'gh api repos/o/r/issues/5/comments -f body=hi')" 2
_case "${PERSONIFY}" "no SUSPENDED file: continued inline PR body BLOCKS (control)" \
  "$(_b64 'gh pr create --title t \
  --body x')" 2

echo "=== dir-write: writes into the lock dirs must BLOCK (exit 2) ==="
# SUSPENDED turns the whole gate off, so an agent that can create it can
# approve everything. It sits in gate-review/ and gets no rule of its own.
_case "${DIRWRITE}" "redirect creating SUSPENDED" \
  "$(_b64 "echo 2099-12-31 > ${HOME}/.claude/gate-review/SUSPENDED")" 2
_case "${DIRWRITE}" "tilde-spelled redirect creating SUSPENDED" \
  "$(_b64 'echo 2099-12-31 > ~/.claude/gate-review/SUSPENDED')" 2
_case "${DIRWRITE}" "noclobber-override redirect creating SUSPENDED" \
  "$(_b64 "echo 2099-12-31 >| ${HOME}/.claude/gate-review/SUSPENDED")" 2
_case "${DIRWRITE}" "noclobber-override redirect into merge-locks" \
  "$(_b64 'echo x >| ~/.claude/merge-locks/fake')" 2
_case "${DIRWRITE}" "touch SUSPENDED" \
  "$(_b64 "touch ${HOME}/.claude/gate-review/SUSPENDED")" 2
_case "${DIRWRITE}" "tee SUSPENDED" \
  "$(_b64 "echo 2099-12-31 | tee ${HOME}/.claude/gate-review/SUSPENDED")" 2
_case "${DIRWRITE}" "cp into SUSPENDED" \
  "$(_b64 "cp /tmp/x ${HOME}/.claude/gate-review/SUSPENDED")" 2
_case "${DIRWRITE}" "rm SUSPENDED (ending it early is his call too)" \
  "$(_b64 "rm ${HOME}/.claude/gate-review/SUSPENDED")" 2
_case "${DIRWRITE}" "cp into merge-locks (the measured hole)" \
  "$(_b64 "cp /tmp/x ${HOME}/.claude/merge-locks/fake")" 2
_case "${DIRWRITE}" "cp into gate-review/approved" \
  "$(_b64 "cp /tmp/x ${HOME}/.claude/gate-review/approved/fake")" 2
_case "${DIRWRITE}" "redirect into approved" \
  "$(_b64 "echo text > ${HOME}/.claude/gate-review/approved/fake")" 2
_case "${DIRWRITE}" "append-redirect into approved" \
  "$(_b64 "echo text >> ${HOME}/.claude/gate-review/approved/fake")" 2
_case "${DIRWRITE}" "tee into approved" \
  "$(_b64 "echo text | tee ${HOME}/.claude/gate-review/approved/fake")" 2
_case "${DIRWRITE}" "sed -i on an approval" \
  "$(_b64 "sed -i '' s/a/b/ ${HOME}/.claude/gate-review/approved/commit-1")" 2
_case "${DIRWRITE}" "mv into approved" \
  "$(_b64 "mv /tmp/x ${HOME}/.claude/gate-review/approved/fake")" 2
_case "${DIRWRITE}" "rm an approval" \
  "$(_b64 "rm ${HOME}/.claude/gate-review/approved/commit-1")" 2
_case "${DIRWRITE}" "touch into approved" \
  "$(_b64 "touch ${HOME}/.claude/gate-review/approved/fake")" 2
_case "${DIRWRITE}" "ln into approved" \
  "$(_b64 "ln -s /tmp/x ${HOME}/.claude/gate-review/approved/fake")" 2
_case "${DIRWRITE}" "tilde-spelled path into merge-locks" \
  "$(_b64 'cp /tmp/x ~/.claude/merge-locks/fake')" 2
_case "${DIRWRITE}" "batch.txt is a gate file too" \
  "$(_b64 "echo '# STATUS: APPROVED' > ${HOME}/.claude/gate-review/batch.txt")" 2
_case "${DIRWRITE}" "redirect into personify checks" \
  "$(_b64 "echo '{}' > ${HOME}/.config/personify/checks/abc.json")" 2
_case "${DIRWRITE}" "cp into personify checks" \
  "$(_b64 "cp /tmp/x ${HOME}/.config/personify/checks/abc.json")" 2
_case "${DIRWRITE}" "tee into personify stamps" \
  "$(_b64 "echo x | tee ${HOME}/.config/personify/stamps/abc.json")" 2
_case "${DIRWRITE}" "tilde-spelled redirect into personify checks" \
  "$(_b64 "echo x > ~/.config/personify/checks/abc.json")" 2

echo "=== dir-write: READS must ALLOW (exit 0) ==="
# The whole point of the gate is `git commit -F <approved file>`. If reading
# from the dir blocked, the approved bytes could never reach git and the gate
# would block the workflow it exists to permit.
_case "${DIRWRITE}" "commit -F from the approved dir" \
  "$(_b64 "git commit -F ${HOME}/.claude/gate-review/approved/commit-1")" 0
_case "${DIRWRITE}" "cat an approval" \
  "$(_b64 "cat ${HOME}/.claude/gate-review/approved/commit-1")" 0
_case "${DIRWRITE}" "ls the approved dir" \
  "$(_b64 "ls -l ${HOME}/.claude/gate-review/approved")" 0
_case "${DIRWRITE}" "grep an approval" \
  "$(_b64 "grep -c . ${HOME}/.claude/gate-review/approved/commit-1")" 0
_case "${DIRWRITE}" "gate-review stage writes via the tool, not a shell redirect" \
  "$(_b64 'gate-review.sh stage commit-1 /tmp/msg.txt')" 0
_case "${DIRWRITE}" "cp OUT of the approved dir" \
  "$(_b64 "cp ${HOME}/.claude/gate-review/approved/commit-1 /tmp/x")" 0
_case "${DIRWRITE}" "unrelated cp" \
  "$(_b64 'cp /tmp/a /tmp/b')" 0
_case "${DIRWRITE}" "cat SUSPENDED" \
  "$(_b64 "cat ${HOME}/.claude/gate-review/SUSPENDED")" 0
_case "${DIRWRITE}" "cat a check record" \
  "$(_b64 "cat ${HOME}/.config/personify/checks/abc.json")" 0
_case "${DIRWRITE}" "the check itself names no record path" \
  "$(_b64 'python3 /x/scripts/pangram_check.py < /tmp/body.md')" 0
_case "${DIRWRITE}" "the key file beside checks/ stays writable" \
  "$(_b64 "chmod 600 ${HOME}/.config/personify/pangram-key")" 0
_case "${DIRWRITE}" "a path merely mentioning the name" \
  "$(_b64 'echo gate-review > /tmp/notes.txt')" 0

# The tool is named after the directory it guards. An earlier pattern matched
# the bare name and made `scripts/gate-review.sh` uneditable -- the hook locked
# out edits to itself. Only paths INSIDE the directories are approval state.
_case "${DIRWRITE}" "writing the gate script itself is not writing the gate dir" \
  "$(_b64 'sed -i "" s/a/b/ /Users/andrewrich/Developer/claude-config/scripts/gate-review.sh')" 0
_case "${DIRWRITE}" "redirect into a file named after the dir" \
  "$(_b64 'echo x > /tmp/gate-review.log')" 0
_case "${DIRWRITE}" "cp to a merge-locks-named file outside the dir" \
  "$(_b64 'cp /tmp/a /tmp/merge-locks.bak')" 0

# A verb only counts in command position. Without that anchor the alternation
# matched the letters wherever they appeared -- `rm` inside "arm", `ln` inside
# "vuln", `dd` inside "add" -- so any PROSE carrying those letters plus a
# --body-file pointing at the approved dir was blocked as a file write. This
# actually happened: `gh pr create --title "...arm the gate..." --body-file
# <approved>` was refused, which is the gate blocking its own PR.
_case "${DIRWRITE}" "prose containing 'arm' with an approved body-file" \
  "$(_b64 "gh pr create --title \"feat(gate): arm the approval gate\" --body-file ${HOME}/.claude/gate-review/approved/pr-body")" 0
_case "${DIRWRITE}" "prose containing 'add' with an approved body-file" \
  "$(_b64 "gh pr comment 1 --body-file ${HOME}/.claude/gate-review/approved/pr-body")" 0
_case "${DIRWRITE}" "prose containing 'vuln' near the dir" \
  "$(_b64 "echo \"vuln scan\" \&\& cat ${HOME}/.claude/gate-review/approved/commit-1")" 0
# The anchor must not weaken a real write that follows a separator.
_case "${DIRWRITE}" "a real rm after && is still blocked" \
  "$(_b64 "echo done \&\& rm ${HOME}/.claude/gate-review/approved/commit-1")" 2

echo "=== merge-locks-write (Write/Edit hook): file_path cases ==="
# This hook reads tool_input.file_path, not a command string, so it gets its
# own payload builder. A temp HOME with no .claude/ stands in for a fresh
# machine, the same fixture test-hooks-unwritable-log.sh uses, so a blocked
# case's log append lands nowhere near the real ~/.claude/blocked-commands.log.
MLWRITE="${SCRIPTS}/hook-block-merge-locks-write.sh"
[[ -x "${MLWRITE}" ]] || {
  echo "missing or not executable: ${MLWRITE}" >&2
  exit 1
}

_wcase() {
  local desc="$1" path="$2" want="$3" tmphome got
  tmphome="$(mktemp -d)"
  printf '{"tool_input":{"file_path":%s}}' "$(printf '%s' "${path}" | jq -Rs .)" |
    HOME="${tmphome}" "${MLWRITE}" >/dev/null 2>&1
  got=$?
  rm -rf "${tmphome}"
  if [[ "${got}" == "${want}" ]]; then
    echo "  PASS (${got}) ${desc}"
    pass=$((pass + 1))
  else
    echo "  FAIL (got ${got} want ${want}) ${desc}"
    fail=$((fail + 1))
  fi
}

_wcase "Write into personify checks" \
  "${HOME}/.config/personify/checks/x.json" 2
_wcase "Write into personify stamps" \
  "${HOME}/.config/personify/stamps/x.json" 2
_wcase "Write into merge-locks" \
  "${HOME}/.claude/merge-locks/x" 2
_wcase "Write SUSPENDED into gate-review" \
  "${HOME}/.claude/gate-review/SUSPENDED" 2
# Assembled so the source holds no quoted leading tilde (SC2088).
_wcase "Write SUSPENDED, tilde-spelled" \
  "$(printf '%s/.claude/gate-review/SUSPENDED' '~')" 2
_wcase "Write into gate-review/approved" \
  "${HOME}/.claude/gate-review/approved/x" 2
_wcase "the key file beside checks/ stays writable" \
  "${HOME}/.config/personify/pangram-key" 0
_wcase "the voice guide beside checks/ stays writable" \
  "${HOME}/.config/personify/VOICE.md" 0
_wcase "a file merely named after the dir" \
  "/tmp/gate-review.log" 0

echo "--- ${pass} passed, ${fail} failed"
[[ "${fail}" == "0" ]]
