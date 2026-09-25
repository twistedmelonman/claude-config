#!/usr/bin/env bash
set -euo pipefail
unset CDPATH

# =========================================================
# run-review.sh — Automated code review via Claude CLI
# =========================================================
#
# Called by commit-msg hook to perform actual code review
# before allowing commits. Uses installed Claude CLI with
# Max subscription (no API charges).
#
# USAGE:
#   git diff --cached | ~/.claude/hooks/run-review.sh
#   git diff main...HEAD | ~/.claude/hooks/run-review.sh --mode=full-diff
#
# FLAGS:
#   --mode=full-diff | --mode=codebase
#       Switch review mode (default: commit / pre-commit).
#   --message-file=PATH | --message-file PATH
#       Read the commit message from PATH instead of $GIT_DIR/COMMIT_EDITMSG.
#       Used by the commit-msg hook to inject the actual in-progress
#       message; pre-commit hooks cannot read the message because git
#       has not yet written it to COMMIT_EDITMSG at pre-commit time
#       (per `man githooks`: pre-commit "is invoked before obtaining
#       the proposed commit log message"). When this flag is absent,
#       behavior is unchanged.
#
# EXIT CODES:
#   0 = Review passed (no blocking issues)
#   1 = Review failed (issues found or error)
#
# CONFIGURATION (via git config):
#   review.maxLines        - Max lines for full review (default: 1000)
#   review.skipThreshold   - Skip AI review beyond this (default: 2500)
#   review.chunkSize       - Max lines per file in chunked mode (default: 800)
#   review.artifactSkip    - Skip AI review when every staged file is a data
#                             artifact (bool, default: true). Commit mode only.
#   review.artifactPatterns - Whitespace-separated globs that REPLACE the
#                             artifact list (default: '*.log *.tsv *.csv
#                             docs/scan/* docs/*/scan/*'). `*` matches `/`.
#   review.model           - Claude model ID for code-reviewer (default: haiku for commits, sonnet for full-diff/codebase)
#   review.adversarialModel - Claude model ID for adversarial-reviewer (default: claude-sonnet-4-6, always, regardless of mode)
#   review.arbiterModel    - Claude model ID for the reconciliation arbiter
#                             (default: claude-sonnet-4-6, only invoked when
#                             code-reviewer BLOCKING FAIL disagrees with an
#                             adversarial-reviewer PASS)
#
# EXAMPLES:
#   git config --global review.maxLines 2000
#   git config review.skipThreshold 5000
#
# PROGRESSIVE REVIEW STRATEGY:
#   - Small diffs (≤ maxLines): Full review
#   - Medium diffs (maxLines to skipThreshold): Chunked file-by-file review.
#     Any file that is not reviewed (diff > chunkSize, agent error) BLOCKS
#     the commit as INCOMPLETE; it is never counted as a pass (#451).
#   - Large diffs (> skipThreshold): BLOCKED - must split into smaller commits
#
# STRICT MODE: This script blocks commits when:
#   - Review finds code quality issues (BLOCKING severity)
#   - code-reviewer times out or errors (incomplete review): per file on the
#     chunked path (#451), and on the whole-diff commit path (#590)
#   - Diff is too large for automated review
#   - Review output cannot be parsed (unverified result)
#
# It does NOT block when adversarial-reviewer times out or errors on the
# whole-diff commit path ("code-reviewer only"), or when the full-diff
# pre-push review does. Both are reported as INCOMPLETE or skipped, never as
# a pass (#590). A timeout is never a finding: nothing is filed for it (#172).
#
# Rationale: Unverified code is unsafe code. If the review cannot complete,
# we cannot verify the code is safe to commit.
#
# =========================================================

# --- Configuration ---
CLAUDE_CLI="${CLAUDE_CLI:-${HOME}/.local/bin/claude}"
TIMEOUT_SECONDS=$(git config --get --type=int review.timeout 2>/dev/null || echo "120")
# Seconds a reviewer may run with no answer before one "still waiting" line
# is printed to stderr (#590). 0 turns it off. A value at or past the
# timeout prints nothing: the timeout message says it all.
SLOW_NOTICE_SECONDS=$(git config --get --type=int review.slowNotice 2>/dev/null || echo "45")

# Dry-run: run the review exactly as a real run, but print non-blocking
# findings to stdout instead of filing them. Set by --no-file or by
# REVIEW_NO_FILE=1 in the environment.
#
# This exists so reading findings before they become issues does not require
# stubbing `gh` from outside on PATH. A blanket gh stub also breaks the
# reviewer's own environment probes (_repo_has_issues_enabled, repo-owner
# detection), so a stubbed run is not guaranteed to be the same review as a
# real one; this flag suppresses only the filing step. See #415.
REVIEW_NO_FILE="${REVIEW_NO_FILE:-}"

# Progressive review configuration (with git config overrides)
REVIEW_MAX_LINES=$(git config --get --type=int review.maxLines 2>/dev/null || echo "1000")
REVIEW_SKIP_THRESHOLD=$(git config --get --type=int review.skipThreshold 2>/dev/null || echo "2500")
REVIEW_CHUNK_SIZE=$(git config --get --type=int review.chunkSize 2>/dev/null || echo "800")

# --- Mode ---
REVIEW_MODE="commit" # default: pre-commit review (code-reviewer + adversarial)
# --- Optional commit-message override ---
# When set, _read_commit_message reads from this path instead of the
# default per-mode source. Wired by the commit-msg hook so the reviewer
# sees the actual in-progress message (pre-commit cannot do this — see
# header comment block above and `man githooks`).
MESSAGE_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode=full-diff) REVIEW_MODE="full-diff" ;;
    --mode=codebase) REVIEW_MODE="codebase" ;;
    --mode=*)
      echo "Unknown mode: $1" >&2
      exit 1
      ;;
    --no-file) REVIEW_NO_FILE=1 ;;
    --message-file=*) MESSAGE_FILE="${1#*=}" ;;
    --message-file)
      # Space-form: consume value as $2, then shift past it. We do NOT inner-
      # shift first and then rely on the outer shift, because if the flag was
      # the LAST argument with no value (`--message-file` alone), the outer
      # shift would fail with "shift count out of range" under set -e and
      # abort the script. `${2:-}` safely returns "" when $2 is unset.
      MESSAGE_FILE="${2:-}"
      [[ $# -ge 2 ]] && shift
      ;;
    # Unrecognized arguments are ignored, not fatal. This hook runs on every
    # commit across every repo, invoked by git hooks whose argument lists we
    # do not control; erroring here would block commits fleet-wide. Unknown
    # --mode=* values DO error, above.
    *) ;;
  esac
  shift
done

# Override timeout for codebase mode (longer due to tool-access exploration)
if [[ "${REVIEW_MODE}" == "codebase" ]]; then
  TIMEOUT_SECONDS=$(git config --get --type=int review.codebaseTimeout 2>/dev/null || echo "300")
fi

# --- Model selection ---
# Priority: git config review.model > mode-based default > CLI default
# Haiku for commit-level (small diffs, fast feedback); Sonnet for branch/codebase analysis.
# This REVIEW_MODEL / CODE_REVIEWER_MODEL_ARGS pair governs code-reviewer (and,
# in full-diff/codebase mode, the single reviewer invocation issued there —
# see ADVERSARIAL_MODEL_ARGS below for why those specific call sites use the
# adversarial model instead).
REVIEW_MODEL=$(git config --get review.model 2>/dev/null || echo "")
if [[ -z "${REVIEW_MODEL}" ]]; then
  case "${REVIEW_MODE}" in
    commit) REVIEW_MODEL="claude-haiku-4-5-20251001" ;;
    full-diff) REVIEW_MODEL="claude-sonnet-4-6" ;;
    codebase) REVIEW_MODEL="claude-sonnet-4-6" ;;
    *) REVIEW_MODEL="" ;;
  esac
fi
CODE_REVIEWER_MODEL_ARGS=()
if [[ -n "${REVIEW_MODEL}" ]]; then
  CODE_REVIEWER_MODEL_ARGS=(--model "${REVIEW_MODEL}")
fi

# adversarial-reviewer gets its own model, independent of REVIEW_MODE.
# code-reviewer's mechanical issue-spotting is a legitimate Haiku task, but
# adversarial-reviewer's assume-wrong-until-proven reasoning benefits from a
# bigger model even on the highest-frequency path (commit mode) — see issue
# #235. Override via `git config review.adversarialModel <model-id>`.
ADVERSARIAL_MODEL=$(git config --get review.adversarialModel 2>/dev/null || echo "")
[[ -n "${ADVERSARIAL_MODEL}" ]] || ADVERSARIAL_MODEL="claude-sonnet-4-6"
ADVERSARIAL_MODEL_ARGS=(--model "${ADVERSARIAL_MODEL}")

# Arbiter model: used only when code-reviewer and adversarial-reviewer
# disagree (BLOCKING FAIL vs PASS) in commit mode. Defaults to the same
# model as adversarial-reviewer since both need the bigger-model reasoning
# the disagreement itself signals is warranted.
ARBITER_MODEL=$(git config --get review.arbiterModel 2>/dev/null || echo "")
[[ -n "${ARBITER_MODEL}" ]] || ARBITER_MODEL="claude-sonnet-4-6"
ARBITER_MODEL_ARGS=(--model "${ARBITER_MODEL}")

# --- Reviewer agent selection ---
# Pinned to a fully-qualified plugin:agent name (git config review.codeReviewerAgent
# to override). The bare name "code-reviewer" broke once a second installed plugin
# also shipped an agent literally named "code-reviewer" — Claude CLI refuses
# ambiguous bare names, so every commit's code-reviewer pass silently errored
# (non-blocking, but useless). The installed agent ID doubles the plugin name —
# comprehensive-review:comprehensive-review-code-reviewer — per the
# comprehensive-review plugin's agents/code-reviewer.md frontmatter; verify with
# `claude --agent bogus -p` (its "Available agents" error lists the real IDs).
# adversarial-reviewer stays a bare name since it is still unique (ships as the
# code-critic plugin in smartwatermelon-marketplace, see CUSTOM_AGENTS.md).
CODE_REVIEWER_AGENT=$(git config --get review.codeReviewerAgent 2>/dev/null || echo "comprehensive-review:comprehensive-review-code-reviewer")

# --- Colors ---
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Helpers ---
log_info() { echo -e "${BLUE}[review]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[review]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[review]${NC} $*" >&2; }
log_error() { echo -e "${RED}[review]${NC} $*" >&2; }

# Normalize an agent's VERDICT line into a bare token, tolerant of markdown
# emphasis (**PASS**, `PASS`, _PASS_), case, and spacing that would defeat a
# literal `grep "VERDICT: PASS"`. Echoes PASS | FAIL | REVISE | "" (unparseable).
# Preserves the original "PASS anywhere wins" precedence. Transient markers such
# as "VERDICT: FAIL (timeout)" still normalize to FAIL; callers that must
# distinguish those re-inspect the raw output separately.
parse_verdict() {
  local _norm
  # Structured first, prose second. Everything reaching here is normally
  # unwrapped by normalize_agent_response, but a raw SDK envelope that slips
  # through has no `VERDICT:` line — the verdict lives at
  # .structured_output.verdict — so the prose grep below returns "" and the
  # caller reads "unparseable" as "untrustworthy" and blocks. That blocked a
  # commit whose review had actually PASSed (smartwatermelon/claude-config#448).
  #
  # Reading the structured field first makes the call site correct regardless
  # of how the value arrived, rather than enumerating the shapes prose can
  # take. Non-JSON input fails the jq and costs one failed parse.
  local _structured
  _structured=$(printf '%s' "$1" | jq -er '
    if (.structured_output.verdict | type) == "string"
    then (.structured_output.verdict | ascii_upcase)
    else halt_error(3) end' 2>/dev/null) || _structured=""
  case "${_structured}" in
    PASS | FAIL | REVISE)
      printf '%s\n' "${_structured}"
      return 0
      ;;
    *)
      # Absent, empty, or an unrecognized spelling — fall through to the prose
      # parser below rather than inventing a verdict from a value we do not
      # understand.
      ;;
  esac

  _norm=$(printf '%s\n' "$1" | tr -d '*`_')
  if printf '%s\n' "${_norm}" | grep -qiE 'VERDICT:[[:space:]]*PASS'; then
    echo "PASS"
  elif printf '%s\n' "${_norm}" | grep -qiE 'VERDICT:[[:space:]]*FAIL'; then
    echo "FAIL"
  elif printf '%s\n' "${_norm}" | grep -qiE 'VERDICT:[[:space:]]*REVISE'; then
    echo "REVISE"
  else
    echo ""
  fi
}

# Explain WHY a verdict could not be read, rather than only that it could not.
# "Could not parse verdict" printed above output containing `"verdict":"PASS"`
# sends the reader hunting for a reviewer problem that does not exist
# (smartwatermelon/claude-config#448). $1 = the unparseable output.
describe_unparseable_verdict() {
  local _o="$1"
  # jq's exit codes carry the distinction that matters here: 5 means "this text
  # is not valid JSON", 1 means "valid JSON, the key is absent or false".
  # Reporting them identically is what routed #461 to the "prose carrying no
  # VERDICT: line" branch and cost #450 an entire misdirected investigation.
  # Check for contamination FIRST, since a blob of envelope-plus-noise fails
  # every test below for the wrong reason.
  local _jq_status=0
  printf '%s' "${_o}" | jq -e . >/dev/null 2>&1 || _jq_status=$?
  local _envelope
  _envelope=$(extract_json_envelope "${_o}")
  # A recovered envelope that DIFFERS from the input is the signature of
  # contamination: valid JSON was in there, adjacent text defeated the parse.
  if [[ ${_jq_status} -eq 5 ]] && [[ "${_envelope}" != "${_o}" ]]; then
    local _ev
    _ev=$(printf '%s' "${_envelope}" | jq -r '.structured_output.verdict // "(absent)"' 2>/dev/null) || _ev="(unreadable)"
    log_error "The output is a JSON envelope with non-JSON text concatenated to it."
    log_error "jq exited 5 (parse error) on the whole blob, so the verdict was never read."
    log_error "The envelope's own .structured_output.verdict is: ${_ev}"
    log_error "This is a bug in this hook, not a reviewer failure — see claude-config#461."
  elif printf '%s' "${_o}" | jq -e '.structured_output' >/dev/null 2>&1; then
    local _v
    _v=$(printf '%s' "${_o}" | jq -r '.structured_output.verdict // "(absent)"' 2>/dev/null) || _v="(unreadable)"
    log_error "The output is a raw SDK envelope that reached the gate unrendered."
    log_error "Its .structured_output.verdict is: ${_v}"
    log_error "This is a bug in this hook, not a reviewer failure — see claude-config#448."
  elif printf '%s' "${_o}" | jq -e . >/dev/null 2>&1; then
    log_error "The output parsed as JSON but carried no .structured_output."
  elif [[ -z "${_o//[[:space:]]/}" ]]; then
    log_error "The output was empty."
  else
    log_error "The output is prose carrying no recognizable VERDICT: line."
    log_error "NOTE: this describes the value the GATE received, which is not"
    log_error "necessarily what the reviewer returned — normalize_agent_response"
    log_error "runs in between. If the terminal above shows a JSON envelope with"
    log_error "a .structured_output.verdict, that verdict was dropped by a"
    log_error "transform, not missing from the review (claude-config#450)."
  fi
  # The printed *_DISPLAY copy is stripped, so the operator never sees the value
  # the parser actually saw. Persist it — recovering it cost a full session in
  # both #448 and #450 (issue #450, suggested step 1).
  # Only claim the append when it actually succeeded. A redirection to an
  # unwritable path fails the block, and announcing a file the operator will
  # then not find sends them chasing a second phantom on top of the first.
  # The outer `2>/dev/null` catches bash's own "No such file" on the failed
  # redirection; an inner one would not, since it applies to the block's
  # commands rather than to the `>>` itself.
  if [[ -n "${REVIEW_LOG:-}" ]] && {
    {
      echo "--- unparseable verdict: raw value seen by the gate ---"
      printf '%s\n' "${_o}"
      echo "--- end raw value ---"
    } >>"${REVIEW_LOG}"
  } 2>/dev/null; then
    log_error "Raw gate input appended to: ${REVIEW_LOG}"
  fi
}

# True when reviewer output declares a BLOCKING severity. Tolerant of markdown
# emphasis (**SEVERITY:** BLOCKING, `SEVERITY: BLOCKING`), case, and spacing,
# exactly like parse_verdict — the five severity gates previously used a bare
# `grep -q "SEVERITY: BLOCKING"`, so markdown-bolded, lowercased, or
# double-spaced emissions from a prose-heavy prompt slipped the gate and let a
# real blocking defect through (dev-env review-pipeline-redesign, item 3).
#
# Deliberately a substring match, matching the previous behavior: prose such as
# "this is not a SEVERITY: BLOCKING issue" still matches. That fails closed
# (blocks a commit that might have passed), which is the safe direction for a
# gate, and it is unchanged from the literal grep this replaces.
#
# "SEVERITY: NON_BLOCKING_ISSUE" does not match, but only because `_` is
# stripped to leave NONBLOCKING and the pattern requires BLOCKING to follow
# the colon directly. That is a consequence of two transforms, not an explicit
# exclusion: a future severity token spelled without underscores (a bare
# "NON BLOCKING") would match and wrongly block. Add an explicit exclusion
# here if such a token is ever introduced; tests/test_has_blocking_severity.bats
# pins the current behavior.
has_blocking_severity() {
  printf '%s\n' "$1" | tr -d '*`_' | grep -qiE 'SEVERITY:[[:space:]]*BLOCKING'
}
# --- Structured reviewer output (claude-config#443) ---
#
# A reviewer's blocking/non-blocking call is a BOOLEAN. It was transported as
# prose and re-derived by grep at five call sites. #442 made that grep tolerant
# of six known leak variants (markdown, case, spacing); there is no reason to
# believe six is the complete set, because enumerating the ways a model can
# spell a word is not a terminating exercise.
#
# The CLI can return a schema-constrained object alongside the prose:
#   claude --output-format json --json-schema "${REVIEW_JSON_SCHEMA}" ...
# The response then carries `.structured_output` next to the text `.result`.
# The prose is still needed (DETAILS for the human, issue filing, arbiter
# input, logs), so this ADDS a decision channel rather than replacing output.
#
# Phase 1 built the transport. Phase 2 (design items 2 and 4) uses it to carry
# the taxonomy:
#
#   severity: BLOCKING | FIX_NOW | WARNING
#     BLOCKING - a defect introduced by this diff. Blocks.
#     FIX_NOW  - a small, mechanical, concrete edit. Commit stage only.
#                PRINTED ONLY: blocks nothing, and has NO FILING PATH anywhere
#                in this file. That absence is the design constraint, not an
#                oversight - see emit_fix_now_entries(). Do not add a flag,
#                a config key, or an env var that could route it to
#                create_nonblocking_issues; a switchable filing path is how
#                this tier becomes the next firehose.
#     WARNING  - reported, does not block. The pre-existing tier.
#
#   details: the human-readable explanation and fix.
#     Phase 1 modelled a finding as {severity, location, issue} with no
#     `details`, so the rendered DETAILS line was a VERBATIM repeat of ISSUE on
#     every finding - measured live against the real CLI after #444 merged.
#     Under the prose contract DETAILS carried the explanation AND the fix, so
#     that repeat was a real, user-visible loss of content. `details` restores
#     it; the renderer falls back to `issue` when a reviewer omits it.
#
# Kept on ONE line: --json-schema takes the schema INLINE as a JSON string,
# not a file path.
REVIEW_JSON_SCHEMA='{"type":"object","required":["verdict","blocking","findings"],"properties":{"verdict":{"type":"string","enum":["PASS","FAIL"]},"blocking":{"type":"boolean"},"findings":{"type":"array","items":{"type":"object","required":["severity","location","issue"],"properties":{"severity":{"type":"string","enum":["BLOCKING","FIX_NOW","WARNING"]},"location":{"type":"string"},"issue":{"type":"string"},"details":{"type":"string"}}}}}}'

# Sentinel line carrying the structured decision from an agent invocation to
# the gates downstream. invoke_agent returns prose on stdout and every caller
# captures it by command substitution, so the boolean rides along as a leading
# line rather than requiring a second return channel through subshells,
# temp files, and background jobs.
#
# Only ever emitted by this script from a verified JSON boolean, and stripped
# before the prose reaches a human, a log, or another agent's prompt.
STRUCTURED_MARKER="__REVIEW_BLOCKING__"

# A literal newline, for building multi-line fallbacks readably.
_NL=$'\n'

# THE FAIL-OPEN TRAP, stated so it is not reintroduced:
#
#   jq -e '.structured_output.blocking'
#
# exits 1 for THREE distinct situations — blocking=false (a legitimate PASS),
# the key being absent (broken or truncated response), and blocking=null
# (malformed). "The reviewer said it is fine" and "the reviewer never answered"
# become indistinguishable, which is exactly the silent-failure/false-OK class
# this pipeline exists to catch. The mirror hazard: the STRING "false" is
# TRUTHY in jq, so a type slip blocks everything.
#
# So: require a real JSON boolean, and report the three outcomes distinctly.
#   exit 0, prints "true"  -> reviewer says BLOCK
#   exit 0, prints "false" -> reviewer says PASS (it genuinely answered)
#   exit 3                 -> absent / null / wrong type (no usable answer)
#   exit 4                 -> jq could not parse the input at all (e.g. a
#                             timeout's zero bytes)
# Callers MUST NOT collapse "false" and "no answer" into one branch.
extract_structured_blocking() {
  printf '%s' "$1" | jq -er '
    if (.structured_output.blocking | type) == "boolean"
    then (.structured_output.blocking | tostring)
    else halt_error(3) end' 2>/dev/null
}

# Prepend the structured decision to an agent's prose so it survives the
# command-substitution return path. $1 = "true"|"false", $2 = prose.
attach_structured_blocking() {
  printf '%s %s\n%s\n' "${STRUCTURED_MARKER}" "$1" "$2"
}

# Read back a sentinel attached above. Echoes "true", "false", or "" when the
# output carries no structured decision (fallback territory).
#
# Anchored to the start of a line and to the two literal words, so reviewer
# prose that merely quotes the marker cannot forge a decision.
read_structured_blocking() {
  local _line
  _line=$(printf '%s\n' "$1" | grep -m1 -E "^${STRUCTURED_MARKER} (true|false)$" || true)
  [[ -n "${_line}" ]] || return 0
  printf '%s\n' "${_line##* }"
}

# --- FIX_NOW transport (claude-config#443 phase 2, design item 2) ---
#
# A FIX_NOW finding is PRINTED AT COMMIT TIME AND NOTHING ELSE. It does not
# block, and there is NO code path from here to create_nonblocking_issues() or
# to any other filing call. Do not add one, and do not add a flag that would
# enable one: the design makes that absence the mechanism that stops this tier
# becoming the next issue firehose.
#
# Transport mirrors STRUCTURED_MARKER: the renderer drops FIX_NOW findings out
# of the prose block (so no gate and no issue filer can ever see them), so they
# need their own channel back through the command-substitution return path that
# every invoke_agent caller uses. One line, one finding, JSON-encoded so an
# embedded newline in a reviewer string cannot forge extra entries.
FIX_NOW_MARKER="__REVIEW_FIX_NOW__"

# Cap per the design: beyond this many, print a count instead of a wall of
# text. A commit generating more than this many mechanical fixes signals a
# calibration problem better seen as one number.
FIX_NOW_MAX=5

# Pull FIX_NOW findings out of a raw CLI envelope, one compact JSON object per
# line. Empty output (no findings, no structured output, unparseable) is normal
# and not an error.
extract_fix_now() {
  printf '%s' "$1" | jq -c '
    (.structured_output.findings // [])
    | map(select((.severity // "") | ascii_upcase == "FIX_NOW"))
    | .[]' 2>/dev/null || true
}

# Attach FIX_NOW findings as sentinel lines beneath the prose. $1 = the
# newline-separated JSON objects from extract_fix_now, $2 = prose.
attach_fix_now() {
  local _entries="$1" _prose="$2" _line
  printf '%s\n' "${_prose}"
  [[ -n "${_entries}" ]] || return 0
  while IFS= read -r _line; do
    [[ -n "${_line}" ]] || continue
    printf '%s %s\n' "${FIX_NOW_MARKER}" "${_line}"
  done <<<"${_entries}"
}

# Read FIX_NOW sentinels back out of an agent's returned text.
read_fix_now() {
  printf '%s\n' "$1" | grep -E "^${FIX_NOW_MARKER} " | sed -E "s/^${FIX_NOW_MARKER} //" || true
}

# Print the FIX_NOW block for a commit-stage review. Advisory output only:
# always returns 0, never touches the exit status, never files anything.
#
# One line per entry, `file:line - what to change`, per the design's 15-word
# target. No DETAILS block, no rationale - that shape is what keeps the
# hedging problem from moving out of GitHub and into the terminal.
emit_fix_now_entries() {
  local _entries="$1" _count _shown _line _loc _issue
  [[ -n "${_entries}" ]] || return 0
  _count=$(printf '%s\n' "${_entries}" | grep -c . || true)
  [[ "${_count}" -gt 0 ]] || return 0

  echo "" >&2
  echo "=== FIX NOW (${_count}) — not blocking, not filed ===" >&2
  if [[ "${_count}" -gt "${FIX_NOW_MAX}" ]]; then
    # Over the cap: a count only, per the design.
    printf '%s mechanical fixes suggested (over the %s-entry cap; not listed).\n' \
      "${_count}" "${FIX_NOW_MAX}" >&2
  else
    _shown=0
    while IFS= read -r _line; do
      [[ -n "${_line}" ]] || continue
      _loc=$(printf '%s' "${_line}" | jq -r '.location // "unspecified"' 2>/dev/null || echo "unspecified")
      _issue=$(printf '%s' "${_line}" | jq -r '.issue // ""' 2>/dev/null || echo "")
      [[ -n "${_issue}" ]] || continue
      printf '  %s — %s\n' "${_loc}" "${_issue}" >&2
      _shown=$((_shown + 1))
    done <<<"${_entries}"
    [[ "${_shown}" -gt 0 ]] || return 0
  fi
  echo "" >&2
  return 0
}

# Strip the sentinels so prose handed to humans, logs, issue filing, and other
# agents' prompts looks exactly as it did before this change. FIX_NOW lines are
# stripped here too: they must never reach lib-review-issues.sh, an arbiter
# prompt, or the review log's reviewer blocks.
strip_structured_blocking() {
  printf '%s\n' "$1" | grep -vE "^(${STRUCTURED_MARKER}|${FIX_NOW_MARKER}) " || true
}

# The gate. Answers "does this reviewer output block?" using the structured
# boolean when the reviewer genuinely answered, and #442's tolerant prose
# matcher when it did not.
#
# Returns 0 (block) / 1 (do not block). The three-way flow:
#   sentinel "true"  -> block. Structured, authoritative.
#   sentinel "false" -> do NOT block. The reviewer answered; do not second-
#                       guess it with a grep over its own explanatory prose,
#                       which is what makes the boolean worth having.
#   no sentinel      -> NO USABLE ANSWER. Fall back to has_blocking_severity()
#                       on the text (an older CLI, a malformed response, a
#                       cached pre-#443 result, a synthetic transient verdict).
#                       That matcher fails closed on ambiguity, which is the
#                       correct direction for a gate.
#
# Transient infrastructure failures (timeout, agent error) reach here as
# synthetic "VERDICT: FAIL (timeout)" prose with no sentinel and no SEVERITY
# line, so they land in the fallback branch and do not block here. Callers
# must then ask is_transient_verdict() before calling the run a pass: a
# reviewer that never ran has not reviewed anything (#590). A code-reviewer
# timeout blocks the commit as INCOMPLETE on the chunked (#451) and
# whole-diff (#590) paths; the full-diff path allows it through and reports
# it as INCOMPLETE.
output_blocks() {
  local _decision
  _decision=$(read_structured_blocking "$1")
  case "${_decision}" in
    true) return 0 ;;
    false) return 1 ;;
    *) has_blocking_severity "$1" ;;
  esac
}

# True when reviewer output $1 is one of invoke_agent's synthetic transient
# verdicts ("VERDICT: FAIL (timeout)", "VERDICT: FAIL (agent error: N)"), or
# the empty-output stand-in the callers build. Such output means the reviewer
# did NOT review the diff. Line-anchored, and callers ask output_blocks()
# FIRST, so a real review that quotes this string in its DETAILS can never be
# relabelled from blocking to incomplete. The Revise form is covered for
# #172.
is_transient_verdict() {
  # Only the exact synthetic forms: "(timeout)" and "(agent error: ...)".
  printf '%s\n' "$1" | grep -qE '^VERDICT: (FAIL|Revise) \((timeout\)|agent error:)'
}

# One-word reason for a transient verdict, for the review log.
transient_reason() {
  if printf '%s\n' "$1" | grep -qE '^VERDICT: (FAIL|Revise) \(timeout'; then
    printf 'timeout'
  else
    printf 'agent error'
  fi
}

# Run the CLI with structured output and normalise the response.
#
# $1 = raw CLI stdout (a --output-format json envelope, in principle).
#
# MEASURED, and it contradicts the obvious reading of the CLI contract: under
# --json-schema the model is constrained to a schema-conforming TOOL CALL, so
# it does not emit prose at all. `.result` holds the SERIALIZED JSON object,
# not a VERDICT/ISSUE/SEVERITY block. Verified against the real CLI:
#   .result == "{\"verdict\":\"FAIL\",\"blocking\":true,\"findings\":[...]}"
#
# Everything downstream reads prose — parse_verdict, the version-pin downgrade,
# NON_BLOCKING_ISSUE filing, round-history feedback, the arbiter's prompt, the
# human-facing log. Handing them a JSON blob makes parse_verdict return "" and
# the run hard-blocks as "unparseable", which is how this was caught.
#
# So when structured output is present, RENDER the prose from it. The structured
# object is authoritative and the rendered text is derived from it, which is the
# right direction: one source of truth, and the prose can no longer disagree
# with the boolean.
#
# Echoes the reviewer's prose with a structured sentinel attached when the
# response carried a real boolean; echoes the input unchanged otherwise, so a
# non-JSON response (older CLI, error text, an empty timeout) degrades to the
# prose path instead of being discarded.
# Render the VERDICT/ISSUE/SEVERITY/LOCATION/DETAILS block the rest of the
# pipeline reads, straight from a raw envelope's .structured_output.
#
# $1 = raw CLI envelope. Prints the rendered prose, or nothing when the
# envelope has no renderable structured output.
#
# Shared by BOTH of normalize_agent_response's structured paths. It used to be
# inlined in the boolean-present branch only, which is how #450's first fix
# came to prepend a bare verdict line in the other branch instead of rendering
# — and prepending left `.result`'s serialized JSON as the only "prose" a
# severity gate could grep, which no severity pattern matches. One renderer,
# used by both branches, removes that asymmetry at the source.
#
# DETAILS comes from the finding's own `details`, falling back to `issue` only
# when the reviewer omitted one.
#
# The `type != "object"` guard is a DELIBERATE divergence from the jq this was
# extracted from: on `structured_output: null` or absent, the old inlined form
# evaluated `$o.verdict // (if $o.blocking then ...)` to `VERDICT: PASS` —
# inventing a passing verdict out of a null. Both inputs are unreachable from
# the boolean-present branch (extract_structured_blocking requires
# .structured_output.blocking to be a JSON boolean, which requires an object
# parent), so this changes no current behavior. Keep the guard: it makes the
# helper safe for a future caller that does not pre-screen its input.
#
# FIX_NOW findings are EXCLUDED. They are not part of the block a gate or an
# issue filer reads; they are printed separately, at the commit stage only, by
# emit_fix_now_entries(). Rendering them here would feed them to
# has_blocking_severity() and to lib-review-issues.sh, which is precisely what
# must not happen.
render_structured_prose() {
  printf '%s' "$1" | jq -r '
    .structured_output as $o
    | if ($o | type) != "object" then "" else
      ([ "VERDICT: " + ($o.verdict // (if $o.blocking then "FAIL" else "PASS" end)) ]
       + ( ($o.findings // [])
           | map(select((.severity // "WARNING") | ascii_upcase != "FIX_NOW"))
           | map( "\nISSUE: " + (.issue // "unspecified")
                  + "\nSEVERITY: " + (.severity // "WARNING")
                  + "\nLOCATION: " + (.location // "unspecified")
                  + "\nDETAILS: " + (.details // .issue // "unspecified") ) )
      ) | join("\n") end' 2>/dev/null || true
}

# Recover the SDK envelope from a blob that may carry adjacent non-JSON text.
#
# claude-config#461: a diagnostic line concatenated with the envelope —
# observed verbatim as
#   Client.listTools() called but server does not advertise tools capability - returning empty list
# — makes jq exit 5 (PARSE ERROR) rather than 1 (key absent) on the whole blob.
# Every jq in the parse path then fails, normalize_agent_response takes its
# "not an envelope" branch, and the gate receives the raw blob as prose. Prose
# carries no `VERDICT:` line, so a clean PASS blocked the push — the same
# user-visible failure as #448 and #450, on a third call site.
#
# Extracting the envelope makes the parse immune to adjacent noise WHATEVER its
# source, instead of suppressing warning strings one at a time. #89 fixed this
# hazard once already (stderr merged into stdout) and it returned in a new
# form; enumerating strings does not close the class.
#
# Strategy, cheapest first:
#   1. The blob already parses as an object with a string .result — the normal
#      case, no noise. Return it untouched, costing one jq on the hot path.
#   2. Otherwise scan the lines for envelopes. If more than one line parses as
#      an envelope, prefer a BLOCKING one over a non-blocking one.
#
# On multiple envelopes, "the last one wins" would be the wrong precedence for
# a safety gate: a PASS envelope appended after a real FAIL would suppress the
# FAIL. This is not known to be reachable — the CLI emits one envelope — but a
# gate should not depend on that for its fail-closed property. So a blocking
# envelope always beats a non-blocking one, and only among equals does the last
# win (noise is typically appended, so the later object is the likelier
# envelope).
#
# KNOWN LIMIT: the scan is line-based, so a PRETTY-PRINTED envelope split
# across lines is not recoverable once noise is attached to it. That case
# yields no envelope and the gate blocks as unparseable — fail-closed, which is
# the correct direction. The CLI emits single-line JSON under
# --output-format json; if that ever changes, this needs a brace-balancing
# scanner instead.
#
# Anything that yields no envelope is echoed back unchanged, so genuine prose
# (older CLI, error text, a timeout's empty output) degrades exactly as before.
#
# $1 = the captured blob. Prints the envelope, or $1 unchanged.
extract_json_envelope() {
  local _blob="$1" _line
  # GUARD: never extract from something that is already usable prose.
  #
  # Scanning unconditionally is a FAIL-OPEN. A genuine prose review that merely
  # QUOTES an envelope — routine when the reviewer is reviewing this very file,
  # since a finding about envelope handling naturally quotes one in DETAILS —
  # would have the whole review discarded in favour of the quoted line. A
  # BLOCKING FAIL then reaches the gate as PASS. Measured against HEAD: the
  # unguarded version turned `VERDICT: FAIL / SEVERITY: BLOCKING` into a clean
  # pass.
  #
  # #461's shape has no VERDICT: line — it is an envelope plus noise. So prose
  # carrying its own parseable verdict is left strictly alone, which confines
  # this recovery to the case it was written for.
  if printf '%s\n' "${_blob}" | tr -d '*`_' | grep -qiE '^[[:space:]]*VERDICT:[[:space:]]*(PASS|FAIL|REVISE)'; then
    printf '%s' "${_blob}"
    return 0
  fi
  # Fast path: already a clean, SINGLE envelope.
  #
  # `-s` (slurp) is load-bearing. jq reads a STREAM of JSON values, so a blob
  # holding two concatenated envelopes satisfies a bare `type == "object"` test
  # and `-e` then reports only the LAST value's status — which would return
  # both envelopes here and let a trailing PASS mask a leading FAIL. Slurping
  # collects the values into an array, so `length == 1` genuinely means "one
  # value", and the multi-envelope case correctly falls through to the scan.
  if printf '%s' "${_blob}" | jq -se 'length == 1 and (.[0] | type) == "object" and (.[0].result | type) == "string"' >/dev/null 2>&1; then
    printf '%s' "${_blob}"
    return 0
  fi
  # Slow path: find the envelope line(s) among the noise.
  local _candidate="" _blocking_candidate=""
  while IFS= read -r _line; do
    case "${_line}" in
      '{'*) ;;
      *) continue ;;
    esac
    printf '%s' "${_line}" | jq -e 'type == "object" and (.result | type) == "string"' >/dev/null 2>&1 || continue
    _candidate="${_line}"
    # A blocking envelope wins outright and is never overwritten by a later
    # non-blocking one. `blocking` may legitimately be absent or a string here
    # (see #450), so a FAIL/REVISE verdict counts as blocking too.
    if printf '%s' "${_line}" | jq -e '
      (.structured_output.blocking == true)
      or ((.structured_output.verdict // "" | ascii_upcase) as $v
          | $v == "FAIL" or $v == "REVISE")' >/dev/null 2>&1; then
      _blocking_candidate="${_line}"
    fi
  done < <(printf '%s\n' "${_blob}")

  if [[ -n "${_blocking_candidate}" ]]; then
    printf '%s' "${_blocking_candidate}"
    return 0
  fi
  if [[ -n "${_candidate}" ]]; then
    printf '%s' "${_candidate}"
    return 0
  fi
  # No envelope found — hand back what we were given.
  printf '%s' "${_blob}"
}

normalize_agent_response() {
  local _raw
  # Strip adjacent non-JSON noise before any parse (claude-config#461). A
  # no-op when the input is a clean envelope or genuine prose.
  _raw=$(extract_json_envelope "$1")
  local _blocking _result _rendered _fixnow _withfix

  # Nothing to parse. Hand it back untouched; callers already normalise empty
  # output into a synthetic transient verdict.
  [[ -n "${_raw}" ]] || {
    printf '%s' "${_raw}"
    return 0
  }

  # Not a JSON object with a string .result => not an envelope. Treat the whole
  # thing as prose rather than dropping it on the floor.
  _result=$(printf '%s' "${_raw}" | jq -er 'if (.result | type) == "string" then .result else halt_error(3) end' 2>/dev/null) || {
    printf '%s\n' "${_raw}"
    return 0
  }

  if _blocking=$(extract_structured_blocking "${_raw}"); then
    # FIX_NOW findings ride their own sentinel: the renderer below drops them
    # from the prose so no gate or issue filer sees them.
    _fixnow=$(extract_fix_now "${_raw}")

    # Prefer the reviewer's own prose when it produced any. Under --json-schema
    # the model is constrained to a tool call and .result is the serialized
    # object, so there is normally none — but a response that DID carry prose
    # must keep it verbatim. The prose sub-languages the schema does not model
    # (NON_BLOCKING_ISSUE / TITLE / END_ISSUE blocks, consumed by
    # lib-review-issues.sh) live only there, and rendering over them would
    # silently drop pre-existing-defect filing.
    if [[ -n "${_result}" ]] && printf '%s\n' "${_result}" | grep -qiE '^[[:space:]]*[*`_]*VERDICT'; then
      _withfix=$(attach_fix_now "${_fixnow}" "${_result}")
      attach_structured_blocking "${_blocking}" "${_withfix}"
      return 0
    fi

    # Otherwise .result is the serialized object. Render the
    # VERDICT/ISSUE/SEVERITY/LOCATION/DETAILS block the rest of the pipeline
    # expects, straight from the structured findings.
    #
    # DETAILS now comes from the finding's own `details` field, falling back to
    # `issue` only when the reviewer omitted one. Phase 1 had no such field, so
    # DETAILS was a verbatim repeat of ISSUE on every finding - a measured,
    # user-visible regression against the prose contract, where DETAILS carried
    # the explanation and the fix.
    #
    # FIX_NOW findings are EXCLUDED here. They are not part of the
    # VERDICT/ISSUE/SEVERITY block a gate or an issue filer reads; they are
    # printed separately, at the commit stage only, by emit_fix_now_entries().
    # Rendering them into this block would feed them to has_blocking_severity()
    # and to lib-review-issues.sh, which is precisely what must not happen.
    _rendered=$(render_structured_prose "${_raw}")

    # Defensive: never hand downstream an empty body. A structured object that
    # renders to nothing still has to carry a parseable verdict.
    [[ -n "${_rendered}" ]] || {
      if [[ "${_blocking}" == "true" ]]; then
        _rendered="VERDICT: FAIL${_NL}ISSUE: reviewer reported a blocking issue with no renderable detail${_NL}SEVERITY: BLOCKING${_NL}LOCATION: unspecified${_NL}DETAILS: The structured response set blocking=true but carried no findings."
      else
        _rendered="VERDICT: PASS${_NL}No blocking issues found."
      fi
    }

    _withfix=$(attach_fix_now "${_fixnow}" "${_rendered}")
    attach_structured_blocking "${_blocking}" "${_withfix}"
  else
    # An envelope whose structured_output.blocking is absent, null, or the
    # wrong type. The reviewer did not answer the BOOLEAN — but it may still
    # have answered the VERDICT, and those are independent fields.
    #
    # This branch used to print `.result` alone. When the response ALSO carried
    # no `VERDICT:` line in its prose (under --json-schema the model is
    # constrained to a tool call, so `.result` is often narration or the
    # serialized object), that discarded a perfectly good
    # `.structured_output.verdict` and handed the gate bare prose. parse_verdict
    # then returned "" and the run hard-blocked a clean PASS, reporting it as
    # "prose carrying no recognizable VERDICT: line" — accurate about the value
    # it received, and wholly misleading about the review
    # (smartwatermelon/claude-config#450, the recurrence of #448).
    #
    # So: prepend a rendered VERDICT line when the structured verdict is
    # present and the prose does not already carry one. Deliberately NO
    # structured sentinel is attached — the reviewer did not supply the
    # boolean, so output_blocks() must still fall back to
    # has_blocking_severity() over the prose rather than silently passing.
    # That keeps the fail-closed direction intact while letting the verdict
    # through.
    local _sv
    _sv=$(printf '%s' "${_raw}" | jq -er '
      if (.structured_output.verdict | type) == "string"
      then (.structured_output.verdict | ascii_upcase)
      else halt_error(3) end' 2>/dev/null) || _sv=""
    case "${_sv}" in
      PASS | FAIL | REVISE) ;;
      *)
        # No usable verdict either. Hand back the prose unchanged; the gate's
        # unparseable path will block, which is correct — nothing here is a
        # reviewer answer.
        printf '%s\n' "${_result}"
        return 0
        ;;
    esac

    # The reviewer's prose keeps priority when it is REAL prose: the
    # sub-languages the schema does not model (NON_BLOCKING_ISSUE / TITLE /
    # END_ISSUE, consumed by lib-review-issues.sh) live ONLY there, and
    # rendering over them silently stops pre-existing-defect filing.
    #
    # The guard matches a NON_BLOCKING_ISSUE header as well as a VERDICT line.
    # Keying on VERDICT alone was not enough: a `.result` carrying only NBI
    # blocks has no VERDICT line, so it fell through to the renderer and the
    # blocks were destroyed — the exact content the guard exists to protect.
    if printf '%s\n' "${_result}" | grep -qiE '^[[:space:]]*[*`_]*(VERDICT|NON_BLOCKING_ISSUE)'; then
      # Fail-closed still has to hold on this path. Returning `.result` bare
      # discards .structured_output entirely — verdict, findings and all — so a
      # reviewer whose prose says nothing blocking, but whose structured
      # findings carry a BLOCKING severity, passed the gate. Attaching no
      # sentinel (correct: it never answered the boolean) means nothing rescues
      # it downstream either.
      #
      # So when the structured verdict is FAIL/REVISE and neither the prose nor
      # the structured findings put a matchable BLOCKING severity in front of
      # has_blocking_severity(), append one. The prose is preserved intact
      # above it, so the sub-languages survive and the human still sees the
      # reviewer's own words.
      # The test is against what actually gets EMITTED — `_result` — not against
      # `_result` plus a rendering that is then thrown away. Checking the
      # combined text was the first cut here and it left the hole open: the
      # structured findings supplied the BLOCKING line that satisfied the
      # check, while the value handed to the gate contained no such line.
      #
      # A structured BLOCKING finding that the prose does not mention is
      # therefore appended verbatim, which both closes the gap and tells the
      # human what the reviewer actually found.
      if [[ "${_sv}" != "PASS" ]] && ! has_blocking_severity "${_result}"; then
        _rendered=$(render_structured_prose "${_raw}")
        if has_blocking_severity "${_rendered}"; then
          # Carry the real findings across rather than a synthetic placeholder.
          # Drop the rendering's own VERDICT line: the prose already has one,
          # and a second would leave two verdicts in the output for
          # parse_verdict's PASS-anywhere-wins rule to pick between.
          #
          # NOTE: when the prose says PASS and the structured findings say
          # BLOCKING, parse_verdict reports PASS while output_blocks() blocks.
          # Severity deliberately wins over verdict — that is the fail-closed
          # direction — but the log will read as a passing review that blocked,
          # which is worth recognizing rather than debugging at 3am.
          _result="${_result}${_NL}${_NL}$(printf '%s\n' "${_rendered}" | grep -vE '^[[:space:]]*[*`_]*VERDICT' || true)"
        else
          _result="${_result}${_NL}${_NL}ISSUE: ${_sv} verdict with no blocking finding and no structured boolean${_NL}SEVERITY: BLOCKING${_NL}LOCATION: unspecified${_NL}DETAILS: Treated as blocking because the reviewer returned ${_sv} without the boolean that would let this be evaluated as non-blocking (claude-config#450)."
        fi
      fi
      # No VERDICT line at all (an NBI-only .result) still needs one, or the
      # gate reads the whole review as unparseable and hard-blocks — the very
      # failure #450 is about.
      if ! printf '%s\n' "${_result}" | grep -qiE '^[[:space:]]*[*`_]*VERDICT'; then
        _result="VERDICT: ${_sv}${_NL}${_result}"
      fi
      _fixnow=$(extract_fix_now "${_raw}")
      _withfix=$(attach_fix_now "${_fixnow}" "${_result}")
      printf '%s\n' "${_withfix}"
      return 0
    fi

    # Otherwise RENDER, rather than prepending a verdict line onto whatever
    # `.result` happens to hold.
    #
    # Prepending was the first attempt at this and it opened a hole. When
    # `.result` is the serialized object — the NORMAL shape under --json-schema,
    # per this function's own header — the prose handed downstream is JSON.
    # has_blocking_severity() matches `SEVERITY:[[:space:]]*BLOCKING`, and the
    # serialized form is `"severity":"BLOCKING"`, whose quote between the colon
    # and the keyword defeats that pattern. So a reviewer reporting
    # verdict=FAIL with a BLOCKING finding, slipping only on the boolean's
    # TYPE, produced a verdict of FAIL that no gate would act on: exit 0 where
    # the pre-#450 code exited 1. Trading a noisy false block for a silent
    # false pass is the one direction a gate must never move.
    #
    # Rendering emits real `SEVERITY: BLOCKING` lines, so the stated
    # fail-closed fallback actually has prose it can read.
    _rendered=$(render_structured_prose "${_raw}")

    # Belt-and-braces for a FAIL/REVISE that renders no findings at all: the
    # verdict says something is wrong and there is no severity line to prove
    # it, so synthesize one rather than emitting a verdict no gate can act on.
    if [[ -z "${_rendered}" ]]; then
      if [[ "${_sv}" == "PASS" ]]; then
        _rendered="VERDICT: PASS${_NL}No blocking issues found."
      else
        _rendered="VERDICT: ${_sv}${_NL}ISSUE: reviewer returned ${_sv} with no renderable detail${_NL}SEVERITY: BLOCKING${_NL}LOCATION: unspecified${_NL}DETAILS: The structured response set verdict=${_sv} but supplied no usable blocking boolean and no findings."
      fi
    fi

    # Keep the reviewer's own words when `findings[]` was empty but `.result`
    # carried real finding prose (an ISSUE:/SEVERITY:/LOCATION: block with no
    # leading VERDICT line, which is why it reached the renderer rather than
    # the prose-priority path above). Rendering alone would emit a verdict and
    # a synthetic reason while `foo.sh:2` and "breaks under set -e" vanished —
    # a hard block with its diagnostic content stripped, which is the worst
    # kind to receive. Appending costs a duplicate verdict line at worst;
    # parse_verdict reads the first, and PASS-anywhere-wins cannot fire here
    # because the appended text has no VERDICT line of its own.
    if [[ -n "${_result//[[:space:]]/}" ]] \
      && printf '%s\n' "${_result}" | grep -qiE '^[[:space:]]*[*`_]*(ISSUE|SEVERITY|LOCATION|DETAILS)'; then
      _rendered="${_rendered}${_NL}${_result}"
    fi

    # A rendered FAIL/REVISE carrying no BLOCKING severity would reach
    # output_blocks() and pass, because the reviewer never answered the
    # boolean and the prose gives the fallback nothing to match. The reviewer
    # said the diff is not acceptable; honor that rather than downgrading it
    # to a warning on the strength of a field it failed to fill in.
    if [[ "${_sv}" != "PASS" ]] && ! has_blocking_severity "${_rendered}"; then
      _rendered="${_rendered}${_NL}ISSUE: ${_sv} verdict with no blocking finding and no structured boolean${_NL}SEVERITY: BLOCKING${_NL}LOCATION: unspecified${_NL}DETAILS: Treated as blocking because the reviewer returned ${_sv} without the boolean that would let this be evaluated as non-blocking (claude-config#450)."
    fi

    # Still NO structured sentinel: the reviewer did not answer the boolean, so
    # output_blocks() must decide from the rendered prose above rather than
    # from a decision channel nobody filled in.
    _fixnow=$(extract_fix_now "${_raw}")
    _withfix=$(attach_fix_now "${_fixnow}" "${_rendered}")
    printf '%s\n' "${_withfix}"
  fi
}

# --- Shared anti-noise prompt language (claude-config#443 phase 2, item 4) ---
#
# The DO-NOT-FILE list, the concede-check, and the Kind A / Kind B split lived
# ONLY in the codebase and CI prompts. The commit, full-diff, chunked, and
# arbiter prompts were ~20 lines each with no severity calibration and no
# anti-nitpick guidance. Measured: 63% of filed issue bodies are phrased
# "Consider..." / "Worth..." / "Suggest..." - a suggestion, not a defect - and
# only 12.5% of a classified sample were real correctness or security findings.
#
# This is ONE variable that every prompt now includes, so the calibration
# cannot drift back apart across five copies.
#
# IT IS NOT REDUNDANT UNDER THE SCHEMA. Measured after #444: on a context-free
# stub the adversarial reviewer set blocking=true. The schema guarantees the
# boolean is WELL-FORMED; it does not make it CORRECT. This language is what
# calibrates the value the model puts in that field, which is why every prompt
# states explicitly when to set blocking=true.
REVIEW_SEVERITY_RULES='SEVERITY — set this deliberately. Two INDEPENDENT questions.

1. IS IT A DEFECT — would a maintainer change code because of it?
   Something is a defect when it produces a wrong result, a crash, a security
   hole, data loss, a silently skipped check, or a documented behavior the code
   does not deliver. Answering "no" here is the COMMON case, and it is a
   complete answer. Say nothing further about it.

2. WHEN did it originate — INTRODUCED by this diff, or PRE-EXISTING?

Then pick exactly one tier:

- BLOCKING: a DEFECT that is INTRODUCED by this diff. Set blocking=true ONLY
  for this tier. If nothing meets this bar, blocking is FALSE — that is the
  expected outcome for a clean diff, not a lazy one.
- FIX_NOW: a small, mechanical, concrete edit worth making right now, in this
  round. Printed to the author and NOTHING else — it never blocks and is never
  filed. Rules below.
- WARNING: a real defect that is neither of the above.
- Everything else: NOT REPORTED AT ALL. There is no third channel — no FYI, no
  note for the next reader, no "worth verifying", no "consider".

FIX_NOW — the tier is defined by these cases, not by a general invitation to
comment on code quality:
  - a comment that only restates what its line already says
  - an unused import or a dead local
  - a missing quote on a variable expansion
  - a leaked temp file with no trap
Rules, all mandatory:
  - ONE LINE: put "file:line" in location and "what to change" in issue. Under
    15 words. No rationale, no details field, no explanation.
  - It must name a CONCRETE EDIT. If you cannot express it as a specific change
    to a specific line, it is NOT FIX_NOW and you must not report it at all.
  - The words "consider", "worth noting", "may want to", and "for the next
    person" are BANNED in this tier. That phrasing is the tell that you already
    decided it is not a defect.
  - At most 5. Beyond that only a count is shown, so send the 5 best.

DO NOT REPORT (this list is where most bad findings come from):
- Anything you would introduce with "worth noting", "worth verifying",
  "consider", "may want to", "for the next person", or "no code change
  required". If that phrasing fits, you have already decided it is not a
  defect. Stop.
- Style, naming, formatting, comment wording, or test-coverage suggestions for
  code that behaves correctly.
- A gap that the comments in the file already document as known and accepted.
- Code that works but that you would have written differently.
- A concern you reasoned about and resolved. If your own analysis ends in "this
  is fine" or "no defect", the finding is finished and unreported. Do not
  report the reasoning.
- Platform or runtime behavior you cannot check and have no specific reason to
  doubt.

BEFORE EMITTING EACH FINDING, CHECK YOURSELF:
Does your explanation end by conceding the thing is fine? If so, delete the
whole finding. Measured over 876 auto-filed issues from this reviewer, roughly
one in seven stated in its own body that nothing was wrong — every one cost a
human a read and a manual close. Reporting nothing is a good outcome and the
expected one for a clean diff.

VERIFIABLE CLAIMS (mandatory). Every factual claim splits into two kinds, and
they have DIFFERENT rules.

KIND A — claims about repository contents: what a file contains, whether a
symbol is defined, whether a name is referenced elsewhere, what a config value
is. If you have tools, open the file or run the search before asserting it, and
say what you looked at. If you have no tools, you cannot make a Kind A claim
about anything outside the diff you were given.

KIND B — claims about how a tool, shell construct, or runtime BEHAVES:
"printf appends another newline here", "command substitution keeps the
trailing newline",
"grep -w splits on /", "this flag does not exist". You CANNOT check these.
Reading the code that calls a tool tells you what the code does, never what the
tool does with it.

FOR EVERY KIND B CLAIM THE SOFTENED FORM IS MANDATORY, NOT A FALLBACK. Phrase
it as a question and say what would settle it. Write:
  "does printf re-add a trailing newline here — worth checking whether the
   command substitution already stripped it?"
NOT:
  "printf appends another newline, producing a blank line between blocks."
A Kind B claim stated as fact is wrong even when the underlying suspicion is
right, because you are reporting a guess as a measurement — and a human then
spends a command disproving it. Confidence does not rescue it. No exceptions.

KIND B ALSO COVERS what a hosted service, platform, or third-party API
supports, documents, or does with a value: "Netlify does not substitute this
variable", "GitHub Actions expressions are case-sensitive here", "this API
ignores that field". You have no network access and cannot read their
documentation, so your memory of it is a guess too.

A KIND B FINDING IS NEVER BLOCKING. Its severity is WARNING at most, however
sure you are. When the developer intent cites documentation or a test result
for the behavior, do not report the opposite claim at all.

If you have no tools, LOCATION must name a file that appears in the diff you
were shown. A finding about a file you were not shown is a guess about its
contents.'

# --- Version-pin-unfamiliarity downgrade ---
# Rationale and rules: docs/CODE-REVIEW.md
# §Version-Pin Unfamiliarity Is Not a Blocking Finding
#
# Reviewer models' training data has a cutoff; a manifest pin for a tool
# version newer than that cutoff reads to the reviewer as "this version
# doesn't exist" or "I don't recognize this" — a false BLOCKING FAIL on
# code that was tested and pinned deliberately. Treat that specific
# objection as invalid and downgrade it to WARNING, without per-ecosystem
# manifest parsing and without a separate test-evidence check (tests-passed
# is already assumed by Protocol 3 by the time a diff reaches review).
#
# What this function does NOT do, deliberately (YAGNI):
#   - It does not verify the pin against a package registry.
#   - It does not distinguish package.json from go.mod from Gemfile, etc.
#   - It does not trust the reviewer's own "I don't recognize this" claim
#     at face value — it re-classifies the DETAILS/ISSUE text itself, so
#     a reviewer that mislabels a real CVE finding as "unfamiliar" still
#     gets caught by the known-bad pattern below.
#
# $1 = raw reviewer output (VERDICT/ISSUE/SEVERITY/LOCATION/DETAILS blocks)
# Prints the same text with qualifying BLOCKING lines rewritten to WARNING.
# If that leaves no BLOCKING severity anywhere, the leading VERDICT: FAIL /
# REVISE is rewritten to PASS as well — parse_verdict reads only the VERDICT
# line, so without this the downgrade would relabel the issue while still
# blocking the commit, which is the opposite of the intent.
# Emits one log_warn per downgrade (stderr) so it stays visible, matching
# how arbitration disagreements are logged elsewhere in this file.
downgrade_version_unfamiliarity_findings() {
  local _output="$1"
  local -a _out_lines=()
  local -a _block=()
  local _line _block_text _is_blocking _tool_hint _result
  local _tool_version _issue_title
  local _downgraded="no"

  # Language that indicates the reviewer's sole objection is "I don't
  # recognize this version" (unfamiliarity), as opposed to a substantive
  # claim about the version being bad. Case-insensitive.
  local _unfamiliar_re='does not exist|doesn.?t exist|no such version|not aware of|unfamiliar|do not recognize|don.?t recognize|unrecognized version|not a (real|valid|known) version|nonexistent version'

  # Language that indicates a substantive, non-familiarity objection.
  # If this matches anywhere in the block, the block is NEVER downgraded,
  # even if unfamiliarity language also appears — a known-bad claim wins.
  # The dot in `supply.chain` is an intentional wildcard, not an unescaped
  # literal: it covers "supply chain", "supply-chain", and "supply_chain".
  # Do not "correct" it to `supply\.chain`.
  local _knownbad_re='CVE-|CVE[[:space:]]|vulnerab|RCE|exploit|deprecat|yanked|breaking change|incompatib|security advisory|malicious|supply.chain'

  # Walk the output one ISSUE:-delimited block at a time. Each block runs
  # from an "ISSUE:" line up to (but not including) the next "ISSUE:" line
  # or end of input. Blocks are classified as a whole so DETAILS: text on
  # a later line still counts toward the block that owns it.
  _flush_block() {
    if [[ ${#_block[@]} -eq 0 ]]; then
      return 0
    fi
    _block_text=$(printf '%s\n' "${_block[@]}")
    _is_blocking=$(printf '%s\n' "${_block_text}" | grep -qiE 'SEVERITY:[[:space:]]*BLOCKING' && echo yes || echo no)
    if [[ "${_is_blocking}" == "yes" ]] \
      && printf '%s\n' "${_block_text}" | grep -qiE "${_unfamiliar_re}" \
      && ! printf '%s\n' "${_block_text}" | grep -qiE "${_knownbad_re}"; then
      # Best-effort local corroboration: if a tool name is present and
      # invokable, log its installed version alongside the downgrade for
      # a human to sanity-check later. Not required to downgrade — an
      # absent local binary (an npm/pip package, say) is not a blocker.
      # grep -E has no lookahead, so match "<name> <version>" whole and strip
      # the version half with sed rather than trying to assert past it.
      _tool_hint=$(printf '%s\n' "${_block_text}" \
        | grep -oE '[a-zA-Z][a-zA-Z0-9_.-]{1,30}[[:space:]]+v?[0-9]+\.[0-9]' \
        | head -1 \
        | sed -E 's/[[:space:]]+v?[0-9]+\.[0-9].*$//' || true)
      if [[ -n "${_tool_hint}" ]] && command -v "${_tool_hint}" >/dev/null 2>&1; then
        _tool_version=$("${_tool_hint}" --version 2>/dev/null || true)
        _tool_version=$(printf '%s\n' "${_tool_version}" | head -1)
        [[ -n "${_tool_version}" ]] || _tool_version="unknown"
        log_warn "version-pin downgrade: local '${_tool_hint} --version' -> ${_tool_version}"
      fi
      _issue_title=$(printf '%s\n' "${_block_text}" | grep -im1 '^ISSUE:' || true)
      [[ -n "${_issue_title}" ]] || _issue_title="(untitled issue)"
      log_warn "Downgrading BLOCKING -> WARNING (version-pin unfamiliarity, not a known-bad claim): ${_issue_title}"
      _downgraded="yes"
      _block_text=$(printf '%s\n' "${_block_text}" | sed -E 's/^(SEVERITY:[[:space:]]*)BLOCKING/\1WARNING/I')
    fi
    _out_lines+=("${_block_text}")
    _block=()
  }

  # A new block starts at an ISSUE: line once markdown emphasis and any
  # bullet, number, or heading marker are stripped ("1. ISSUE:", "- **ISSUE:**").
  # Missing one merges two findings, and one match then downgrades both.
  local _norm _issue_split_re='^[^A-Za-z]*ISSUE:'
  while IFS= read -r _line; do
    _norm="${_line//[*\`_]/}"
    if [[ "${_norm}" =~ ${_issue_split_re} ]]; then
      _flush_block
    fi
    _block+=("${_line}")
  done <<<"${_output}"
  _flush_block

  unset -f _flush_block

  if [[ ${#_out_lines[@]} -eq 0 ]]; then
    return 0
  fi

  _result=$(printf '%s\n' "${_out_lines[@]}")

  # Only promote the verdict when a downgrade actually happened AND nothing
  # blocking survives. A reviewer that raised an unrelated BLOCKING issue
  # alongside the version pin still fails, as it should. has_blocking_severity()
  # strips markdown, so a "**SEVERITY:** BLOCKING" survivor still counts.
  if [[ "${_downgraded}" == "yes" ]] && ! has_blocking_severity "${_result}"; then
    log_warn "All BLOCKING findings were version-pin unfamiliarity; promoting VERDICT to PASS"
    # awk, not `sed '1,/^VERDICT:/'`: that range ends at the SECOND match, so
    # it would rewrite a trailing VERDICT line too, and BSD sed ignores the
    # `0,/re/` form that would otherwise fix it. Rewrite the first line only.
    _result=$(printf '%s\n' "${_result}" | awk '
      BEGIN { done = 0 }
      !done && toupper($0) ~ /^VERDICT:[[:space:]]*(FAIL|REVISE)/ {
        # Rebuild rather than sub(): awk sub() is case-sensitive, so any
        # casing the toupper() guard admits ("verdict: revise", "fAiL")
        # would survive a substitution unchanged. parse_verdict is
        # case-insensitive, so that would still block the commit. Split on
        # the uppercased copy and keep the original tail verbatim.
        rest = $0
        sub(/^[^:]*:[[:space:]]*/, "", rest)
        upper = toupper(rest)
        keep = (upper ~ /^REVISE/) ? substr(rest, 7) : substr(rest, 5)
        print "VERDICT: PASS" keep
        done = 1
        next
      }
      { print }
    ')
    # This function deliberately overrides the reviewer's own judgment on a
    # known false-positive class. A structured `blocking=true` sentinel must
    # not survive that override and re-block via output_blocks() — it is the
    # very claim just determined to be invalid. Dropping the sentinel returns
    # the decision to the rewritten prose, which now reads WARNING/PASS.
    # Only done when a downgrade actually fired and nothing blocking survived.
    #
    # Belt-and-braces: the promotion above already rewrote VERDICT to PASS, and
    # every severity gate is guarded by VERDICT == FAIL/REVISE, so a promoted
    # output never reaches output_blocks() in the first place.
    #
    # Inlined rather than calling strip_structured_blocking(): this function is
    # sourced by tests/test_version_pin_downgrade.bats, which extracts it with
    # sed along with has_blocking_severity() only. Add any other helper call
    # to that test's setup() too. `|| true` guards grep's exit 1 on an
    # all-lines-match (impossible here, but set -e is on).
    _result=$(printf '%s\n' "${_result}" | grep -vE "^${STRUCTURED_MARKER:-__REVIEW_BLOCKING__} " || true)
  fi

  printf '%s\n' "${_result}"
}

# --- Paths a diff touches ---
# Prints one path per line for every file the unified diff $1 names, read from
# its own headers rather than from `git diff --name-only`. Full-diff mode gets
# its diff on stdin with no staged index to ask, so the headers are the only
# source that describes exactly what the reviewer was shown.
#
# Prefix-agnostic on purpose. `diff.mnemonicPrefix` (set on Andrew's machines)
# writes `c/`, `i/`, `w/` instead of `a/`, `b/`, and `diff.noprefix` writes
# none, so each header path is printed both as-is and with a one-letter prefix
# removed. An extra entry only makes the location check below more permissive,
# which is the safe direction for a check that can only downgrade.
#
# git quotes a path holding non-ASCII or control characters ("caf\303\251.sh"
# under the default core.quotePath). The quotes are stripped and the escapes
# decoded, so the location check compares the name the reviewer actually saw.
diff_changed_paths() {
  local _p
  printf '%s\n' "$1" | awk '
    function emit(p) {
      if (p ~ /^".*"$/) { p = substr(p, 2, length(p) - 2); q = 1 } else { q = 0 }
      if (p == "/dev/null" || p == "") return
      print (q ? "Q" : "P") p
      if (p ~ /^[a-z]\//) print (q ? "Q" : "P") substr(p, 3)
    }
    /^(\+\+\+|---) / {
      p = substr($0, 5)
      sub(/\t.*$/, "", p)
      emit(p)
      next
    }
    /^rename (from|to) / {
      p = $0
      sub(/^rename (from|to) /, "", p)
      emit(p)
    }' | while IFS= read -r _p; do
    if [[ "${_p}" == Q* ]]; then
      printf '%b\n' "${_p#Q}"
    else
      printf '%s\n' "${_p#P}"
    fi
  done | sort -u
}

# --- Unverifiable-claim downgrade (claude-config#455, #555, #488) ---
#
# Reviewers here run with `--tools ""`: no network, no filesystem. Two kinds
# of BLOCKING finding are therefore claims the reviewer had no way to check,
# and both have blocked correct commits:
#
#   1. EXTERNAL BEHAVIOR (#455, #555). "Netlify does not support %{...}
#      syntax", "BSD sed does not support [[:space:]]". The prompt's Kind B
#      rule already says such a claim must be phrased as a question; nothing
#      enforced it, so a flat false assertion still blocked. #455 reproduced
#      3 of 3 times on Haiku against a documented Netlify variable, once with
#      the arbiter upholding it.
#   2. A LOCATION OUTSIDE THE DIFF (#488). A finding against `tally.sh` when
#      the diff touched one `.disabled` file. The reviewer was shown only the
#      diff, so a finding that names no file in it is misattributed or
#      invented. It could not have read the file it cites.
#
# Both are rewritten BLOCKING -> WARNING, so the human still sees them. The
# verdict is promoted and the structured sentinel dropped only when nothing
# blocking survives, exactly as downgrade_version_unfamiliarity_findings does.
#
# This function weakens a gate, so every rule below errs toward blocking. A
# false block costs a human one command; a false pass ships the defect.
#
#   - SECURITY EXEMPTION, both kinds (_security_re). A finding that names a
#     credential, token, auth, logging, injection, or data-loss class is never
#     downgraded. That keeps #488's literal instance (a leaked token in a file
#     that never existed) blocking: the arbiter stays its backstop, because a
#     reviewer must not be able to launder a credential finding into a warning
#     by misplacing it or by calling it unsupported.
#   - Kind 1 needs a named third-party platform as the grammatical subject of
#     the negation ("Netlify Forms does not support ... syntax"). "the new
#     parser does not support that flag" names nothing external and blocks.
#   - Kind 2 downgrades only when LOCATION holds a file-shaped path (a name
#     with an extension) and nothing uncertain: no glob, no directory, no
#     extensionless path, no git-quoted changed path it cannot compare. It
#     never fires when the finding mentions any changed file or its basename
#     anywhere, or reads as a missed edit ("settings.json has no entry for the
#     new hook"): a file the change should have touched is not in the diff by
#     definition.
#   - A block with more than one SEVERITY line is never downgraded: it is two
#     findings the split below failed to separate.
#   - Markdown-bolded severities are not recognized for downgrade, so they
#     stay blocking, and the survivor check uses has_blocking_severity(),
#     which strips markdown, so a bolded BLOCKING keeps the verdict at FAIL.
#
# $1 = reviewer output (VERDICT/ISSUE/SEVERITY/LOCATION/DETAILS blocks)
# $2 = newline-separated paths the reviewed diff touches (may be empty, which
#      disables the location check rather than downgrading everything)
#
# Depends on has_blocking_severity() and log_warn() only.
# tests/test_unverifiable_claim_downgrade.bats extracts those with sed.
downgrade_unverifiable_findings() {
  local _output="$1"
  local _changed="$2"
  local -a _out_lines=()
  local -a _block=()
  local -a _toks=()
  local _line _norm _block_text _prose _issue_title _reason _loc _loc_words _tok _path _f _base
  local _related _uncertain _pathlike _sev_count
  local _result
  local _downgraded="no"

  # A new finding starts at an ISSUE: line, after markdown emphasis is
  # stripped and any bullet, number, or heading marker before it: "1. ISSUE:",
  # "- **ISSUE:**", "### ISSUE:". Missing one merges two findings, and one
  # match would then downgrade both.
  local _issue_split_re='^[^A-Za-z]*ISSUE:'

  # Credential, auth, logging, injection, and data-loss classes. A finding
  # that names any of them is never downgraded, by either kind. Short words
  # are bounded so they do not match inside ordinary ones: "rce" in
  # "percent", "log" in "logic" or "catalog", "auth" in "author". Bare
  # "inject" is left out: a measured #455 finding suggested "a serverless
  # function to inject the ID" and another called a variable "injectable".
  local _security_re='hard-?coded|leak|secret|credential|passw|api[ _-]?key|bearer|unmask|plain ?text|expos(e|ed|es|ing|ure)([^a-z]|$)|(^|[^a-z])tokens?([^a-z]|$)|(^|[^a-z])o?auth(n|z|entic[a-z]*|oriz[a-z]*)?([^a-z]|$)|(^|[^a-z])(log|logs|logged|logging)([^a-z]|$)|inject(ion|ed)|(^|[^a-z])eval([^a-z]|$)|rm -rf|CVE-|vulnerab|exploit|(^|[^a-z])rce([^a-z]|$)|privilege|traversal|XSS|CSRF|SSRF|data loss|sanitiz|escap(e|ing)'

  # Kind 1. A named third-party platform, then (within the same clause, only
  # letters, spaces, and apostrophes between) a negative claim about what it
  # supports or documents. Every live #455 finding and the #555-class BSD sed
  # finding match; an in-diff defect worded "the parser does not support that
  # flag" does not, because nothing external is its subject.
  local _neg='(does ?n.?o?t|do ?n.?o?t|did ?n.?o?t)'
  local _vendor='(netlify|vercel|cloudflare|heroku|github actions|actions expressions?|workflow expressions?|(^|[^a-z])(aws|gcp|azure)|google cloud|docker hub|npm registry|pypi|homebrew|bsd|gnu|macos|busybox)'
  local _claim="${_neg} (support|accept|allow|recogni[sz]e|expand|substitute|interpolate)[^.]{0,60}(syntax|placeholder|variable|substitution|interpolat|templat|flag|option|expression|bracket|construct|keyword|quantifier)|${_neg} (document|have (a |any )?(built-in |native )?[a-z ]{0,30}(substitution|templat|interpolat))|(has|have) no documented"
  local _external_re="${_vendor}[a-z' ]{0,25}(${_claim})"

  # A finding that says the change should have edited a file it did not.
  # Such a file is outside the diff by definition, so its LOCATION proves
  # nothing about fabrication.
  local _omission_re='should (also )?(have )?(be(en)? )?(update|edit|change|add|regist|includ|modif|mention|document)|(also|must|needs?( to)?|has to|have to) (be )?(update|edit|change|add|regist|includ|modif)|not (been )?(updated|registered|added|wired|edited|changed|included|referenced|invoked|called|sourced|imported)|never (updated|registered|added|invoked|called|runs|run|referenced|sourced|imported)|no (entry|reference|registration|mention)|nothing (invokes|calls|references|registers|sources|imports)|missing|forgot|omit|out of (sync|date)|stale|unregistered|orphan'

  _flush_block() {
    if [[ ${#_block[@]} -eq 0 ]]; then
      return 0
    fi
    _block_text=$(printf '%s\n' "${_block[@]}")
    _reason=""
    # Only a plain, line-anchored SEVERITY: BLOCKING is eligible. Anything
    # else (bolded, bulleted, indented) is left alone and still blocks.
    _sev_count=$(printf '%s\n' "${_block_text}" | tr -d '*`_' | grep -ciE 'SEVERITY:' || true)
    if [[ "${_sev_count}" == "1" ]] \
      && printf '%s\n' "${_block_text}" | grep -qiE '^SEVERITY:[[:space:]]*BLOCKING' \
      && ! printf '%s\n' "${_block_text}" | grep -qiE "${_security_re}"; then
      # Dots inside a token (`%{...}`, a file name) are not sentence ends.
      _prose=$(printf '%s\n' "${_block_text}" | sed -E 's/\.([^[:space:]])/_\1/g')
      # Kind 1: external-behavior claim.
      if printf '%s\n' "${_prose}" | grep -qiE "${_external_re}"; then
        _reason="claim about external tool/service behavior the reviewer cannot check (#455/#555)"
      fi
      # Kind 2: LOCATION names no file in the diff.
      if [[ -z "${_reason}" && -n "${_changed//[[:space:]]/}" ]] \
        && ! printf '%s\n' "${_block_text}" | grep -qiE "${_omission_re}"; then
        _loc=$(printf '%s\n' "${_block_text}" | grep -im1 '^LOCATION:' | sed -E 's/^LOCATION:[[:space:]]*//I' || true)
        _loc="${_loc//\\//}"
        _related=0
        _uncertain=0
        _pathlike=0
        # Any changed path, or its basename, anywhere in the finding ties it
        # to the diff. Whole-string containment, so a name with a space or
        # non-ASCII characters, a #L anchor, or a :line tail cannot defeat it.
        while IFS= read -r _f; do
          [[ -n "${_f}" ]] || continue
          # A git-quoted path ("caf\303\251.sh") cannot be compared reliably.
          if [[ "${_f}" == \"* || "${_f}" == *\\* ]]; then
            _uncertain=1
            break
          fi
          _base="${_f##*/}"
          if [[ "${_block_text//\\//}" == *"${_f}"* || "${_block_text}" == *"${_base}"* ]]; then
            _related=1
            break
          fi
        done <<<"${_changed}"
        # A glob or brace pattern could name a changed file.
        if [[ "${_loc}" == *[\*\?\[\{]* ]]; then
          _uncertain=1
        fi
        if [[ ${_related} -eq 0 && ${_uncertain} -eq 0 ]]; then
          # Split on whitespace, commas, "+", and strip quoting. read -a, not
          # an unquoted $(...), so a LOCATION token can never glob.
          _loc_words=$(printf '%s\n' "${_loc}" | sed -E 's/[`"(),+;]/ /g') || _loc_words=""
          read -r -a _toks <<<"${_loc_words}"
          for _tok in "${_toks[@]}"; do
            _path="${_tok%%#*}"
            _path="${_path%%:*}"
            _path="${_path#./}"
            [[ -n "${_path}" ]] || continue
            # A directory, or a path with no extension that could be one.
            if [[ "${_path}" == */ ]] \
              || { [[ "${_path}" == */* ]] && ! [[ "${_path##*/}" =~ \.[A-Za-z0-9_-]+$ ]]; }; then
              _uncertain=1
              break
            fi
            # File-shaped: a basename with an extension. "N/A", "line", "e.g"
            # are not.
            if [[ "${_path##*/}" =~ [^.]\.[A-Za-z0-9_-]+$ ]]; then
              _pathlike=1
            fi
          done
        fi
        if [[ ${_pathlike} -eq 1 && ${_related} -eq 0 && ${_uncertain} -eq 0 ]]; then
          _reason="LOCATION names no file in the reviewed diff (#488): ${_loc}"
        fi
      fi
    fi
    if [[ -n "${_reason}" ]]; then
      _issue_title="${_block[0]}"
      [[ -n "${_issue_title}" ]] || _issue_title="(untitled issue)"
      log_warn "Downgrading BLOCKING -> WARNING (${_reason}): ${_issue_title}"
      # Recorded in the per-repo log so the rate is measurable (#488).
      printf 'downgraded: %s: %s\n' "${_reason}" "${_issue_title}" >>"${REVIEW_LOG:-/dev/null}" 2>/dev/null || true
      _downgraded="yes"
      _block_text=$(printf '%s\n' "${_block_text}" | sed -E 's/^(SEVERITY:[[:space:]]*)BLOCKING/\1WARNING/I')
    fi
    _out_lines+=("${_block_text}")
    _block=()
  }

  while IFS= read -r _line; do
    _norm="${_line//[*\`_]/}"
    if [[ "${_norm}" =~ ${_issue_split_re} ]]; then
      _flush_block
    fi
    _block+=("${_line}")
  done <<<"${_output}"
  _flush_block

  unset -f _flush_block

  if [[ ${#_out_lines[@]} -eq 0 ]]; then
    return 0
  fi

  _result=$(printf '%s\n' "${_out_lines[@]}")

  # Same promotion rule as the version-pin sibling: only when a downgrade
  # fired AND nothing blocking survives. has_blocking_severity() strips
  # markdown, so "**SEVERITY:** BLOCKING" counts as a survivor. The awk
  # rewrites the FIRST verdict line only, case-insensitively; see the sibling
  # for why not sed or sub().
  if [[ "${_downgraded}" == "yes" ]] && ! has_blocking_severity "${_result}"; then
    log_warn "All BLOCKING findings were unverifiable claims; promoting VERDICT to PASS"
    _result=$(printf '%s\n' "${_result}" | awk '
      BEGIN { done = 0 }
      !done && toupper($0) ~ /^VERDICT:[[:space:]]*(FAIL|REVISE)/ {
        rest = $0
        sub(/^[^:]*:[[:space:]]*/, "", rest)
        upper = toupper(rest)
        keep = (upper ~ /^REVISE/) ? substr(rest, 7) : substr(rest, 5)
        print "VERDICT: PASS" keep
        done = 1
        next
      }
      { print }
    ')
    # The structured blocking=true sentinel is the very claim just ruled
    # unverifiable; left in place, output_blocks() would still block on it.
    _result=$(printf '%s\n' "${_result}" | grep -vE "^${STRUCTURED_MARKER:-__REVIEW_BLOCKING__} " || true)
  fi

  printf '%s\n' "${_result}"
}

# --- Shared issue library (for --mode=codebase non-blocking issues) ---
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The source-path/source directives below resolve both libs locally, where the
# siblings sit next to this script. They do NOT resolve under the CI checkout
# layout (standards-check checks out the repo into a ./repo subdirectory), so
# `shellcheck -S info` there reports SC1091 and fails the job. Both files are
# real, tracked siblings and are verified by hooks/tests/run-review-test.sh, so
# the finding is a static-resolution artifact, not a defect.
#
# Disables are a last resort in this repo (see CLAUDE.md). Used here because the
# directives that should have fixed it already exist and are insufficient, and
# the alternatives are worse: `shellcheck -x` lives in the shared
# smartwatermelon/github-workflows reusable workflow and would change behavior
# for every consuming repo, and rewriting the source paths would alter a
# load-bearing hook to satisfy a linter.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-review-issues.sh
# shellcheck disable=SC1091  # sibling lib; unresolvable under CI checkout layout
source "${_LIB_DIR}/lib-review-issues.sh"

# --- Shared context-assembly library (file-header extraction, round memory) ---
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-review-context.sh
# shellcheck disable=SC1091  # sibling lib; unresolvable under CI checkout layout
source "${_LIB_DIR}/lib-review-context.sh"

# Resolve repo metadata for issue creation (best-effort)
if [[ -z "${REPO_OWNER:-}" ]]; then
  _remote_url=$(git remote get-url origin 2>/dev/null || echo "")
  if [[ "${_remote_url}" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
    export REPO_OWNER="${BASH_REMATCH[1]}"
    export REPO_NAME="${BASH_REMATCH[2]}"
  fi
fi

# --- Preflight ---
if [[ ! -x "${CLAUDE_CLI}" ]]; then
  log_error "Claude CLI not found at: ${CLAUDE_CLI}"
  log_error "Set CLAUDE_CLI env var to override location"
  exit 1
fi

# Responsiveness check: if the CLI is hung, each agent invocation below
# burns TIMEOUT_SECONDS (120-300s) before failing. A --version call should
# return within a few seconds; if `timeout` has to kill it (exit 124), the
# CLI is hung — fail fast so the caller can diagnose instead of waiting
# through multiple long timeouts.
#
# Note: we ONLY fail on exit 124 (timeout). A CLI that responds with any
# other nonzero status (broken install, auth expired, etc.) is still
# responsive — let the real invocation surface the actionable error. Mock
# CLIs in the test suite exit with configured codes; those must not trip
# this preflight. See hooks/tests/run-review-test.sh.
_preflight_rc=0
# Redirect stdin from /dev/null: the review diff arrives on this script's stdin
# (DIFF=$(cat) below), and a CLI/wrapper that reads stdin on --version would
# otherwise drain it, leaving DIFF empty ("No staged changes to review").
timeout 5 "${CLAUDE_CLI}" --version </dev/null >/dev/null 2>&1 || _preflight_rc=$?
if [[ ${_preflight_rc} -eq 124 ]]; then
  log_error "Claude CLI did not respond to --version within 5s: ${CLAUDE_CLI}"
  log_error "CLI may be hung. Diagnose:"
  log_error "  timeout 5 ${CLAUDE_CLI} --version"
  exit 1
fi
unset _preflight_rc

# --- Agent invocation function ---
# $1 = agent name, $2 = prompt, $3 = cache file, $4... = model args array
# (e.g. "${CODE_REVIEWER_MODEL_ARGS[@]}" or "${ADVERSARIAL_MODEL_ARGS[@]}",
# possibly empty). Per-call model args replace the old shared global
# MODEL_ARGS so each reviewer can be pinned to its own model (issue #235).
# Slow-response notice (#590). _slow_notice_start forks one sleeper that, if
# it is still alive after SLOW_NOTICE_SECONDS, prints ONE line to stderr;
# _slow_notice_stop kills it and waits for it. The sleeper blocks in `wait`
# on its own `sleep`, so it burns no CPU, and its TERM trap kills that sleep
# at once, so nothing is left holding stderr open after the reviewer returns.
# Its stdout is /dev/null: a sleeper that inherited a $(...) capture pipe
# would make the caller wait out the whole threshold. It also checks that
# the shell that started it is still alive before printing, so a reviewer
# shell that died without reaching _slow_notice_stop never gets a stray line.
# Not `local`: set in the caller's shell, read by _slow_notice_stop.
_SLOW_NOTICE_PID=""
_slow_notice_start() {
  local agent_name="$1"
  _SLOW_NOTICE_PID=""
  [[ "${SLOW_NOTICE_SECONDS}" =~ ^[0-9]+$ ]] || return 0
  ((SLOW_NOTICE_SECONDS > 0 && SLOW_NOTICE_SECONDS < TIMEOUT_SECONDS)) || return 0
  local _owner="${BASHPID}"
  (
    _sleep_pid=""
    trap 'kill "${_sleep_pid}" 2>/dev/null; exit 0' TERM
    sleep "${SLOW_NOTICE_SECONDS}" 2>/dev/null &
    _sleep_pid=$!
    wait "${_sleep_pid}" || exit 0
    kill -0 "${_owner}" 2>/dev/null || exit 0
    printf '[review] %s has not responded after %ss — still waiting (timeout at %ss)\n' \
      "${agent_name}" "${SLOW_NOTICE_SECONDS}" "${TIMEOUT_SECONDS}" >&2
  ) </dev/null >/dev/null &
  _SLOW_NOTICE_PID=$!
}

_slow_notice_stop() {
  [[ -n "${_SLOW_NOTICE_PID}" ]] || return 0
  kill "${_SLOW_NOTICE_PID}" 2>/dev/null || true
  wait "${_SLOW_NOTICE_PID}" 2>/dev/null || true
  _SLOW_NOTICE_PID=""
}

invoke_agent() {
  local agent_name="$1"
  local prompt="$2"
  local cache_file="$3"
  shift 3
  local -a model_args=("$@")

  # An empty cache_file means "always run live, never cache" -- used by
  # callers that need a guaranteed-fresh result (e.g. adversarial-reviewer
  # during a retry-after-FAIL, where a cached PASS from an earlier attempt
  # would feed stale evidence to the arbiter; see claude-config#246).
  # Check cache first
  if [[ -n "${cache_file}" && -f "${cache_file}" ]]; then
    local cached_verdict
    cached_verdict=$(head -1 "${cache_file}")
    if [[ "${cached_verdict}" == "PASS" ]]; then
      log_info "${agent_name}: cached PASS"
      echo "VERDICT: PASS (cached)"
      return 0
    fi
    # Cache was FAIL or invalid - re-review
    rm -f "${cache_file}"
  fi

  log_info "Running ${agent_name} agent..."

  local start_time
  start_time=$(date +%s)

  # Invoke agent via Claude CLI
  # Unset CLAUDECODE to allow invocation from within a Claude Code session.
  # Claude CLI 2.1.50+ refuses to start if CLAUDECODE is set (anti-nesting check).
  # Safe here because --no-session-persistence + piped input = non-interactive child process.
  local agent_output
  local exit_code=0
  # --output-format json + --json-schema: the reviewer returns a
  # schema-constrained object in `.structured_output` alongside the prose in
  # `.result`, so the blocking decision arrives as a boolean instead of a word
  # the gate has to find in a sentence (claude-config#443).
  #
  # stderr is no longer merged with 2>&1. It used to be, which was harmless
  # when stdout was prose — but a CLI upgrade notice or deprecation warning
  # interleaved into a JSON document makes it unparseable, which would silently
  # demote every review to the prose fallback path. Same reasoning, and the
  # same pattern, as codebase mode and the parallel invocations (issue #89).
  local _agent_err
  _agent_err=$(mktemp)
  # Use || to prevent set -e from propagating if the CLI exits non-zero.
  # exit_code is then set to the actual failure code for the handler below.
  #
  # Every caller runs invoke_agent in a subshell ($(...) or ( ... ) &), so
  # this EXIT trap is that subshell's own and cannot replace the script's.
  # It is the backstop; the explicit stop right after the CLI returns is
  # the normal path. Guarded so a future main-shell caller cannot clobber
  # the script's EXIT trap.
  _slow_notice_start "${agent_name}"
  if [[ "${BASHPID}" != "$$" ]]; then
    trap '_slow_notice_stop' EXIT
  fi
  agent_output=$(echo "${prompt}" | timeout "${TIMEOUT_SECONDS}" env -u CLAUDECODE "${CLAUDE_CLI}" --agent "${agent_name}" -p "${model_args[@]}" --output-format json --json-schema "${REVIEW_JSON_SCHEMA}" --tools "" --no-session-persistence 2>"${_agent_err}") || exit_code=$?
  _slow_notice_stop
  if [[ -s "${_agent_err}" ]]; then
    cat "${_agent_err}" >&2
  fi
  rm -f "${_agent_err}"
  unset _agent_err

  # Handle timeout. This function does not decide whether that blocks; the
  # caller does, and each caller reports the outcome itself (#590). Saying
  # "BLOCKING" here printed a block that the whole-diff path then let through.
  if [[ ${exit_code} -eq 124 ]]; then
    log_error "${agent_name} timed out after ${TIMEOUT_SECONDS}s"
    log_error "Review timeout means the review did not complete."
    log_error ""
    log_error "Options:"
    log_error "  1. Retry the commit (review will run again)"
    log_error "  2. Increase timeout: git config review.timeout 300"
    log_error "  3. Split into smaller commits"
    echo "VERDICT: FAIL (timeout)"
    return 1
  elif [[ ${exit_code} -ne 0 ]]; then
    log_error "${agent_name} exited with error code ${exit_code}"
    log_error "Agent error means the review did not complete."
    log_error ""
    log_error "Options:"
    log_error "  1. Retry the commit (review will run again)"
    log_error "  2. Check Claude CLI: claude --version"
    echo "VERDICT: FAIL (agent error: ${exit_code})"
    return 1
  fi

  local end_time
  end_time=$(date +%s)
  local elapsed=$((end_time - start_time))
  log_info "${agent_name} completed in ${elapsed}s"

  # Unwrap the JSON envelope into prose, with the structured boolean attached
  # as a leading sentinel when the reviewer actually supplied one. A response
  # that is not an envelope (older CLI, raw error text) passes through as prose,
  # unmarked, so the gate falls back to has_blocking_severity().
  agent_output=$(normalize_agent_response "${agent_output}")

  # Return the output for parsing
  echo "${agent_output}"

  # Cache verdict if PASS (unless caching was disabled via an empty cache_file)
  local _cache_verdict
  _cache_verdict=$(parse_verdict "${agent_output}")
  if [[ -n "${cache_file}" && "${_cache_verdict}" == "PASS" ]]; then
    echo "PASS" >"${cache_file}"
    date -u +%Y-%m-%dT%H:%M:%SZ >>"${cache_file}"
  fi
}

# Records a code-reviewer/adversarial-reviewer disagreement and how the
# arbiter resolved it. claude-config#332 reworked this: it used to file a
# GitHub issue on EVERY disagreement, which had three defects.
#
#   1. Wrong destination. The destination repo is hardcoded to
#      smartwatermelon/claude-config, but four of the six issues ever filed
#      were about beacon-biosignals/infra — a different org entirely.
#   2. Leaked reviewed source. The body pasted all three reviewers' verbatim
#      output, which quotes code from the repo under review. Another org's
#      Terraform (module wiring, cluster names, bucket refs) ended up in a
#      personal repo purely as a side effect.
#   3. Fired on the healthy case. The arbiter ruled PASS in 5 of 6. A strict
#      reviewer disagreeing with a skeptical one is the system working, not
#      a defect worth a tracked issue.
#
# New behavior:
#   * The LOCAL LOG is the default record. Every disagreement appends a full
#     verbatim record (all three reviewers) to ${DISAGREEMENT_LOG}, a sibling
#     of REVIEW_LOG inside this repo's .git/. Verbatim is fine there: it never
#     leaves the machine and it stays with the repo it describes.
#   * A GitHub issue is filed ONLY when the arbiter verdict is FAIL. That is
#     the case where the disagreement says something about the TOOLING (a
#     reviewer produced a finding the arbiter upheld against a PASS), which is
#     why the destination stays hardcoded to this infrastructure's own repo.
#   * When an issue IS filed, it carries only metadata and the arbiter's own
#     reasoning — our tooling's summary, not reviewed source. Reviewer output
#     stays in the local log, which the issue points at by path.
#   * Deduped on (repo, branch) using the local log as the source of truth, so
#     a long-running branch files at most once no matter how many pushes it
#     takes. Issues #323/#324/#325 were one branch re-filing on every push.
#
# Best-effort throughout: this must never block or fail a commit, whatever
# the gh auth state, API result, or writability of the log path.
#
# Reviewer output is MODEL-AUTHORED and untrusted. It is only ever written to
# a file via printf with a literal format string — never eval'd, never
# interpolated into a command, never passed to a search query.
file_reviewer_disagreement_issue() {
  local cr_output="$1" ar_output="$2" arbiter_output="$3" arbiter_verdict="$4"

  local repo_slug="${REPO_OWNER:-unknown}/${REPO_NAME:-unknown}"
  local branch="${_review_branch:-unknown}"
  local commit="${_review_commit:-unknown}"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")

  # The local log is the whole record. There is no dedup key any more: it
  # existed only to stop one branch re-filing an issue on every push, and no
  # issue is filed. Existing `filed-issue-for:` lines in old logs are inert.
  #
  # Appended on EVERY disagreement, whatever the arbiter verdict — a PASS
  # disagreement is as diagnostically useful as a FAIL, and neither is
  # published anywhere.
  if [[ -n "${DISAGREEMENT_LOG}" ]]; then
    {
      printf -- '=== REVIEWER DISAGREEMENT %s ===\n' "${ts}"
      printf -- 'repo: %s\n' "${repo_slug}"
      printf -- 'branch: %s\n' "${branch}"
      printf -- 'commit: %s\n' "${commit}"
      printf -- 'arbiter_model: %s\n' "${ARBITER_MODEL:-unknown}"
      printf -- 'arbiter_verdict: %s\n' "${arbiter_verdict}"
      printf -- '--- code-reviewer output ---\n%s\n' "${cr_output}"
      printf -- '--- adversarial-reviewer output ---\n%s\n' "${ar_output}"
      printf -- '--- arbiter reasoning ---\n%s\n' "${arbiter_output}"
      printf -- '=== END DISAGREEMENT ===\n'
    } >>"${DISAGREEMENT_LOG}" 2>/dev/null || true
  fi

  # --- 2. No GitHub issue is filed. ---
  # This used to file into smartwatermelon/claude-config whenever the arbiter
  # returned FAIL, on the premise that an arbiter FAIL is a fact about the
  # TOOLING. Five filings later (claude-config#358/#363/#378/#390/#414) that
  # premise did not hold: not one produced work in this repo.
  #
  # A FAIL means only "the arbiter sided with code-reviewer". In practice that
  # resolved to one of two things, neither a tooling defect:
  #   * The arbiter was right (#390, #414) — the system working as designed.
  #     The finding then belongs to the repo under review, which is usually
  #     not this one: four of the five were about other repos.
  #   * The arbiter was wrong (#358, which hallucinated a variable as
  #     undefined that was defined in the same file). Worth knowing, but the
  #     filed issue reads as a code ticket, so the actual signal is invisible
  #     until a human checks the upstream source.
  #
  # This is the second narrowing of this gate. claude-config#332 removed
  # filing-on-every-disagreement because it "fired on the healthy case"; that
  # change kept the same verdict-keyed shape and kept filing the other half of
  # the healthy case. See claude-config#418 for the evidence.
  #
  # The local log written above remains the record. It is strictly richer than
  # the issue ever was — full verbatim output from all three reviewers, on
  # every disagreement rather than only FAIL — and it stays with the repo it
  # describes, which is also why it carries no cross-org source-leak risk.
  return 0
}

# --- Helper Functions for Progressive Review ---

# Read the developer's commit message for the current invocation, so it can be
# injected into review prompts as "DEVELOPER INTENT". Without this, the
# chunked reviewer judges each file in isolation and can flag false positives
# when the rationale spans files (e.g. a project rename where storage-key
# changes look unsafe unless you also see the bundle-ID change that makes the
# renamed app a fresh install). Echoes nothing when no message is available
# so callers can omit the header entirely instead of emitting an empty one.
#
# Sources by priority:
#   --message-file=PATH     -> read from PATH (highest priority, regardless of mode)
#   commit                  -> $GIT_DIR/COMMIT_EDITMSG (template '#' lines stripped)
#                              NOTE: during pre-commit hook execution this
#                              ALWAYS contains the PREVIOUS commit's message
#                              (per `man githooks`: pre-commit "is invoked
#                              before obtaining the proposed commit log
#                              message"). Use --message-file from the
#                              commit-msg hook to inject the real one.
#   full-diff               -> every commit message on the branch being pushed
#                              (base..HEAD, newest first, capped), where base
#                              is origin/main, else main — the same base the
#                              dotfiles pre-push hook diffs against. Falls back
#                              to HEAD's message when that range is empty.
#                              claude-config#489: the pre-push reviewer used to
#                              see the diff alone and re-flag tradeoffs the
#                              author had already explained.
#   pre-push / default      -> git log -1 --format=%B HEAD
#   codebase                -> empty (no specific commit context)
_read_commit_message() {
  local msg=""

  # Highest priority: explicit --message-file flag. Used by the commit-msg
  # hook to inject the in-progress message (the only context where it is
  # actually written to disk). Applies regardless of REVIEW_MODE so future
  # callers can override the default source for full-diff / pre-push too.
  #
  # When the flag is set, it is authoritative: if the file is missing or
  # unreadable, return empty (do NOT fall through to the per-mode source).
  # Callers who want the fallback should simply omit --message-file.
  # Rationale: silently substituting a different source on a missing
  # --message-file would re-introduce the very stale-message bug this flag
  # exists to fix (commit-msg hook hands us $1; if $1 is moved/deleted by
  # the time we read it, COMMIT_EDITMSG would be PRE-rewrite and stale).
  if [[ -n "${MESSAGE_FILE:-}" ]]; then
    if [[ -r "${MESSAGE_FILE}" ]]; then
      # || true guards set -e/pipefail: grep exits 1 on an empty/template-only
      # (all-comment) message file, which pipefail would otherwise propagate
      # into this assignment and abort the script. Issue #148.
      msg=$(grep -v '^#' "${MESSAGE_FILE}" 2>/dev/null \
        | awk 'NF{found=1} found{print}' \
        | awk 'BEGIN{n=0} {lines[n++]=$0} END{end=n-1; while(end>=0 && lines[end]~/^[[:space:]]*$/) end--; for(i=0;i<=end;i++) print lines[i]}') || true
      if [[ -n "${msg//[[:space:]]/}" ]]; then
        printf '%s\n' "${msg}"
      fi
    fi
    return 0
  fi

  case "${REVIEW_MODE}" in
    codebase)
      return 0
      ;;
    commit)
      local git_dir editmsg
      git_dir=$(git rev-parse --git-dir 2>/dev/null || echo "")
      [[ -n "${git_dir}" ]] || return 0
      editmsg="${git_dir}/COMMIT_EDITMSG"
      [[ -f "${editmsg}" ]] || return 0
      # Strip git-template comment lines (leading '#') and leading/trailing
      # blank lines. Use grep -v to drop comments; awk trims surrounding blanks.
      # || true guards set -e/pipefail: grep exits 1 when COMMIT_EDITMSG is
      # empty or template-only (e.g. --allow-empty-message), which pipefail
      # would otherwise propagate into this assignment and abort. Issue #148.
      msg=$(grep -v '^#' "${editmsg}" 2>/dev/null \
        | awk 'NF{found=1} found{print}' \
        | awk 'BEGIN{n=0} {lines[n++]=$0} END{end=n-1; while(end>=0 && lines[end]~/^[[:space:]]*$/) end--; for(i=0;i<=end;i++) print lines[i]}') || true
      ;;
    full-diff)
      local base_ref=main
      if git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
        base_ref=origin/main
      fi
      # One header line per commit so the reviewer can tell messages apart.
      # Capped: a long branch must not crowd the diff out of the prompt.
      msg=$(git log --no-merges --format='--- %h%n%B' "${base_ref}..HEAD" 2>/dev/null \
        | awk -v max=200 'NR<=max {print} NR==max+1 {print "[... further commit messages truncated]"}') || true
      if [[ -z "${msg//[[:space:]]/}" ]]; then
        msg=$(git log -1 --format=%B HEAD 2>/dev/null) || true
      fi
      ;;
    *)
      # pre-push and any future post-commit mode that doesn't early-exit
      # before reaching this function.
      msg=$(git log -1 --format=%B HEAD 2>/dev/null \
        | awk 'NF{found=1} found{print}' \
        | awk 'BEGIN{n=0} {lines[n++]=$0} END{end=n-1; while(end>=0 && lines[end]~/^[[:space:]]*$/) end--; for(i=0;i<=end;i++) print lines[i]}')
      ;;
  esac
  # Suppress whitespace-only results so callers can test for "non-empty" cleanly.
  if [[ -n "${msg//[[:space:]]/}" ]]; then
    printf '%s\n' "${msg}"
  fi
}

show_large_diff_summary() {
  local total_lines="$1"

  echo "" >&2
  echo "=== LARGE DIFF SUMMARY ===" >&2
  echo "" >&2

  # File statistics
  local files_changed
  files_changed=$(git diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')

  echo "Total changes: ${total_lines} lines across ${files_changed} files" >&2
  echo "" >&2

  # Top changed files
  echo "Top 10 changed files:" >&2
  git diff --cached --numstat 2>/dev/null \
    | sort -rn \
    | head -10 \
    | awk '{printf "  %5d + | %5d - | %s\n", $1, $2, $3}' >&2 || true

  echo "" >&2
  log_info "AI review skipped for very large diffs (${total_lines} > ${REVIEW_SKIP_THRESHOLD} lines)"
  log_info "To review manually: git diff --cached | claude --agent code-reviewer -p --tools \"\""
  log_warn "Allowing commit without AI review (diff too large is not a code quality issue)"
  echo "" >&2
}

# True when the adversarial-reviewer agent is installed. Shared by the
# chunked path and the whole-diff path so the two cannot disagree about it.
_adversarial_reviewer_installed() {
  find -L "${HOME}/.claude/plugins/marketplaces" -name "adversarial-reviewer.md" -type f 2>/dev/null | grep -q .
}

perform_chunked_review() {
  local total_lines="$1"

  log_info "Performing chunked review (${total_lines} lines total, reviewing files ≤ ${REVIEW_CHUNK_SIZE} lines each)"

  # Get list of changed files
  local files
  files=$(git diff --cached --name-only 2>/dev/null || echo "")

  if [[ -z "${files}" ]]; then
    log_warn "No files to review"
    return 0
  fi

  local file_count
  file_count=$(echo "${files}" | wc -l | tr -d ' ')

  log_info "Reviewing ${file_count} files individually..."

  local overall_verdict="PASS"
  local blocking_count=0
  local warning_count=0
  local reviewed_files=0
  local skipped_files=0
  local issues_output=""
  # One "path (reason)" line per file that was NOT reviewed. A non-empty list
  # means the run is INCOMPLETE and must not report a pass (#451).
  local unreviewed_list=""
  # Files handed to a reviewer subshell. The aggregate loop uses it to tell a
  # file that was never dispatched (already listed above) from one whose
  # subshell died without writing a result, which must not vanish silently.
  local dispatched_list=""

  # Parallel dispatch: up to CHUNK_PARALLEL claude invocations in flight.
  # Each subshell writes its result (file path on line 1, agent output from
  # line 2 onwards) to a unique file under _chunk_results. Aggregation runs
  # serially after `wait`. Bound prevents pathological diffs (50 files)
  # from launching 50 concurrent claude processes.
  local CHUNK_PARALLEL
  CHUNK_PARALLEL=$(git config --get --type=int review.chunkParallel 2>/dev/null || echo "4")
  # Not `local`: the EXIT trap references this by name for cleanup on
  # abnormal exit (SIGINT while the function is on the call stack). Bash's
  # visibility of function-local variables to traps is implementation-
  # dependent, so keep this at script scope where the trap can always see
  # it. On the normal return path the in-function `rm -rf` below still
  # handles cleanup; the trap is the backstop for SIGINT / errexit.
  # Issue #130.
  _chunk_results=$(mktemp -d)
  local -a _chunk_pids=()

  # Read the commit message ONCE for this run; injected into every per-file
  # prompt so the reviewer sees developer intent across chunks. See
  # _read_commit_message for source-by-mode behavior.
  local commit_msg commit_msg_section
  commit_msg=$(_read_commit_message)
  if [[ -n "${commit_msg}" ]]; then
    commit_msg_section="DEVELOPER INTENT (commit message):
${commit_msg}
---

"
  else
    commit_msg_section=""
  fi

  # adversarial-reviewer: ONE pass over the whole diff, in parallel with the
  # per-file code-reviewer passes. Issue #558: this path used to call only
  # code-reviewer, so a chunked commit never got adversarial review and the
  # log gave no sign of it. Its value is cross-file reasoning, which per-file
  # chunks cannot give, so it is not chunked. The diff here is at most
  # review.skipThreshold lines — what full-diff mode already hands it.
  #
  # Its output file lives in a subdirectory of _chunk_results. Per-file result
  # names have every `/` replaced, so no repo path can collide with it.
  local adv_available=false adv_out_file=""
  if _adversarial_reviewer_installed; then
    adv_available=true
    mkdir -p "${_chunk_results}/meta"
    adv_out_file="${_chunk_results}/meta/adversarial.out"
    local adv_prompt
    adv_prompt="${commit_msg_section}You are performing a pre-commit code review of the WHOLE diff below. It is large, so a second reviewer is also reading it file by file; your job is the cross-file view: how the changes interact, what one file assumes about another, and what fails when they meet.

IMPORTANT: You are being invoked as a focused analysis tool with --no-session-persistence.
Do NOT output Protocol 0 environment check or any preamble.
Begin your response directly with the verdict in the specified format below.

${REVIEW_SEVERITY_RULES}

CRITICAL: Respond with this exact format:

VERDICT: [PASS or FAIL]

[If FAIL, list each issue:]
ISSUE: [one-line description]
SEVERITY: [BLOCKING, FIX_NOW, or WARNING]
LOCATION: [file:line]
DETAILS: [explanation and fix]

Review this diff:

\`\`\`diff
${DIFF}
\`\`\`"
    (
      _aout=$(invoke_agent "adversarial-reviewer" "${adv_prompt}" "${CACHE_DIR}/adversarial-chunked-${DIFF_HASH}" "${ADVERSARIAL_MODEL_ARGS[@]}") || true
      printf '%s\n' "${_aout}" >"${adv_out_file}"
    ) &
  else
    log_warn "adversarial-reviewer agent not found - chunked review runs code-reviewer only (see ~/.claude/docs/CUSTOM_AGENTS.md)"
  fi

  # Dispatch phase: build per-file prompt, spawn background invoke_agent.
  # Skip-if-too-large is still serial (and bumps skipped_files directly).
  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue

    local file_diff
    file_diff=$(git diff --cached -U10 -- "${file}" 2>/dev/null || echo "")
    [[ -z "${file_diff}" ]] && continue

    local file_lines
    file_lines=$(echo "${file_diff}" | wc -l | tr -d ' ')

    if [[ ${file_lines} -gt ${REVIEW_CHUNK_SIZE} ]]; then
      log_warn "Cannot review ${file} (${file_lines} lines > ${REVIEW_CHUNK_SIZE} chunk size)"
      ((skipped_files += 1))
      unreviewed_list="${unreviewed_list}${file} (${file_lines} lines > chunkSize ${REVIEW_CHUNK_SIZE})
"
      continue
    fi

    # Bounded concurrency: reap finished pids, sleep if still at cap.
    while [[ ${#_chunk_pids[@]} -ge ${CHUNK_PARALLEL} ]]; do
      local -a _alive_pids=()
      local _p
      for _p in "${_chunk_pids[@]}"; do
        if kill -0 "${_p}" 2>/dev/null; then
          _alive_pids+=("${_p}")
        fi
      done
      _chunk_pids=("${_alive_pids[@]}")
      [[ ${#_chunk_pids[@]} -lt ${CHUNK_PARALLEL} ]] || sleep 0.1
    done

    local file_prompt
    file_prompt="${commit_msg_section}Reviewing file: ${file}

IMPORTANT: You are being invoked as a focused analysis tool with --no-session-persistence.
Do NOT output Protocol 0 environment check or any preamble.
Begin your response directly with the verdict in the specified format below.

Focus on:
1. Correctness: Logic errors, null handling, race conditions
2. Security: Hardcoded secrets, injection vulnerabilities, auth issues
3. Error Handling: Silent failures, missing error cases
4. Completeness: Edge cases, incomplete implementations
5. Comments: limited to what isn't obvious from the code — flag comments that only restate what the code already says. Report these as SEVERITY: FIX_NOW, never as BLOCKING.

${REVIEW_SEVERITY_RULES}

CRITICAL: Respond with this exact format:

VERDICT: [PASS or FAIL]

[If FAIL, list each issue:]
ISSUE: [one-line description]
SEVERITY: [BLOCKING, FIX_NOW, or WARNING]
LOCATION: [file:line]
DETAILS: [explanation and fix]

Review this diff:

\`\`\`diff
${file_diff}
\`\`\`"

    # Create per-file cache key. Includes SCRIPT_SHA so prompt/logic edits
    # invalidate stale PASS entries (see DIFF_HASH above for rationale).
    local file_cache_key
    # Use `shasum -a 256` (BSD) rather than `sha256sum` (GNU-only) so the cache
    # works on macOS by default. Previously this fell to the "nocache" fallback
    # on every Darwin host unless the user had installed GNU coreutils, which
    # silently disabled per-file chunked caching. Matches the DIFF_HASH tool
    # choice elsewhere in this file. Issue #126.
    file_cache_key=$(printf '%s\n%s\n' "${SCRIPT_SHA:-nover}" "${file_diff}" | shasum -a 256 2>/dev/null | awk '{print $1}' || echo "nocache")
    [[ -n "${file_cache_key}" ]] || file_cache_key="nocache"
    local file_cache="${CACHE_DIR}/${file//\//_}_${file_cache_key}"

    # Sanitize file path to a safe filename for the result file.
    local _safe_name="${file//\//__}"
    _safe_name="${_safe_name// /_}"

    # Background dispatch. Each subshell captures invoke_agent stdout;
    # stderr (progress lines) flows through to the user's terminal. Empty
    # output on agent error is normalized here so the aggregate loop can
    # treat it uniformly.
    (
      _fout=$(invoke_agent "${CODE_REVIEWER_AGENT}" "${file_prompt}" "${file_cache}" "${CODE_REVIEWER_MODEL_ARGS[@]}") || true
      [[ -n "${_fout}" ]] || _fout="VERDICT: FAIL (agent error: invoke_agent produced no output)"
      {
        printf '%s\n' "${file}"
        printf '%s\n' "${_fout}"
      } >"${_chunk_results}/${_safe_name}"
    ) &
    _chunk_pids+=("$!")
    dispatched_list="${dispatched_list}${file}
"
  done <<<"${files}"

  # Wait for all remaining background jobs.
  wait 2>/dev/null || true

  # Aggregate phase: walk per-file results in the original git-diff file
  # order (so the issues_output digest is deterministic and matches the
  # pre-parallel serial order, not alphabetic-by-sanitized-name). Runs
  # serially on the main shell so accumulator updates are safe.
  local _result_file _rfile _rout _agg_safe
  while IFS= read -r _rfile; do
    [[ -z "${_rfile}" ]] && continue
    _agg_safe="${_rfile//\//__}"
    _agg_safe="${_agg_safe// /_}"
    _result_file="${_chunk_results}/${_agg_safe}"
    if [[ ! -f "${_result_file}" ]]; then
      if grep -Fxq -- "${_rfile}" <<<"${dispatched_list}"; then
        log_warn "No result for ${_rfile} - reviewer process wrote nothing; file not reviewed"
        ((skipped_files += 1))
        unreviewed_list="${unreviewed_list}${_rfile} (reviewer wrote no result)
"
      fi
      continue
    fi
    _rout=$(tail -n +2 "${_result_file}")

    # Synthetic transient-failure verdicts (timeout or agent error) indicate
    # the agent failed — skip the file rather than counting it as a blocking
    # issue. Matches the prior serial behavior where agent_exit != 0 always
    # incremented skipped_files. invoke_agent emits either "(timeout)" or
    # "(agent error: N)"; real content failures produce a bare "VERDICT: FAIL"
    # followed by SEVERITY/ISSUE/LOCATION lines with no parens on the verdict.
    # Match any "VERDICT: FAIL (" (parenthesis-suffixed) to catch both.
    if echo "${_rout}" | grep -q "VERDICT: FAIL ("; then
      log_warn "Agent timeout/error for ${_rfile} - file not reviewed"
      ((skipped_files += 1))
      unreviewed_list="${unreviewed_list}${_rfile} (agent error or timeout)
"
      continue
    fi

    # Same version-pin-unfamiliarity downgrade as the whole-diff path, applied
    # per-file so chunked review doesn't diverge in behavior from small diffs.
    _rout=$(downgrade_version_unfamiliarity_findings "${_rout}")

    _chunk_verdict=$(parse_verdict "${_rout}")
    if [[ "${_chunk_verdict}" == "FAIL" || "${_chunk_verdict}" == "REVISE" ]]; then
      if output_blocks "${_rout}"; then
        ((blocking_count += 1))
        overall_verdict="FAIL"
      else
        ((warning_count += 1))
      fi

      # The digest is read by a human and fed to later prompts; strip the
      # machinery sentinel so it looks exactly as it did before #443.
      issues_output="${issues_output}

=== Issues in ${_rfile} ===
$(strip_structured_blocking "${_rout}")"
    fi

    ((reviewed_files += 1))
  done <<<"${files}"

  # Read adversarial-reviewer's result (the `wait` above covered its job).
  # Same normalisation, downgrade and gate as the whole-diff path, so the
  # two paths reach the same decision on the same output.
  local adv_verdict="N/A" adv_status="" adv_output="" adv_display=""
  if [[ "${adv_available}" == true ]]; then
    adv_output=$(cat "${adv_out_file}" 2>/dev/null || true)
    [[ -n "${adv_output//[[:space:]]/}" ]] || adv_output="VERDICT: FAIL (agent error: invoke_agent produced no output)"
    adv_output=$(downgrade_version_unfamiliarity_findings "${adv_output}")
    adv_display=$(strip_structured_blocking "${adv_output}")
    adv_verdict=$(parse_verdict "${adv_output}")
    if [[ "${adv_verdict}" == "REVISE" ]]; then
      adv_verdict="FAIL"
    fi
    if [[ "${adv_verdict}" != "PASS" && "${adv_verdict}" != "FAIL" ]]; then
      adv_status="unparseable"
    elif [[ "${adv_verdict}" == "FAIL" ]] && grep -qE "VERDICT: (FAIL|Revise) \((timeout|agent error)" <<<"${adv_display}"; then
      adv_status="transient"
    elif [[ "${adv_verdict}" == "FAIL" ]] && output_blocks "${adv_output}"; then
      adv_status="blocking"
    elif [[ "${adv_verdict}" == "FAIL" ]]; then
      adv_status="warnings"
    else
      adv_status="pass"
    fi
  fi

  rm -rf "${_chunk_results}"
  unset _chunk_results _chunk_pids

  # Display accumulated issues
  if [[ -n "${issues_output}" ]]; then
    echo "${issues_output}" >&2
    echo "" >&2
  fi

  # Summary
  echo "" >&2
  echo "=== CHUNKED REVIEW SUMMARY ===" >&2
  echo "Reviewed: ${reviewed_files}/${file_count} files" >&2
  if [[ ${skipped_files} -gt 0 ]]; then
    echo "NOT reviewed: ${skipped_files} files" >&2
    printf '%s' "${unreviewed_list}" | sed 's/^/  - /' >&2
  fi
  echo "Blocking issues: ${blocking_count}" >&2
  echo "Warnings: ${warning_count}" >&2
  case "${adv_status}" in
    "") echo "adversarial-reviewer: NOT RUN (agent not installed)" >&2 ;;
    transient) echo "adversarial-reviewer: NOT COMPLETED (timeout or agent error)" >&2 ;;
    *) echo "adversarial-reviewer: ${adv_verdict} (whole diff)" >&2 ;;
  esac
  echo "" >&2

  if [[ -n "${adv_display}" ]]; then
    echo "=== ADVERSARIAL REVIEWER (whole diff) ===" >&2
    echo "${adv_display}" >&2
    echo "" >&2
  fi

  # Write results to REVIEW_LOG (global; || true guards set -e)
  {
    printf '=== CHUNKED REVIEW ===\n'
    printf 'Reviewed: %d/%d files | Blocking: %d | Warnings: %d\n' \
      "${reviewed_files}" "${file_count}" "${blocking_count}" "${warning_count}"
    if [[ ${skipped_files} -gt 0 ]]; then
      printf 'Files skipped (agent error or oversized chunk): %d\n' "${skipped_files}"
      printf '%s' "${unreviewed_list}" | sed 's/^/unreviewed: /'
    fi
    if [[ -n "${issues_output}" ]]; then
      printf '%s\n' "${issues_output}"
    fi
    if [[ -n "${adv_display}" ]]; then
      printf '=== ADVERSARIAL REVIEWER (whole diff) ===\n%s\n' "${adv_display}"
    fi
    # Same verdict lines as the whole-diff path, so the Protocol 4 log check
    # reads a chunked commit the same way. A reviewer that did not run says
    # so here rather than leaving the line out.
    if [[ "${overall_verdict}" == "FAIL" ]]; then
      printf 'code-reviewer: FAIL\n'
    else
      printf 'code-reviewer: PASS (%d/%d files)\n' "${reviewed_files}" "${file_count}"
    fi
    case "${adv_status}" in
      "") printf 'adversarial-reviewer: skipped (agent not installed)\n' ;;
      transient) printf 'adversarial-reviewer: skipped (timeout or agent error)\n' ;;
      unparseable) printf 'adversarial-reviewer: FAIL (unparseable)\n' ;;
      *) printf 'adversarial-reviewer: %s\n' "${adv_verdict}" ;;
    esac
  } >>"${REVIEW_LOG}" || true

  if [[ "${overall_verdict}" == "FAIL" ]]; then
    log_error "Chunked review found ${blocking_count} blocking issues in reviewed files"
    echo "" >&2
    echo "💡 Tip: If this appears to be a false positive, force single-pass review:" >&2
    echo "   git config review.maxLines 2500  # review whole diff at once" >&2
    echo "   git commit                        # retry" >&2
    echo "   git config --unset review.maxLines" >&2
    return 1
  elif [[ "${adv_status}" == "blocking" ]]; then
    log_error "adversarial-reviewer found issues - commit rejected"
    log_error "Note: the per-file code-reviewer passes did not block; adversarial-reviewer read the whole diff"
    return 1
  elif [[ "${adv_status}" == "unparseable" ]]; then
    log_error "Could not parse adversarial-reviewer verdict"
    describe_unparseable_verdict "${adv_output}"
    log_error "BLOCKING: Cannot verify adversarial review result"
    return 1
  elif [[ ${skipped_files} -gt 0 ]]; then
    # Fail-closed on ANY unreviewed file, not only when all were skipped.
    # #200 closed the 0/N case; #451 is the partial case: a 2625-line commit
    # reviewed README.md and CLAUDE.md, skipped the 1029-line script and its
    # 1351-line test suite as oversized, and printed "Chunked review passed".
    # On a large diff the biggest file is the one most likely to be skipped,
    # so a partial pass reads the prose and waves the code through.
    printf 'chunked: INCOMPLETE (%d/%d files not reviewed)\n' "${skipped_files}" "${file_count}" >>"${REVIEW_LOG}" || true
    log_error "Chunked review INCOMPLETE: ${skipped_files}/${file_count} files were not reviewed - cannot verify diff is safe"
    echo "" >&2
    echo "💡 Not reviewed:" >&2
    printf '%s' "${unreviewed_list}" | sed 's/^/   - /' >&2
    echo "   Oversized file: raise the per-file limit above its diff size, e.g." >&2
    echo "     git config review.chunkSize <lines>   (current: ${REVIEW_CHUNK_SIZE})" >&2
    echo "   or split the commit so the file is reviewed on its own." >&2
    echo "   Agent error/timeout: retry the commit, or raise review.timeout." >&2
    return 1
  elif [[ ${reviewed_files} -eq 0 && ${file_count} -gt 0 ]]; then
    # Fail-closed backstop from #200: nothing was reviewed and nothing was
    # listed as skipped (e.g. every per-file diff came back empty). No
    # review signal is not a pass.
    printf 'chunked: INCOMPLETE (0/%d files reviewed)\n' "${file_count}" >>"${REVIEW_LOG}" || true
    log_error "Chunked review reviewed 0/${file_count} files - cannot verify diff is safe"
    echo "   Review manually: git diff --cached | claude --agent code-reviewer -p --tools \"\"" >&2
    return 1
  else
    case "${adv_status}" in
      "")
        log_warn "adversarial-reviewer did NOT run on this commit (agent not installed)"
        log_success "Chunked review passed (${reviewed_files} files reviewed; code-reviewer only)"
        ;;
      transient)
        # Non-blocking, as on the whole-diff path, but never silent.
        log_warn "adversarial-reviewer timed out or errored - it did NOT review this commit (non-blocking)"
        log_warn "  Re-run: git config review.timeout 300, then retry the commit"
        log_success "Chunked review passed (${reviewed_files} files reviewed; code-reviewer only)"
        ;;
      warnings)
        log_warn "adversarial-reviewer found warnings (non-blocking)"
        log_success "Chunked review passed (${reviewed_files} files reviewed; code-reviewer + adversarial-reviewer)"
        ;;
      *)
        log_success "Chunked review passed (${reviewed_files} files reviewed; code-reviewer + adversarial-reviewer)"
        ;;
    esac
    return 0
  fi
}

# --- Read diff from stdin ---
DIFF=$(cat)

# --- Review log: scoped to this repo's .git/ directory ---
# Rationale: A single global log is overwritten by concurrent sessions in other
# repos, making cross-repo contamination undetectable (incident 2026-03-08).
# Per-repo log + identity fields let the controller confirm the log matches
# the repo and commit they just made.
# A literal ".git" fallback here creates a real .git/ DIRECTORY on first write
# in whatever directory the review was launched from (claude-config#519). The
# result looks like a repo to any `[ -d .git ]` check while git itself rejects
# it, and a later real `git init` silently inherits the stale artifacts. There
# is also nothing to review outside a repo, so refuse rather than invent a path.
if ! GIT_DIR_PATH="$(git rev-parse --git-dir 2>/dev/null)"; then
  _review_cwd=$(pwd -L || echo "unknown")
  echo "run-review.sh: not inside a git repository; nothing to review." >&2
  echo "  cwd: ${_review_cwd}" >&2
  exit 1
fi
REVIEW_LOG="${REVIEW_LOG:-${GIT_DIR_PATH}/last-review-result.log}"
# Sibling of REVIEW_LOG: the append-only record of code-reviewer /
# adversarial-reviewer disagreements and how the arbiter resolved each one.
# Unlike REVIEW_LOG (truncated each run), this accumulates across runs — it
# doubles as the dedup source of truth for issue filing (claude-config#332).
# Overridable by env var so tests can point it at a temp path.
DISAGREEMENT_LOG="${DISAGREEMENT_LOG:-${GIT_DIR_PATH}/reviewer-disagreements.log}"
_review_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ || true)
_review_repo=$(cdup=$(git rev-parse --show-cdup 2>/dev/null) && cd "./${cdup:-.}" >/dev/null 2>&1 && pwd -L || echo "unknown")
_review_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached")
_review_commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
{
  printf '%s\n' "${_review_ts}"
  printf 'repo: %s\n' "${_review_repo}"
  printf 'branch: %s\n' "${_review_branch}"
  printf 'commit: %s\n' "${_review_commit}"
} >"${REVIEW_LOG}" || true

# Global pointer: keep ~/.claude/last-review-result.log pointed at the most
# recent per-repo log. Controllers checking the global path will see identity
# fields that reveal cross-repo contamination immediately.
_global_log="${HOME}/.claude/last-review-result.log"
{
  printf '%s\n' "${_review_ts}"
  printf 'repo: %s\n' "${_review_repo}"
  printf 'branch: %s\n' "${_review_branch}"
  printf 'commit: %s\n' "${_review_commit}"
  printf 'log: %s\n' "${REVIEW_LOG}"
} >"${_global_log}" || true

_ec=0 # captured by EXIT trap; declared here so shellcheck sees the assignment
trap '_ec=$?; rm -rf "${_chunk_results:-}" 2>/dev/null; rm -f "${_cr_out:-}" "${_ar_out:-}" "${DIFF_TMPFILE:-}" "${_codebase_err:-}" 2>/dev/null; [[ -n "${REVIEW_LOG:-}" ]] && printf "exit_code: %d\n" "$_ec" >> "${REVIEW_LOG}" || true' EXIT

if [[ -z "${DIFF}" ]]; then
  log_warn "No staged changes to review"
  printf 'skipped: no staged changes\n' >>"${REVIEW_LOG}" || true
  exit 0
fi

# --- Review caching (skip review if diff unchanged since last PASS) ---
CACHE_DIR="${GIT_DIR_PATH}/claude-review-cache"
mkdir -p "${CACHE_DIR}"

# Clean up cache entries older than 30 days to prevent unbounded growth
find "${CACHE_DIR}" -type f -mtime +30 -delete 2>/dev/null || true

# Cache key includes the hash of THIS script so edits to review logic or
# prompt text automatically invalidate stale PASS entries. Without this,
# a tightened adversarial prompt would read old PASS cache for identical
# diffs and silently skip the stricter review. Fail open on shasum miss
# (falls back to diff-only hash) so cache still works in stripped envs.
SCRIPT_SHA=$(shasum -a 256 "${BASH_SOURCE[0]}" 2>/dev/null | awk '{print $1}' | cut -c1-12 || echo "nover")
DIFF_HASH=$(printf '%s\n%s\n' "${SCRIPT_SHA}" "${DIFF}" | shasum -a 256 | awk '{print $1}')
CACHE_FILE="${CACHE_DIR}/${DIFF_HASH}"

if [[ -f "${CACHE_FILE}" ]]; then
  CACHED_VERDICT=$(head -1 "${CACHE_FILE}")
  if [[ "${CACHED_VERDICT}" == "PASS" ]]; then
    log_success "Review cached: identical diff previously passed"
    printf 'skipped: cached PASS\n' >>"${REVIEW_LOG}" || true
    exit 0
  fi
  # If cached verdict was FAIL or unparseable, re-review (code may have changed)
  rm -f "${CACHE_FILE}"
fi

# Skip review entirely on sync branches.
# `sync/*` branches are created by sync-to-public.sh and contain content
# that has already passed full review in the source (private) repo. Running
# the size-cap check against an aggregated sync diff produces false blocks
# on legitimate, already-reviewed code.
_current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
if [[ "${REVIEW_MODE}" == "commit" ]] && [[ "${_current_branch}" == sync/* ]]; then
  log_info "Sync branch (${_current_branch}) - skipping review (content already reviewed upstream)"
  printf 'skipped: sync branch (%s)\n' "${_current_branch}" >>"${REVIEW_LOG}" || true
  exit 0
fi
unset _current_branch

# --- Check for documentation-only / lockfile-only changes (commit mode only) ---
# These short-circuits compare staged-index file names against skip-eligible
# patterns. In --mode=full-diff and --mode=codebase the real diff source is
# stdin (piped main...HEAD), NOT the staged index; the staged index may be
# markdown-only while the branch's piped diff contains code. Skipping based
# on the wrong source silently bypasses the full-branch review those modes
# are designed for. Commit-mode DIFF is piped from `git diff --cached` so
# staged index aligns with the review input — the short-circuits are safe
# only there. Issue #131.
#
# MUST stay ABOVE the size dispatch below. A generated file is exempt from
# review regardless of how large it is, so sizing it up first can only ever
# block a commit that would have produced zero findings. A regenerated
# lockfile is one indivisible file, so "split into smaller commits" is not
# available to the human, and `review.skipThreshold` only reroutes it into a
# chunked review that fails on the oversized chunk. Issue #427.
#
# Derive CHANGED_FILES outside the guard so it's defined (empty) in other
# modes; the two checks below are both no-ops when unset.
CHANGED_FILES=""
if [[ "${REVIEW_MODE}" == "commit" ]]; then
  CHANGED_FILES=$(git diff --cached --name-only 2>/dev/null || echo "")
fi

# Skip code review for markdown files - they're handled by markdownlint
if [[ -n "${CHANGED_FILES}" ]]; then
  # Check if ALL changed files are markdown
  NON_MD_FILES=$(echo "${CHANGED_FILES}" | grep -vE '\.md$' || echo "")
  if [[ -z "${NON_MD_FILES}" ]]; then
    log_info "Markdown-only changes detected - skipping code review (handled by markdownlint)"
    printf 'skipped: markdown-only\n' >>"${REVIEW_LOG}" || true
    exit 0
  fi
fi

# Skip code review for lockfiles - they're generated files
if [[ -n "${CHANGED_FILES}" ]]; then
  # Check if ALL changed files are lockfiles
  NON_LOCK_FILES=$(echo "${CHANGED_FILES}" | grep -vE '(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Gemfile\.lock|Cargo\.lock|composer\.lock|\.terraform\.lock\.hcl)$' || echo "")
  if [[ -z "${NON_LOCK_FILES}" ]]; then
    log_info "Lockfile-only changes detected - skipping code review (generated files)"
    printf 'skipped: lockfile-only\n' >>"${REVIEW_LOG}" || true
    exit 0
  fi
fi

# Skip code review for data artifacts - scan logs, TSV/CSV exports.
# Same all-or-nothing shape as the lockfile check: one code file in the set
# and the whole commit is reviewed. Issue #481: a commit of 42 scan logs was
# split six ways to get under the size gate and each piece was AI-reviewed as
# if it were code.
#
# Per-repo overrides (repo-local beats global, like every review.* key):
#   review.artifactSkip=false   turn the skip off entirely
#   review.artifactPatterns     whitespace-separated globs that REPLACE the
#                               default list, e.g. '*.log' to keep CSVs reviewed
# Each glob becomes an anchored ERE: `*` matches any run of characters,
# including `/`, and `?` matches one character.
if [[ -n "${CHANGED_FILES}" ]]; then
  _artifact_skip=$(git config --get --type=bool review.artifactSkip 2>/dev/null || echo "true")
  if [[ "${_artifact_skip}" == "true" ]]; then
    _artifact_patterns=$(git config --get review.artifactPatterns 2>/dev/null || echo "")
    [[ -n "${_artifact_patterns//[[:space:]]/}" ]] \
      || _artifact_patterns='*.log *.tsv *.csv docs/scan/* docs/*/scan/*'
    # Escape ERE metacharacters first, then translate the two glob wildcards.
    # `[` sits last in the bracket list: `[.` would open a collating element.
    # One pattern per line in, one alternation out.
    _artifact_re=$(tr -s '[:space:]' '\n' <<<"${_artifact_patterns}" \
      | grep -v '^$' \
      | sed -e 's/[]+^(){}|$.[\]/\\&/g' -e 's/\*/.*/g' -e 's/?/./g' \
      | paste -sd '|' -) || _artifact_re=""
    _non_artifact=""
    if [[ -n "${_artifact_re}" ]]; then
      # The sed above escaped only a `$` typed INSIDE a glob. This trailing `$`
      # is the real end-of-string anchor: in double quotes a `$` before the
      # closing quote is literal, so the ERE ends `)$`. Pinned by the
      # artifact-only tests in tests/test_run_review_generated_file_skip_order.bats.
      _artifact_re="^(${_artifact_re})$"
      while IFS= read -r _af; do
        [[ -z "${_af}" ]] && continue
        if ! [[ "${_af}" =~ ${_artifact_re} ]]; then
          _non_artifact="${_af}"
          break
        fi
      done <<<"${CHANGED_FILES}"
    else
      _non_artifact="(no usable review.artifactPatterns)"
    fi
    if [[ -z "${_non_artifact}" ]]; then
      log_info "Artifact-only changes detected - skipping code review (patterns: ${_artifact_patterns})"
      log_info "  To review these anyway: git config review.artifactSkip false"
      printf 'skipped: artifact-only (patterns: %s)\n' "${_artifact_patterns}" >>"${REVIEW_LOG}" || true
      exit 0
    fi
    unset _artifact_patterns _artifact_re _non_artifact _af
  fi
  unset _artifact_skip
fi

# Progressive review strategy based on diff size
DIFF_LINES=$(echo "${DIFF}" | wc -l | tr -d ' ')

if [[ "${REVIEW_MODE}" != "full-diff" && "${REVIEW_MODE}" != "codebase" ]] && [[ ${DIFF_LINES} -gt ${REVIEW_SKIP_THRESHOLD} ]]; then
  show_large_diff_summary "${DIFF_LINES}"
  log_error ""
  log_error "BLOCKING: Diff too large for automated review (${DIFF_LINES} lines)"
  log_error ""
  log_error "Options:"
  log_error "  1. Split into smaller commits (recommended)"
  log_error "  2. Increase threshold: git config review.skipThreshold 5000"
  log_error "     Chunked review then needs every file's diff under review.chunkSize"
  log_error "     (current: ${REVIEW_CHUNK_SIZE}); a larger file blocks the commit"
  log_error "     as unreviewed, so raise review.chunkSize too if one is bigger."
  printf 'blocked: diff too large (%d lines > %d threshold)\n' "${DIFF_LINES}" "${REVIEW_SKIP_THRESHOLD}" >>"${REVIEW_LOG}" || true
  exit 1

elif [[ "${REVIEW_MODE}" != "full-diff" && "${REVIEW_MODE}" != "codebase" ]] && [[ ${DIFF_LINES} -gt ${REVIEW_MAX_LINES} ]]; then
  # Medium diff (commit-mode only) — use chunked review.
  # full-diff and codebase modes have their own dedicated handlers below
  # (lines 582+ and 672+) and are INTENDED for large cross-file analysis.
  # Routing them to chunked here would bypass their dedicated prompts
  # whenever the feature-branch diff exceeds REVIEW_MAX_LINES, defeating
  # their purpose. Issue #127.
  log_warn "Diff is large (${DIFF_LINES} lines), using chunked file-by-file review"
  printf 'diff_lines: %d (chunked review)\n' "${DIFF_LINES}" >>"${REVIEW_LOG}" || true
  perform_chunked_review "${DIFF_LINES}"
  exit $? # Exit with chunked review result

elif [[ "${REVIEW_MODE}" != "full-diff" && "${REVIEW_MODE}" != "codebase" ]] && [[ ${DIFF_LINES} -gt $((REVIEW_MAX_LINES * 3 / 4)) ]]; then
  # Approaching limit (commit mode) — warn but proceed with full review.
  log_warn "Diff is approaching review limit (${DIFF_LINES}/${REVIEW_MAX_LINES} lines)"
fi

# Small enough for full review - continue with existing logic below

# --- Check for empty diff (permission/mode changes only) ---
# Skip review if diff contains no actual code changes
# Use a here-string rather than `echo ... | grep -q` — grep -q exits as soon
# as it finds a match, and on a large DIFF that can happen before the pipe's
# writer (echo) finishes, delivering SIGPIPE. Under pipefail the pipeline's
# exit status then becomes echo's 141 instead of grep's real result, so
# `! ...` wrongly evaluates true and the script skips review on a diff that
# DOES have code changes. A here-string has no writer process to race.
# Issues #166, #171 (the removed `2>/dev/null` on echo was a no-op — echo
# cannot fail here since DIFF is always set via `DIFF=$(cat)` above).
if ! grep -qE '^[+-][^+-]' <<<"${DIFF}"; then
  log_info "No code changes detected (permission/metadata only) - skipping review"
  printf 'skipped: permission/metadata only\n' >>"${REVIEW_LOG}" || true
  exit 0
fi

# --- Check for submodule-pointer-only changes ---
# A `Subproject commit <sha>` bump is opaque to every review mode here — this
# script has no access to the submodule's own history, so codebase-mode review
# can only ever restate "contents not inspectable" as a non-blocking issue on
# every bump (see claude-config#192). Operates on DIFF content directly (not
# file names), so — unlike the markdown/lockfile skips above, which are
# commit-mode only — it's safe to apply in every mode, including
# full-diff/codebase where DIFF is piped from main...HEAD rather than the
# staged index.
SUBMODULE_ONLY_LINES=$(echo "${DIFF}" | grep -E '^[+-][^+-]' | grep -vE '^[+-]Subproject commit [0-9a-f]{40}$' || true)
if [[ -z "${SUBMODULE_ONLY_LINES}" ]]; then
  log_info "Submodule-pointer-only changes detected - skipping review (contents not inspectable)"
  printf 'skipped: submodule-pointer-only\n' >>"${REVIEW_LOG}" || true
  exit 0
fi
unset SUBMODULE_ONLY_LINES

# Every path the reviewed diff touches, for downgrade_unverifiable_findings'
# location check (#488). The staged index (commit mode) plus the diff's own
# headers, which are the only source in full-diff mode.
REVIEWED_PATHS=$(printf '%s\n%s\n' "${CHANGED_FILES}" "$(diff_changed_paths "${DIFF}")" | grep -v '^$' | sort -u || true)

# --- Full-diff mode (pre-push cross-file review) ---
if [[ "${REVIEW_MODE}" == "full-diff" ]]; then
  log_info "Full-diff review: analyzing complete feature branch diff"
  log_info "Diff size: ${DIFF_LINES} lines"
  log_info "Model: ${ADVERSARIAL_MODEL}"
  printf 'model: %s\n' "${ADVERSARIAL_MODEL}" >>"${REVIEW_LOG}" || true

  FULL_DIFF_CACHE="${CACHE_DIR}/full-diff-${DIFF_HASH}"

  # Check cache
  if [[ -f "${FULL_DIFF_CACHE}" ]]; then
    CACHED_VERDICT=$(head -1 "${FULL_DIFF_CACHE}")
    if [[ "${CACHED_VERDICT}" == "PASS" ]]; then
      log_success "Full-diff review cached: identical diff previously passed"
      printf 'full-diff: cached PASS\n' >>"${REVIEW_LOG}" || true
      exit 0
    fi
    rm -f "${FULL_DIFF_CACHE}"
  fi

  # The branch's commit messages, so the reviewer sees the author's stated
  # rationale before re-deriving it (#489). Context, not proof: the framing
  # below keeps a message from excusing a real cross-file defect.
  FULL_DIFF_INTENT_SECTION=""
  _fd_msg=$(_read_commit_message)
  if [[ -n "${_fd_msg}" ]]; then
    FULL_DIFF_INTENT_SECTION="DEVELOPER INTENT (commit messages on this branch, newest first):
${_fd_msg}
---
Use this as context, not proof. When a message states a tradeoff the author
deliberately accepted (an outage window, a destroy/recreate, a removed entry
point), do not re-flag that tradeoff as a defect. A message never makes a real
cross-file defect acceptable, and its description of what the code does is a
claim to check against the diff.

"
  fi
  unset _fd_msg

  FULL_DIFF_PROMPT="${FULL_DIFF_INTENT_SECTION}You are performing a pre-push full-diff review of an entire feature branch.
This diff represents ALL changes from main to HEAD — the complete PR surface area.

IMPORTANT: You are being invoked as a focused analysis tool with --no-session-persistence.
Do NOT output Protocol 0 environment check or any preamble.
Begin your response directly with the verdict in the specified format below.

Focus on CROSS-FILE integration issues that per-commit reviews miss:
1. Cross-file consistency: Are interfaces used correctly across file boundaries?
2. State management: Do shared identifiers, IDs, or keys match across files?
3. Error propagation: Do errors flow correctly from source to handler across files?
4. Feature completeness: Are all entry points to new features discoverable?
5. Platform guards: If platform-specific code exists, are both paths tested?
6. Removed functionality: If UI elements or entry points were removed, is that intentional?
7. Security surface: Do auth/RLS/permission changes have corresponding test coverage?

Do NOT repeat per-line issues (those are caught in per-commit review).
Focus ONLY on issues visible when examining the full change set together.

${REVIEW_SEVERITY_RULES}

FIX_NOW does NOT apply at this stage. It is a commit-time tier, and the commit
review has already run over these changes. Use BLOCKING or WARNING, or report
nothing.

CRITICAL: Respond with this exact format:

VERDICT: [PASS or FAIL]

[If FAIL, list each issue:]

ISSUE: [one-line description]
SEVERITY: [BLOCKING or WARNING]
LOCATION: [file:line or file1+file2]
DETAILS: [explanation of the cross-file issue]

[If PASS:]

No cross-file integration issues found.

Review diff:
\`\`\`diff
${DIFF}
\`\`\`"

  FULL_DIFF_OUTPUT=$(invoke_agent "adversarial-reviewer" "${FULL_DIFF_PROMPT}" "${FULL_DIFF_CACHE}" "${ADVERSARIAL_MODEL_ARGS[@]}") || true

  [[ -n "${FULL_DIFF_OUTPUT}" ]] || FULL_DIFF_OUTPUT="VERDICT: FAIL (agent error: invoke_agent produced no output)"

  # Before parse_verdict, as on the commit path: a BLOCKING finding the
  # reviewer could not have verified does not block the push (#455/#555/#488).
  FULL_DIFF_OUTPUT=$(downgrade_unverifiable_findings "${FULL_DIFF_OUTPUT}" "${REVIEWED_PATHS}")

  # FULL_DIFF_OUTPUT keeps the structured sentinel for the gate below;
  # the displayed and logged copy has it stripped.
  FULL_DIFF_DISPLAY=$(strip_structured_blocking "${FULL_DIFF_OUTPUT}")

  echo "=== FULL-DIFF REVIEW (adversarial-reviewer) ===" >&2
  echo "${FULL_DIFF_DISPLAY}" >&2
  echo "" >&2

  { printf '=== FULL-DIFF REVIEW ===\n%s\n' "${FULL_DIFF_DISPLAY}"; } >>"${REVIEW_LOG}" || true

  FULL_DIFF_VERDICT=$(parse_verdict "${FULL_DIFF_OUTPUT}")
  if [[ "${FULL_DIFF_VERDICT}" == "PASS" ]]; then
    printf 'full-diff: PASS\n' >>"${REVIEW_LOG}" || true
    log_success "Full-diff review passed"
    exit 0
  elif [[ "${FULL_DIFF_VERDICT}" == "FAIL" || "${FULL_DIFF_VERDICT}" == "REVISE" ]]; then
    if output_blocks "${FULL_DIFF_OUTPUT}"; then
      printf 'full-diff: FAIL (blocking)\n' >>"${REVIEW_LOG}" || true
      log_error "Full-diff review found blocking cross-file issues"
      exit 1
    elif is_transient_verdict "${FULL_DIFF_OUTPUT}"; then
      # The only reviewer on this path did not run. The push is still let
      # through (transient failures are non-blocking, #444), but it is not a
      # review and must not be logged as "warnings only". #590 decided this
      # path stays non-blocking.
      _fd_reason=$(transient_reason "${FULL_DIFF_OUTPUT}")
      printf 'full-diff: INCOMPLETE (%s)\n' "${_fd_reason}" >>"${REVIEW_LOG}" || true
      log_warn "Full-diff review INCOMPLETE: adversarial-reviewer did not complete (${_fd_reason}) - this branch was NOT reviewed"
      log_warn "  Push allowed: transient reviewer failures are non-blocking. Re-run: git config review.timeout 300, then push again"
      exit 0
    else
      printf 'full-diff: FAIL (warnings only)\n' >>"${REVIEW_LOG}" || true
      log_warn "Full-diff review found warnings (non-blocking)"
      exit 0
    fi
  else
    log_error "Could not parse full-diff review verdict"
    describe_unparseable_verdict "${FULL_DIFF_OUTPUT}"
    log_error "Output was:"
    echo "${FULL_DIFF_DISPLAY}" | head -20 >&2
    printf 'full-diff: FAIL (unparseable)\n' >>"${REVIEW_LOG}" || true
    exit 1
  fi
fi

# --- Codebase mode (pre-push whole-codebase review with tool access) ---
if [[ "${REVIEW_MODE}" == "codebase" ]]; then
  log_info "Codebase review: analyzing diff with full codebase tool access"
  log_info "Diff size: ${DIFF_LINES} lines | Timeout: ${TIMEOUT_SECONDS}s"
  log_info "Model: ${ADVERSARIAL_MODEL}"
  printf 'model: %s\n' "${ADVERSARIAL_MODEL}" >>"${REVIEW_LOG}" || true

  CODEBASE_CACHE="${CACHE_DIR}/codebase-${DIFF_HASH}"

  # Check cache
  if [[ -f "${CODEBASE_CACHE}" ]]; then
    CACHED_VERDICT=$(head -1 "${CODEBASE_CACHE}")
    if [[ "${CACHED_VERDICT}" == "PASS" ]]; then
      log_success "Codebase review cached: identical diff previously passed"
      printf 'codebase: cached PASS\n' >>"${REVIEW_LOG}" || true
      exit 0
    fi
    rm -f "${CODEBASE_CACHE}"
  fi

  # Write diff to temp file so the agent can re-read it via Read tool
  DIFF_TMPFILE=$(mktemp "${TMPDIR:-/tmp}/codebase-review-diff.XXXXXX")
  printf '%s\n' "${DIFF}" >"${DIFF_TMPFILE}"

  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd -L)

  CODEBASE_PROMPT="You are performing a codebase-aware review of a feature branch diff.
You have full tool access: Read, Grep, Glob. Use them to explore the repository.

IMPORTANT: You are being invoked as a focused analysis tool with --no-session-persistence.
Do NOT output Protocol 0 environment check or any preamble.
Begin your response directly with the analysis, then end with the verdict.

Repository root: ${REPO_ROOT}
Diff file (re-readable): ${DIFF_TMPFILE}

REVIEW PROCEDURE:
1. Read the diff file at ${DIFF_TMPFILE} to identify what changed.
2. For each changed file, use Read to view the FULL file for surrounding context.
3. Follow imports and references ONE level out — check callers/callees of changed functions.
4. Look specifically for:
   a. Field/contract violations: renamed or removed fields still referenced elsewhere
   b. Data flow bugs: values passed to wrong parameters, type mismatches
   c. Date/timezone inconsistencies: mixing UTC and local, wrong format strings
   d. Dead UI elements: buttons/links pointing to removed routes or handlers
   e. Cache key mismatches: cache writes and reads using different key patterns
   f. Platform-specific gotchas: iOS/Android/web divergence without guards

CLASSIFICATION — two INDEPENDENT questions. Answer both.

1. WHEN did it originate?
   - INTRODUCED by this diff (new bug, new inconsistency), or
   - PRE-EXISTING (was there before this diff).

2. IS IT A DEFECT — would a maintainer change code because of it?
   Something is a defect when it produces a wrong result, a crash, a security
   hole, data loss, a silently skipped check, or a documented behavior the code
   does not deliver. Answering \"no\" here is the common case, and it is a
   complete answer. Say nothing further about it.

Only a defect can be reported at all:
- BLOCK: a DEFECT that is INTRODUCED by this diff. These BLOCK the push.
- NON_BLOCKING_ISSUE: a DEFECT that is PRE-EXISTING. Each one becomes a GitHub
  issue that a human must read, judge, and close by hand.

REPORT NOTHING ELSE. There is no third channel — no FYI, no note for the next
reader, no \"worth verifying\", no \"consider\". If it is not a defect, it does
not go in your output in any form.

DO NOT FILE (this list is where most bad findings come from):
- Anything you would introduce with \"worth noting\", \"worth verifying\",
  \"consider\", \"may want to\", \"for the next person\", or \"no code change
  required\". If that phrasing fits, you have already decided it is not a
  defect. Stop.
- Style, naming, formatting, comment wording, or test-coverage suggestions for
  code that behaves correctly.
- A gap the file's own comments already document as known and accepted.
- Code that works but that you would have written differently.
- A concern you reasoned about and resolved. If your own analysis ends in \"this
  is fine\", \"no defect\", or \"the export covers it\", the finding is finished
  and unfiled. Do not file the reasoning.
- Platform or runtime behavior you cannot check and have no specific reason to
  doubt.

BEFORE EMITTING EACH NON_BLOCKING_ISSUE, CHECK YOURSELF:
Does the DETAILS text end by conceding the thing is fine? If so, delete the
whole block. Measured over 18 filed issues from this reviewer, about half
described no defect, and a third of those said so in their own text while
being filed anyway — every one cost a human a read and a manual close.
Filing nothing is a good outcome and the expected one for a clean diff. An
empty findings list is a successful review, not a lazy one.

CRITICAL: Respond with this exact format:

If there are BLOCKING issues:

VERDICT: FAIL

ISSUE: <one-line title>
SEVERITY: BLOCKING
LOCATION: <file:line>
DETAILS: <explanation of the bug and how to fix it>

If there are NO blocking issues (with optional non-blocking issues):

VERDICT: PASS

No blocking issues found.

NON_BLOCKING_ISSUE:
TITLE: <one-line title>
SOURCE: pre-push whole-codebase review
LOCATION: <file:line>
DETAILS: <explanation of the pre-existing issue>
VERIFIED: <optional; see VERIFIABLE CLAIMS below>
END_ISSUE

VERIFIABLE CLAIMS (mandatory):
YOUR ONLY TOOLS ARE Read, Grep, AND Glob. You cannot run commands. You have no
shell, no Bash, no gh, no test runner. Nothing you write in a VERIFIED: field
was executed, and you must never imply otherwise.

This splits every factual claim into two kinds, and they have DIFFERENT rules.

KIND A — claims about repository contents. What a file contains, whether a
symbol is defined, whether a name is referenced anywhere else, what a config
value is set to. Read/Grep/Glob settle these. For a Kind A claim you must
actually open the file or run the search before asserting it, and record what
you looked at in a VERIFIED: field. Example:
  VERIFIED: Grep \"REVIEW_MAX_LINES=\" hooks/run-review.sh -> line 81, default 1000
Cite the tool and what it returned, not a command you did not run.

KIND B — claims about how a tool, shell construct, or runtime BEHAVES. \"printf
appends another newline here\", \"$() keeps the trailing newline\", \"argv[1] is
the script path\", \"if: failure() only covers the previous step\", \"grep -w
splits on /\", \"this flag does not exist\", \"an empty object passes\". You
CANNOT check any of these. Reading the source that calls a tool tells you what
the code does, never what the tool does with it.

FOR EVERY KIND B CLAIM, THE SOFTENED FORM IS MANDATORY, NOT A FALLBACK.
Phrase it as a question and say what would settle it. Write:
  \"does printf re-add a trailing newline here — worth checking whether $()
   already stripped it?\"
NOT:
  \"printf appends another newline, producing a blank line between blocks.\"
Both sentences point at the same line of code. Only the first is honest about
what you actually know. A Kind B claim stated as fact is wrong even when the
underlying suspicion is right, because you are reporting a guess as a
measurement — and a human then spends a command disproving it.

A Kind B claim is not rescued by confidence, by how standard the behavior
seems, or by how much surrounding code you read. If your finding's core
assertion is about runtime behavior, it goes in question form. No exceptions.

Never assert a checkable fact you did not check. Findings that assert
incorrectness with no VERIFIED: field are filed with an \"unverified\" label
and a warning banner, because past unverified assertions of exactly this
shape turned out to be false and cost a human real time to disprove.
VERIFIED: is optional and should be omitted entirely when the finding makes
no factual claim about external state (style, structure, maintainability)."

  log_info "Running codebase reviewer with tool access..."
  codebase_start=$(date +%s)

  codebase_exit=0
  # Invoke WITHOUT --tools "" so agent gets default tool access (Read, Grep, Glob).
  # --allowedTools restricts to safe read-only tools only.
  # stderr is routed to its own temp file rather than merged via 2>&1: CLI
  # upgrade notices / deprecation warnings on stderr would otherwise land in
  # CODEBASE_OUTPUT and could corrupt the `grep -q "VERDICT:"` parsing below.
  # Matches the pattern used for the parallel code-reviewer/adversarial
  # invocations (_cr_out/_ar_out). Issue #89.
  _codebase_err=$(mktemp)
  #
  # --output-format json + --json-schema, as in invoke_agent (claude-config#443).
  # Tool use and structured output compose: the reviewer reads files across
  # several turns, then emits the conforming object at the end.
  CODEBASE_OUTPUT=$(echo "${CODEBASE_PROMPT}" | timeout "${TIMEOUT_SECONDS}" env -u CLAUDECODE "${CLAUDE_CLI}" --agent "adversarial-reviewer" -p "${ADVERSARIAL_MODEL_ARGS[@]}" --output-format json --json-schema "${REVIEW_JSON_SCHEMA}" --allowedTools "Read,Grep,Glob" --no-session-persistence 2>"${_codebase_err}") || codebase_exit=$?
  if [[ -s "${_codebase_err}" ]]; then
    cat "${_codebase_err}" >&2
  fi
  rm -f "${_codebase_err}"
  unset _codebase_err

  codebase_end=$(date +%s)
  codebase_elapsed=$((codebase_end - codebase_start))
  log_info "Codebase review completed in ${codebase_elapsed}s"

  # Clean up temp file
  rm -f "${DIFF_TMPFILE}"

  # Handle timeout
  if [[ ${codebase_exit} -eq 124 ]]; then
    log_error "Codebase review timed out after ${TIMEOUT_SECONDS}s"
    log_error "BLOCKING: Review timeout means review did not complete."
    log_error "Increase timeout: git config review.codebaseTimeout 600"
    printf 'codebase: FAIL (timeout)\n' >>"${REVIEW_LOG}" || true
    exit 1
  fi

  # Handle other CLI errors
  if [[ ${codebase_exit} -ne 0 ]]; then
    log_error "Codebase reviewer exited with error code ${codebase_exit}"
  fi

  # Unwrap the JSON envelope. CODEBASE_OUTPUT keeps the structured sentinel so
  # the gate below can read the boolean; CODEBASE_DISPLAY is the same text with
  # the sentinel stripped, and is what reaches the terminal, the log, and
  # issue filing — the machinery marker is not something a human should see.
  CODEBASE_OUTPUT=$(normalize_agent_response "${CODEBASE_OUTPUT}")

  [[ -n "${CODEBASE_OUTPUT}" ]] || CODEBASE_OUTPUT="VERDICT: FAIL (agent error: invoke produced no output)"

  CODEBASE_DISPLAY=$(strip_structured_blocking "${CODEBASE_OUTPUT}")

  echo "=== CODEBASE REVIEW ===" >&2
  echo "${CODEBASE_DISPLAY}" >&2

  # Parse verdict and handle results
  CODEBASE_VERDICT=$(parse_verdict "${CODEBASE_OUTPUT}")
  if [[ "${CODEBASE_VERDICT}" == "PASS" ]]; then
    echo "PASS" >"${CODEBASE_CACHE}"
    printf 'codebase: PASS\n' >>"${REVIEW_LOG}" || true
    log_success "Codebase review passed"

    # Extract and file non-blocking issues (best-effort, never blocks)
    if echo "${CODEBASE_DISPLAY}" | grep -q "NON_BLOCKING_ISSUE:"; then
      log_info "Filing non-blocking issues found during codebase review..."
      create_nonblocking_issues "${CODEBASE_DISPLAY}" || true
    fi

    exit 0
  elif [[ "${CODEBASE_VERDICT}" == "FAIL" || "${CODEBASE_VERDICT}" == "REVISE" ]]; then
    if output_blocks "${CODEBASE_OUTPUT}"; then
      printf 'codebase: FAIL (blocking)\n' >>"${REVIEW_LOG}" || true
      log_error "Codebase review found blocking issues"
      exit 1
    else
      printf 'codebase: FAIL (warnings only)\n' >>"${REVIEW_LOG}" || true
      log_warn "Codebase review found warnings (non-blocking)"
      exit 0
    fi
  else
    log_error "Could not parse codebase review verdict"
    describe_unparseable_verdict "${CODEBASE_OUTPUT}"
    log_error "Output was:"
    echo "${CODEBASE_DISPLAY}" | head -20 >&2
    printf 'codebase: FAIL (unparseable)\n' >>"${REVIEW_LOG}" || true
    exit 1
  fi
fi

# --- Agent-Based Review Flow ---
# Both code-reviewer and adversarial-reviewer run on every commit regardless
# of content. The prior detect_security_critical heuristic (~90 lines of
# regex patterns matching paths/content/extensions) was removed because its
# only consumer was a single log_info — it never changed reviewer behavior,
# prompt content, or cache policy. If differentiated scrutiny is ever
# needed, wire it with intent (different prompt, different timeout, or
# separate cache bucket) instead of resurrecting the dead heuristic.

# Build cache keys
CODE_REVIEWER_CACHE="${CACHE_DIR}/code-reviewer-${DIFF_HASH}"
ROUND_HISTORY_KEY=$(round_history_key "${CHANGED_FILES}")
ROUND_HISTORY_FILE=""
if [[ -n "${ROUND_HISTORY_KEY}" && "${ROUND_HISTORY_KEY}" != "noround" ]]; then
  ROUND_HISTORY_FILE="${CACHE_DIR}/round-history-${ROUND_HISTORY_KEY}"
else
  log_warn "Could not compute round-history key; this run's review will not carry prior-round feedback"
fi

# adversarial-reviewer's cache is deliberately bypassed during a retry after a
# prior FAIL on this branch/file-set (i.e. ROUND_HISTORY_FILE has content).
# The arbiter (below) treats an adversarial PASS as evidence that
# code-reviewer's current BLOCKING claim doesn't hold up -- but a cache hit
# means adversarial-reviewer never actually looked at *this* code-reviewer
# FAIL; it only proves some earlier attempt at this diff passed adversarial
# review, possibly before code-reviewer's current objection even existed.
# Live-only here forces a fresh, substantive check exactly when arbitration
# is most likely to be invoked. dev-env#35 / claude-config#246: a stale
# cached PASS was silently reused across retries and misled the arbiter,
# which noticed the cache was stale but sided with a fabricated
# code-reviewer claim anyway rather than treating "no fresh evidence" as a
# reason to force a live check.
_prior_round_feedback_present=""
[[ -n "${ROUND_HISTORY_FILE}" ]] && _prior_round_feedback_present=$(read_round_feedback "${ROUND_HISTORY_FILE}")
if [[ -n "${_prior_round_feedback_present}" ]]; then
  log_info "Retry after a prior FAIL on this branch/file-set -- forcing a live adversarial-reviewer check (bypassing cache)"
  ADVERSARIAL_CACHE="" # empty = invoke_agent always runs live, never caches
else
  ADVERSARIAL_CACHE="${CACHE_DIR}/adversarial-${DIFF_HASH}"
fi
unset _prior_round_feedback_present

# Build structured prompt for agents
# Use string concatenation - safe variable expansion without command execution
#
# File-header context: give the reviewer each changed file's stated scope
# (e.g. "macOS-only, not intended for Linux/CI") even when that line isn't
# part of the diff hunk itself. Diff-only prompts can't see this — dev-env#35.
FILE_CONTEXT_SECTION=""
if [[ -n "${CHANGED_FILES}" ]]; then
  while IFS= read -r _cf; do
    [[ -z "${_cf}" ]] && continue
    _cf_header=$(extract_file_header_context "${_cf}")
    [[ -n "${_cf_header}" ]] || continue
    FILE_CONTEXT_SECTION="${FILE_CONTEXT_SECTION}--- ${_cf} ---
${_cf_header}

"
  done <<<"${CHANGED_FILES}"
  if [[ -n "${FILE_CONTEXT_SECTION}" ]]; then
    FILE_CONTEXT_SECTION="FILE HEADER CONTEXT (stated scope/intent from each changed file's leading comments — weigh findings against this before flagging out-of-scope concerns):
${FILE_CONTEXT_SECTION}---

"
  fi
fi
unset _cf _cf_header

# Inject prior-round feedback from a failed review attempt on this branch/file-set.
# Each --no-session-persistence invocation starts from zero, so a FAILed round's
# findings were forgotten by the next retry. Track up to the last 2 rounds and
# inject them so retries build on prior findings instead of re-litigating.
PRIOR_ROUND_SECTION=""
if [[ -n "${ROUND_HISTORY_FILE}" ]]; then
  _prior_feedback=$(read_round_feedback "${ROUND_HISTORY_FILE}")
  if [[ -n "${_prior_feedback}" ]]; then
    if grep -qE "^VERDICT: (PASS|FAIL|REVISE)" <<<"${_prior_feedback}"; then
      PRIOR_ROUND_SECTION="PRIOR ROUND FEEDBACK (from up to 2 previous FAILed review attempts on this branch/file-set — do NOT re-flag an issue below unless it is still genuinely present in the current diff; do not propose a different remedy for something already addressed):
${_prior_feedback}
---

"
    else
      log_warn "Round-history file at ${ROUND_HISTORY_FILE} has no VERDICT line; discarding as invalid"
      clear_round_feedback "${ROUND_HISTORY_FILE}"
    fi
  fi
fi
unset _prior_feedback

# Inject the developer's commit message (when available) so the reviewer sees
# intent before code. Same pattern as the chunked path; section is omitted
# entirely when no message is available.
COMMIT_MSG=$(_read_commit_message)
if [[ -n "${COMMIT_MSG}" ]]; then
  COMMIT_MSG_SECTION="DEVELOPER INTENT (commit message):
${COMMIT_MSG}
---

"
else
  COMMIT_MSG_SECTION=""
fi

AGENT_PROMPT="${PRIOR_ROUND_SECTION}${FILE_CONTEXT_SECTION}${COMMIT_MSG_SECTION}You are performing a pre-commit code review. Analyze the diff below and identify issues BEFORE code is committed.

IMPORTANT: You are being invoked as a focused analysis tool with --no-session-persistence.
Do NOT output Protocol 0 environment check or any preamble.
Begin your response directly with the verdict in the specified format below.

Focus on:
1. Correctness: Logic errors, null handling, race conditions
2. Security: Hardcoded secrets, injection vulnerabilities, auth issues
3. Error Handling: Silent failures, missing error cases
4. Completeness: Edge cases, incomplete implementations
5. Comments: limited to what isn't obvious from the code — flag comments that only restate what the code already says. Report these as SEVERITY: FIX_NOW, never as BLOCKING.

${REVIEW_SEVERITY_RULES}

CRITICAL: Respond with this exact format:

VERDICT: [PASS or FAIL]

[If FAIL, list each issue:]
ISSUE: [one-line description]
SEVERITY: [BLOCKING, FIX_NOW, or WARNING]
LOCATION: [file:line]
DETAILS: [explanation and fix]

[If PASS:]
No blocking issues found.

Review this diff:

\`\`\`diff
${DIFF}
\`\`\`"

# Announce log path BEFORE any agent runs — this line IS visible in Claude Code's
# Bash tool even when subsequent output is swallowed by the nested claude process.
printf 'diff_lines: %d\n' "${DIFF_LINES}" >>"${REVIEW_LOG}" || true
log_info "Review log: ${REVIEW_LOG}"
if [[ -n "${REVIEW_MODEL}" ]]; then
  log_info "Model: ${REVIEW_MODEL}"
  printf 'model: %s\n' "${REVIEW_MODEL}" >>"${REVIEW_LOG}" || true
fi

# Run code-reviewer and adversarial-reviewer in parallel when both are
# available. Each reviewer's stdout is captured to its own temp file so
# the outputs don't interleave. stderr (log_info progress lines) flows
# through to the user's terminal — it may interleave between the two
# agents but remains readable because each log line is agent-prefixed.
#
# Parallelization roughly halves wall time on the common two-agent path
# (previously serial at 60-120s each; now both run concurrently).
#
# Serial fallback: when adversarial-reviewer isn't installed, only
# code-reviewer runs (unchanged from the prior serial behavior).

ADVERSARIAL_OUTPUT=""
ADVERSARIAL_VERDICT="N/A"
ADVERSARIAL_AVAILABLE=true
if ! _adversarial_reviewer_installed; then
  log_warn "adversarial-reviewer agent not found - skipping (see ~/.claude/docs/CUSTOM_AGENTS.md for setup)"
  ADVERSARIAL_AVAILABLE=false
fi

if [[ "${ADVERSARIAL_AVAILABLE}" == true ]]; then
  _cr_out=$(mktemp)
  _ar_out=$(mktemp)
  # Subshells inherit set -e. invoke_agent handles its own errors and always
  # echoes a verdict line (real output, or synthetic "VERDICT: FAIL (agent
  # error/timeout)"). `|| true` on the wait calls suppresses propagation of
  # the subshell's exit status; the same empty-output guard below handles
  # any silent failure.
  (invoke_agent "${CODE_REVIEWER_AGENT}" "${AGENT_PROMPT}" "${CODE_REVIEWER_CACHE}" "${CODE_REVIEWER_MODEL_ARGS[@]}" >"${_cr_out}") &
  _cr_pid=$!
  (invoke_agent "adversarial-reviewer" "${AGENT_PROMPT}" "${ADVERSARIAL_CACHE}" "${ADVERSARIAL_MODEL_ARGS[@]}" >"${_ar_out}") &
  _ar_pid=$!
  wait "${_cr_pid}" || true
  wait "${_ar_pid}" || true
  CODE_REVIEWER_OUTPUT=$(cat "${_cr_out}")
  ADVERSARIAL_OUTPUT=$(cat "${_ar_out}")
  rm -f "${_cr_out}" "${_ar_out}"
  unset _cr_out _ar_out _cr_pid _ar_pid
else
  # Serial path (no adversarial): only code-reviewer runs.
  CODE_REVIEWER_OUTPUT=$(invoke_agent "${CODE_REVIEWER_AGENT}" "${AGENT_PROMPT}" "${CODE_REVIEWER_CACHE}" "${CODE_REVIEWER_MODEL_ARGS[@]}") || true
fi

# Guard: invoke_agent may exit 0 but produce no output (silent agent failure).
# Normalise to a transient-error verdict so the non-blocking check below handles it.
[[ -n "${CODE_REVIEWER_OUTPUT}" ]] || CODE_REVIEWER_OUTPUT="VERDICT: FAIL (agent error: invoke_agent produced no output)"
if [[ "${ADVERSARIAL_AVAILABLE}" == true ]]; then
  [[ -n "${ADVERSARIAL_OUTPUT}" ]] || ADVERSARIAL_OUTPUT="VERDICT: FAIL (agent error: invoke_agent produced no output)"
fi

# Version-pin-unfamiliarity downgrade: rewrite qualifying BLOCKING findings
# to WARNING before verdict parsing, so a downgraded issue no longer flips
# the verdict to FAIL. Applied to both reviewers' raw output.
CODE_REVIEWER_OUTPUT=$(downgrade_version_unfamiliarity_findings "${CODE_REVIEWER_OUTPUT}")
if [[ "${ADVERSARIAL_AVAILABLE}" == true ]]; then
  ADVERSARIAL_OUTPUT=$(downgrade_version_unfamiliarity_findings "${ADVERSARIAL_OUTPUT}")
fi

# Unverifiable-claim downgrade (#455/#555/#488): same placement and contract.
# Runs before arbitration, so an external-behavior claim never reaches an
# arbiter that has no more ability to check it than the reviewer did.
CODE_REVIEWER_OUTPUT=$(downgrade_unverifiable_findings "${CODE_REVIEWER_OUTPUT}" "${REVIEWED_PATHS}")
if [[ "${ADVERSARIAL_AVAILABLE}" == true ]]; then
  ADVERSARIAL_OUTPUT=$(downgrade_unverifiable_findings "${ADVERSARIAL_OUTPUT}" "${REVIEWED_PATHS}")
fi

# The *_OUTPUT vars carry the structured-decision sentinel (claude-config#443)
# and are what the gates read. The *_DISPLAY copies have it stripped and are
# what reaches a human, the review log, round-history feedback, the arbiter's
# prompt, and the disagreement issue — none of which should ever see the
# marker, and one of which (the arbiter prompt) would otherwise be handed
# another agent's raw decision channel as if it were review prose.
CODE_REVIEWER_DISPLAY=$(strip_structured_blocking "${CODE_REVIEWER_OUTPUT}")
ADVERSARIAL_DISPLAY=$(strip_structured_blocking "${ADVERSARIAL_OUTPUT}")

# Parse verdict from code-reviewer output
CODE_REVIEWER_VERDICT=$(parse_verdict "${CODE_REVIEWER_OUTPUT}")
if [[ "${CODE_REVIEWER_VERDICT}" == "PASS" ]]; then
  : # already PASS
elif [[ "${CODE_REVIEWER_VERDICT}" == "FAIL" || "${CODE_REVIEWER_VERDICT}" == "REVISE" ]]; then
  CODE_REVIEWER_VERDICT="FAIL" # normalize REVISE -> FAIL for downstream contract
else
  log_error "Could not parse code-reviewer verdict"
  describe_unparseable_verdict "${CODE_REVIEWER_OUTPUT}"
  log_error "BLOCKING: Cannot verify review result"
  log_error ""
  log_error "Output was:"
  echo "${CODE_REVIEWER_DISPLAY}" | head -20 >&2
  exit 1
fi

# Parse verdict from adversarial-reviewer output (when available)
if [[ "${ADVERSARIAL_AVAILABLE}" == true ]]; then
  ADVERSARIAL_VERDICT=$(parse_verdict "${ADVERSARIAL_OUTPUT}")
  if [[ "${ADVERSARIAL_VERDICT}" == "PASS" ]]; then
    : # already PASS
  elif [[ "${ADVERSARIAL_VERDICT}" == "FAIL" || "${ADVERSARIAL_VERDICT}" == "REVISE" ]]; then
    ADVERSARIAL_VERDICT="FAIL" # normalize REVISE -> FAIL for downstream contract
  else
    log_error "Could not parse adversarial-reviewer verdict"
    describe_unparseable_verdict "${ADVERSARIAL_OUTPUT}"
    log_error "BLOCKING: Cannot verify adversarial review result"
    log_error ""
    log_error "Output was:"
    echo "${ADVERSARIAL_DISPLAY}" | head -20 >&2
    exit 1
  fi
fi

# A reviewer that timed out or errored did not review the diff (#590). Its
# synthetic "VERDICT: FAIL (timeout)" is not a finding: it is kept out of the
# round history, never reported as a pass, and logged as INCOMPLETE. Asked
# only after output_blocks(), so a real BLOCKING review is never relabelled.
CODE_REVIEWER_INCOMPLETE=false
CODE_REVIEWER_INCOMPLETE_REASON=""
if [[ "${CODE_REVIEWER_VERDICT}" == "FAIL" ]] \
  && ! output_blocks "${CODE_REVIEWER_OUTPUT}" \
  && is_transient_verdict "${CODE_REVIEWER_OUTPUT}"; then
  CODE_REVIEWER_INCOMPLETE=true
  CODE_REVIEWER_INCOMPLETE_REASON=$(transient_reason "${CODE_REVIEWER_OUTPUT}")
fi
ADVERSARIAL_INCOMPLETE=false
if [[ "${ADVERSARIAL_VERDICT}" == "FAIL" ]] \
  && ! output_blocks "${ADVERSARIAL_OUTPUT}" \
  && is_transient_verdict "${ADVERSARIAL_OUTPUT}"; then
  ADVERSARIAL_INCOMPLETE=true
fi

if [[ -n "${ROUND_HISTORY_FILE}" && "${CODE_REVIEWER_INCOMPLETE}" != true ]]; then
  if [[ "${CODE_REVIEWER_VERDICT}" == "PASS" ]]; then
    clear_round_feedback "${ROUND_HISTORY_FILE}"
  else
    write_round_feedback "${ROUND_HISTORY_FILE}" "${CODE_REVIEWER_DISPLAY}"
  fi
fi

# --- Evaluate Combined Verdict ---
echo "" >&2

# Show code-reviewer output; also write to log (best-effort: || true guards set -e)
echo "=== CODE REVIEWER ===" >&2
echo "${CODE_REVIEWER_DISPLAY}" >&2
echo "" >&2
{ printf '=== CODE REVIEWER ===\n%s\n' "${CODE_REVIEWER_DISPLAY}"; } >>"${REVIEW_LOG}" || true

# Show adversarial-reviewer output if ran
if [[ -n "${ADVERSARIAL_OUTPUT}" ]]; then
  echo "=== ADVERSARIAL REVIEWER ===" >&2
  echo "${ADVERSARIAL_DISPLAY}" >&2
  echo "" >&2
  { printf '=== ADVERSARIAL REVIEWER ===\n%s\n' "${ADVERSARIAL_DISPLAY}"; } >>"${REVIEW_LOG}" || true
fi

# --- FIX_NOW (claude-config#443 phase 2, design item 2) ---
#
# Commit stage ONLY. This is the cheapest moment to apply a mechanical fix, and
# early enough that full-diff and CI never see the finding. Advisory: it does
# not touch the exit status below, and there is no filing call anywhere on this
# path - a FIX_NOW finding never becomes a GitHub issue by any route.
#
# Both reviewers' entries are pooled, then capped as one list, so the cap is a
# per-commit budget rather than a per-reviewer one.
_FIX_NOW_ENTRIES=$(
  {
    read_fix_now "${CODE_REVIEWER_OUTPUT}"
    [[ -z "${ADVERSARIAL_OUTPUT}" ]] || read_fix_now "${ADVERSARIAL_OUTPUT}"
  } | grep -v '^$' || true
)
emit_fix_now_entries "${_FIX_NOW_ENTRIES}" || true

# Write verdict summary before exit — EXIT trap appends exit_code
# A reviewer that did not complete is logged as such, not as FAIL: #590's log
# read "code-reviewer: FAIL ... exit_code: 0", which says neither what
# happened nor why the commit went through. The adversarial wording matches
# the chunked path's.
{
  if [[ "${CODE_REVIEWER_INCOMPLETE}" == true ]]; then
    printf 'code-reviewer: INCOMPLETE (%s)\n' "${CODE_REVIEWER_INCOMPLETE_REASON}"
  else
    printf 'code-reviewer: %s\n' "${CODE_REVIEWER_VERDICT}"
  fi
  if [[ "${ADVERSARIAL_INCOMPLETE}" == true ]]; then
    printf 'adversarial-reviewer: skipped (timeout or agent error)\n'
  else
    printf 'adversarial-reviewer: %s\n' "${ADVERSARIAL_VERDICT}"
  fi
} >>"${REVIEW_LOG}" || true

# Determine final result
if [[ "${CODE_REVIEWER_VERDICT}" == "FAIL" ]]; then
  # Check if the reviewer's finding blocks. Structured boolean when it
  # answered; #442's prose matcher when it did not (see output_blocks).
  if output_blocks "${CODE_REVIEWER_OUTPUT}"; then
    # Reconciliation: if adversarial-reviewer (already a bigger model,
    # already reasoning about failure modes) independently reached PASS,
    # don't take code-reviewer's BLOCKING FAIL as final — ask a third
    # agent to arbitrate rather than silently trusting either side.
    # dev-env#35: non-convergent Haiku findings that adversarial-reviewer
    # explicitly called "solid design choices" on the same diff.
    if [[ "${ADVERSARIAL_AVAILABLE}" == true && "${ADVERSARIAL_VERDICT}" == "PASS" ]]; then
      log_warn "code-reviewer BLOCKING FAIL disagrees with adversarial-reviewer PASS — arbitrating"

      ARBITER_PROMPT="Two reviewers disagree on whether this diff is safe to commit. Read both verdicts and the diff, then decide which reviewer is correct.

IMPORTANT: You are being invoked as a focused analysis tool with --no-session-persistence.
Do NOT output Protocol 0 environment check or any preamble.
Begin your response directly with the verdict in the specified format below.

=== CODE-REVIEWER VERDICT (found a BLOCKING issue) ===
${CODE_REVIEWER_DISPLAY}

=== ADVERSARIAL-REVIEWER VERDICT (found no blocking issue) ===
${ADVERSARIAL_DISPLAY}

=== DIFF UNDER REVIEW ===
\`\`\`diff
${DIFF}
\`\`\`

Decide: is code-reviewer's BLOCKING finding a genuine, currently-present issue in this diff, or is adversarial-reviewer correct that it doesn't apply (e.g. out of stated scope, already mitigated, a false positive)?

${REVIEW_SEVERITY_RULES}

You are ruling on ONE question: does the disputed finding meet the BLOCKING bar
above? If it is real but does not meet that bar — including anything that is
merely FIX_NOW-shaped or a style preference — the correct ruling is PASS. Do
not introduce new findings of your own; you are arbitrating, not reviewing.

CRITICAL: Respond with this exact format:

VERDICT: [PASS or FAIL]

[Explain which reviewer is correct and why, in 2-4 sentences.]

[If VERDICT: FAIL, restate the still-blocking issue:]
ISSUE: [one-line description]
SEVERITY: BLOCKING
LOCATION: [file:line]
DETAILS: [explanation and fix]"

      ARBITER_CACHE="${CACHE_DIR}/arbiter-${DIFF_HASH}"
      ARBITER_OUTPUT=$(invoke_agent "adversarial-reviewer" "${ARBITER_PROMPT}" "${ARBITER_CACHE}" "${ARBITER_MODEL_ARGS[@]}") || true
      [[ -n "${ARBITER_OUTPUT}" ]] || ARBITER_OUTPUT="VERDICT: FAIL (agent error: invoke_agent produced no output)"

      # The arbiter's ruling is read from its VERDICT line, not from a
      # severity gate, so its structured sentinel has no consumer — strip it
      # everywhere. The disagreement issue is read by a human.
      ARBITER_OUTPUT=$(strip_structured_blocking "${ARBITER_OUTPUT}")

      echo "=== ARBITER (reconciling code-reviewer vs adversarial-reviewer) ===" >&2
      echo "${ARBITER_OUTPUT}" >&2
      echo "" >&2
      { printf '=== ARBITER ===\n%s\n' "${ARBITER_OUTPUT}"; } >>"${REVIEW_LOG}" || true

      ARBITER_VERDICT=$(parse_verdict "${ARBITER_OUTPUT}")
      [[ -n "${ARBITER_VERDICT}" ]] || ARBITER_VERDICT="FAIL"
      printf 'arbiter: %s\n' "${ARBITER_VERDICT}" >>"${REVIEW_LOG}" || true

      file_reviewer_disagreement_issue "${CODE_REVIEWER_DISPLAY}" "${ADVERSARIAL_DISPLAY}" "${ARBITER_OUTPUT}" "${ARBITER_VERDICT}"

      if [[ "${ARBITER_VERDICT}" == "PASS" ]]; then
        log_success "Arbiter sided with adversarial-reviewer — commit allowed"
        # write_round_feedback already persisted code-reviewer's FAIL output
        # before this block ran (it only sees CODE_REVIEWER_VERDICT, not the
        # arbiter's later ruling). The arbiter just determined that FAIL was
        # a false positive, so clear it -- otherwise it survives into the
        # next commit's PRIOR ROUND FEEDBACK as an already-resolved finding.
        [[ -n "${ROUND_HISTORY_FILE}" ]] && clear_round_feedback "${ROUND_HISTORY_FILE}"
      else
        log_error "Arbiter sided with code-reviewer - commit rejected"
        exit 1
      fi
    else
      log_error "code-reviewer found blocking issues - commit rejected"
      exit 1
    fi
  elif [[ "${CODE_REVIEWER_INCOMPLETE}" == true ]]; then
    # Not a finding (nothing is filed, #172), but the commit was not
    # reviewed, so it is blocked below, after the adversarial gate has had
    # its say (#590).
    log_error "code-reviewer did NOT complete (${CODE_REVIEWER_INCOMPLETE_REASON}) - it did NOT review this commit"
  else
    log_warn "code-reviewer found warnings (non-blocking)"
    # Continue to adversarial if security-critical
  fi
fi

if [[ "${ADVERSARIAL_VERDICT}" == "FAIL" ]]; then
  # Transient infrastructure failures (timeout, CLI crash) produce "VERDICT: FAIL (timeout)"
  # or "VERDICT: FAIL (agent error: N)" with no SEVERITY: BLOCKING — treat as non-blocking,
  # consistent with how code-reviewer handles the same case. Also matches a
  # "Revise (...)" form in case a future synthetic transient error is ever
  # phrased that way instead of "FAIL (...)" (#172).
  #
  # ADVERSARIAL_INCOMPLETE is set only when output_blocks() said no, so a real
  # BLOCKING review that happens to quote a synthetic verdict still blocks.
  if [[ "${ADVERSARIAL_INCOMPLETE}" == true ]]; then
    log_warn "adversarial-reviewer timed out or errored - it did NOT review this commit (non-blocking)"
  elif output_blocks "${ADVERSARIAL_OUTPUT}"; then
    # Symmetric with the code-reviewer gate above: only a BLOCKING severity
    # rejects the commit. A warnings-only FAIL is logged but non-blocking.
    # Issue #199.
    log_error "adversarial-reviewer found issues - commit rejected"
    log_error "Note: code-reviewer passed but adversarial-reviewer caught additional concerns"
    exit 1
  else
    log_warn "adversarial-reviewer found warnings (non-blocking)"
  fi
fi

# Defensive: block on any unexpected verdict values
# (code-reviewer parsing already exits 1 on failure, so this should never trigger)
if [[ "${CODE_REVIEWER_VERDICT}" != "PASS" && "${CODE_REVIEWER_VERDICT}" != "FAIL" ]]; then
  log_error "Unexpected code-reviewer verdict: ${CODE_REVIEWER_VERDICT}"
  exit 1
fi
if [[ "${ADVERSARIAL_VERDICT}" != "PASS" && "${ADVERSARIAL_VERDICT}" != "FAIL" && "${ADVERSARIAL_VERDICT}" != "N/A" ]]; then
  log_error "Unexpected adversarial-reviewer verdict: ${ADVERSARIAL_VERDICT}"
  exit 1
fi

# A code-reviewer that timed out or errored did not review the commit, so the
# commit is blocked as INCOMPLETE (#590), as the chunked path blocks the same
# failure (#451). Checked last so a real adversarial BLOCKING finding is
# reported as such first. An adversarial-reviewer that did not complete is
# still allowed through ("code-reviewer only" below).
if [[ "${CODE_REVIEWER_INCOMPLETE}" == true ]]; then
  if [[ "${ADVERSARIAL_VERDICT}" == "N/A" || "${ADVERSARIAL_INCOMPLETE}" == true ]]; then
    log_error "Review INCOMPLETE: no reviewer completed - this commit was NOT reviewed - commit rejected"
  else
    log_error "Review INCOMPLETE: code-reviewer did not complete (adversarial-reviewer alone is not a review) - commit rejected"
  fi
  log_error "  Retry with a longer timeout: git -c review.timeout=300 commit ..."
  log_error "  Human bypass (not for agents): git commit --no-verify - see ~/.claude/docs/HUMAN-BYPASS.md"
  printf 'review: INCOMPLETE (code-reviewer did not complete)\n' >>"${REVIEW_LOG}" || true
  exit 1
fi

# Nothing blocked. Say "passed" only for a reviewer that actually reviewed the
# commit (#590). The adversarial wording matches the chunked path's
# "code-reviewer only".
if [[ "${ADVERSARIAL_INCOMPLETE}" == true ]]; then
  log_success "Review passed (code-reviewer only; adversarial-reviewer did not complete)"
elif [[ "${ADVERSARIAL_VERDICT}" != "N/A" ]]; then
  log_success "Review passed (code-reviewer + adversarial-reviewer)"
else
  log_success "Review passed (code-reviewer)"
fi
_review_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ || true)
# Overwrite the start timestamp (first line) with the completion timestamp so that
# `head -1 ~/.claude/last-review-result.log` reflects when the review FINISHED,
# not when it started. For slow reviews (>60s), this prevents false staleness alerts.
{
  printf '%s\n' "${_review_ts}"
  tail -n +2 "${REVIEW_LOG}"
} >"${REVIEW_LOG}.tmp" \
  && mv "${REVIEW_LOG}.tmp" "${REVIEW_LOG}" || true
# Also update the global pointer's timestamp to match the completion time.
# Controllers checking head -1 ~/.claude/last-review-result.log need the
# completion time (not start time) for the staleness check to be accurate.
# Write all fields from current session variables (not tail -n +2 of the
# existing file) to avoid a read-modify-write race with concurrent sessions.
{
  printf '%s\n' "${_review_ts}"
  printf 'repo: %s\n' "${_review_repo}"
  printf 'branch: %s\n' "${_review_branch}"
  printf 'commit: %s\n' "${_review_commit}"
  printf 'log: %s\n' "${REVIEW_LOG}"
} >"${_global_log}.tmp" \
  && mv "${_global_log}.tmp" "${_global_log}" || true
log_success "Review timestamp: ${_review_ts}  ← verify this matches commit time"
exit 0
