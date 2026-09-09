#!/usr/bin/env bash
set -euo pipefail
unset CDPATH

# =========================================================
# pre-merge-review.sh — Analyze PR reviews before merge
# =========================================================
#
# Called by gh() wrapper in functions.sh before `gh pr merge`
# Fetches PR review comments and analyzes for unresolved issues.
#
# USAGE:
#   Called automatically via gh wrapper, or directly:
#   ~/.claude/hooks/pre-merge-review.sh pr merge [PR_NUMBER] [flags]
#
# FEATURES:
#   - Filters out outdated and resolved inline comments
#   - Targeted diff extraction for large PRs:
#     * Small diffs (<= 1000 lines): Full diff included
#     * Large diffs (> 1000 lines): Extracts complete diff sections
#       for files with inline comments, summarizes others
#     * Ensures critical review context is always visible
#   - Honors `gh --repo OWNER/NAME` (and `-R`, `--repo=`, `-R=`) so the
#     caller can invoke `gh pr merge` from any directory. When --repo is
#     supplied, REPO_OWNER/REPO_NAME are parsed directly from the flag and
#     propagated to all downstream `gh pr view` / `gh pr diff` calls,
#     bypassing the CWD-dependent `gh repo view` resolution.
#
# EXIT CODES:
#   0 = Review passed (safe to merge)
#   1 = Review failed (unresolved issues or error)
#
# =========================================================

# --- Configuration ---
CLAUDE_CLI="${CLAUDE_CLI:-${HOME}/.local/bin/claude}"

# Analysis timeout policy.
#
# The time the model needs to render a verdict tracks the size of the prompt it
# is handed, and prompt size varies enormously between PRs — independently of
# anything knowable at startup. A flat constant is therefore the wrong shape:
# it is either too small for big diffs (an infrastructure timeout that presents
# as a merge-blocking review objection) or wastefully large for small ones.
#
# Note the failure is NOT confined to the >1000-line "smart diff" path, which
# an earlier version of this comment claimed. The observed timeout came from a
# 460-line PR taking the ordinary full-diff path: its prompt was 33,835 bytes,
# it timed out twice at 180s, and it completed comfortably at 420s.
#
# So the effective timeout is computed AFTER the prompt is assembled, from its
# actual byte size — see compute_effective_timeout() and its call site below.
# These constants calibrate that scaling:
#   - FLOOR is the previous flat default, retained for small prompts.
#   - PER_KB is set so the 33,835-byte data point yields 510s: comfortably
#     above the 420s that was observed to work, without being open-ended.
#   - CEILING bounds a pathological prompt so a wedged call cannot hang the
#     merge for the better part of an hour.
TIMEOUT_FLOOR_SECONDS=180
TIMEOUT_PER_KB_SECONDS=10
TIMEOUT_CEILING_SECONDS=900

# Explicit operator override. When `git config review.preMergeTimeout N` is set
# (repo-local or --global), that value is honored verbatim and scaling is
# skipped entirely — an operator who has named a number means that number.
# Unset (the normal case) means "scale with the prompt".
TIMEOUT_OVERRIDE=$(git config --get --type=int review.preMergeTimeout 2>/dev/null || echo "")

# Placeholder until the prompt exists; see compute_effective_timeout() below.
TIMEOUT_SECONDS="${TIMEOUT_FLOOR_SECONDS}"

# --- Colors ---
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Helpers ---
log_info() { echo -e "${BLUE}[pre-merge]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[pre-merge]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[pre-merge]${NC} $*" >&2; }
log_error() { echo -e "${RED}[pre-merge]${NC} $*" >&2; }

# --- Timeout Scaling ---

# Resolve the analysis timeout for a prompt of a given byte size.
#
# Sets TIMEOUT_SECONDS and logs which path was taken, so an operator reading
# the transcript can see why the analysis was given the budget it got.
#
# Args:
#   $1 - prompt size in bytes
compute_effective_timeout() {
  local prompt_size="$1"
  local prompt_kb scaled

  # Explicit override wins outright — no scaling, no clamping to the ceiling.
  if [[ -n "${TIMEOUT_OVERRIDE}" ]]; then
    TIMEOUT_SECONDS="${TIMEOUT_OVERRIDE}"
    log_info "Analysis timeout: ${TIMEOUT_SECONDS}s (explicit override from git config review.preMergeTimeout)"
    return 0
  fi

  # Integer division: sub-1KB prompts contribute nothing and land on the floor.
  prompt_kb=$((prompt_size / 1024))
  scaled=$((TIMEOUT_FLOOR_SECONDS + (prompt_kb * TIMEOUT_PER_KB_SECONDS)))

  if ((scaled > TIMEOUT_CEILING_SECONDS)); then
    scaled=${TIMEOUT_CEILING_SECONDS}
    TIMEOUT_SECONDS="${scaled}"
    log_info "Analysis timeout: ${TIMEOUT_SECONDS}s (scaled for ${prompt_kb}KB prompt, clamped to ${TIMEOUT_CEILING_SECONDS}s ceiling)"
    return 0
  fi

  TIMEOUT_SECONDS="${scaled}"
  log_info "Analysis timeout: ${TIMEOUT_SECONDS}s (scaled: ${TIMEOUT_FLOOR_SECONDS}s floor + ${prompt_kb}KB x ${TIMEOUT_PER_KB_SECONDS}s/KB)"
}

# --- File Classification Functions ---

# Classify file as data/config file
is_data_file() {
  local file="$1"
  # Match lock files, minified files, generated files, and JSON
  # Order specific patterns before wildcards to avoid redundancy
  case "${file}" in
    pnpm-lock.yaml | \
      *-lock.json | *.lock | \
      *.min.js | *.min.css | *.bundle.js | *.generated.* | \
      *.json)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Check if file has active inline comments
has_inline_comments() {
  local file="$1"
  echo "${COMMENTED_FILES}" | grep -qF "${file}"
}

# Extract diff section for a specific file
extract_file_diff() {
  local full_diff="$1"
  local target_file="$2"

  echo "${full_diff}" | awk -v file="${target_file}" '
    BEGIN { in_target = 0 }
    /^diff --git/ {
      in_target = 0
      # Extract b/ path which handles spaces correctly (POSIX-compatible)
      # Format: "diff --git a/path b/path"
      idx = index($0, " b/")
      if (idx > 0) {
        file_path = substr($0, idx + 3)
      }
      if (file_path == file) {
        in_target = 1
        print $0
      }
      next
    }
    in_target { print }
  '
}

# Get list of changed files from diff
get_changed_files() {
  local diff="$1"
  # Extract b/ path which handles spaces correctly
  echo "${diff}" | grep -E '^diff --git' | sed -E 's/^diff --git a\/.* b\/(.+)$/\1/'
}

# --- Diff Summarization Functions ---

# Summarize data file when CI passed
summarize_data_file() {
  local file_path="$1"
  local file_diff="$2"

  local added
  local removed
  added=$(echo "${file_diff}" | grep -c '^+[^+]' || echo "0")
  removed=$(echo "${file_diff}" | grep -c '^-[^-]' || echo "0")

  echo "diff --git a/${file_path} b/${file_path}"
  echo "--- CI validated data file (not shown) ---"
  echo "File: ${file_path}"
  echo "Changes: +${added} -${removed} lines"
  echo ""
}

# Truncate code file diff (first/last 50 lines)
truncate_code_diff() {
  local file_diff="$1"
  local total_lines
  total_lines=$(echo "${file_diff}" | wc -l)

  if [[ ${total_lines} -le 100 ]]; then
    echo "${file_diff}"
  else
    local header
    local footer
    local truncated
    header=$(echo "${file_diff}" | head -50)
    footer=$(echo "${file_diff}" | tail -50)
    truncated=$((total_lines - 100))

    echo "${header}"
    echo ""
    echo "... [${truncated} lines truncated - no review comments, CI passed] ..."
    echo ""
    echo "${footer}"
  fi
}

# --- Non-Blocking Issue Functions (shared library) ---
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-review-issues.sh
source "${_LIB_DIR}/lib-review-issues.sh"

# --- Preflight ---
if [[ ! -x "${CLAUDE_CLI}" ]]; then
  log_error "Claude CLI not found at: ${CLAUDE_CLI}"
  exit 1
fi

if ! command -v gh &>/dev/null; then
  log_error "gh CLI not found"
  exit 1
fi

# --- Parse arguments ---
# Expected forms (the wrappers pass the full original $@ through):
#   pr merge [PR_NUMBER] [--flags...]
#   -R owner/repo pr merge [PR_NUMBER] [--flags...]
#   --repo owner/repo pr merge [PR_NUMBER] [--flags...]
#   --repo=owner/repo pr merge [PR_NUMBER] [--flags...]
#
# We can't naively `shift 2` because global flags may precede `pr merge`.
# Walk the args once, skipping flags (and their separated values for the
# known two-token globals), and treat the third positional as PR_NUMBER.
# Also capture --repo / -R for downstream propagation.
PR_NUMBER=""
GH_REPO_OVERRIDE=""
_skip_next=0
_pending_capture=""
_positional_count=0
for arg in "$@"; do
  if [[ "${_skip_next}" == "1" ]]; then
    if [[ "${_pending_capture}" == "repo" ]]; then
      GH_REPO_OVERRIDE="${arg}"
    fi
    _pending_capture=""
    _skip_next=0
    continue
  fi
  case "${arg}" in
    -R | --repo)
      _skip_next=1
      _pending_capture=repo
      ;;
    --hostname | --config-dir | --token)
      _skip_next=1
      ;;
    --repo=*) GH_REPO_OVERRIDE="${arg#*=}" ;;
    -R=*) GH_REPO_OVERRIDE="${arg#*=}" ;;
    --*=* | -*) ;; # other flags: pass over (single-token; no value to skip)
    *)
      # Positional. Order: [pr] [merge] [PR_NUMBER]
      _positional_count=$((_positional_count + 1))
      if [[ ${_positional_count} -ge 3 && -z "${PR_NUMBER}" && "${arg}" =~ ^[0-9]+$ ]]; then
        PR_NUMBER="${arg}"
      fi
      ;;
  esac
done

# Build REPO_FLAG passthrough array for downstream gh calls.
# When empty, "${REPO_FLAG[@]}" expands to nothing under bash 5+ on macOS
# (the script's target platform), so call sites can spread it unconditionally.
REPO_FLAG=()
if [[ -n "${GH_REPO_OVERRIDE}" ]]; then
  REPO_FLAG=(--repo "${GH_REPO_OVERRIDE}")
fi

# --- Fetch PR data ---
# PR_NUMBER must be resolved (either parsed from args above, or fetched here
# from the API when the caller relies on branch tracking) BEFORE the merge-lock
# authorization check below: merge-lock.sh check "" is a usage error, not an
# "unauthorized" result, and would falsely block an already-authorized merge.
log_info "Fetching PR review data..."

PR_JSON_FIELDS="number,title,state,reviews,comments,reviewDecision,statusCheckRollup"
PR_JSON_FIELDS_FALLBACK="number,title,state,reviews,comments,reviewDecision"

# Fetch with statusCheckRollup first; fall back without it if the PAT lacks
# Checks permission (fine-grained PATs cannot access the Checks API).
_fetch_pr_json() {
  local -a pr_args=()
  [[ -n "${1:-}" ]] && pr_args+=("$1")
  local result gh_stderr
  # Use a temp file for stderr so gh debug output / upgrade notices / warnings
  # never contaminate the JSON captured on stdout. Previously `2>&1` merged
  # them, causing `jq: parse error: Invalid numeric literal` on any gh stderr.
  local stderr_file
  stderr_file=$(mktemp)
  for fields in "${PR_JSON_FIELDS}" "${PR_JSON_FIELDS_FALLBACK}"; do
    if result=$(command gh pr view "${pr_args[@]}" "${REPO_FLAG[@]}" --json "${fields}" 2>"${stderr_file}"); then
      rm -f "${stderr_file}"
      echo "${result}"
      return 0
    fi
    gh_stderr=$(<"${stderr_file}")
    if [[ "${fields}" == "${PR_JSON_FIELDS}" ]] && [[ "${gh_stderr}" == *"not accessible by personal access token"* ]]; then
      log_warn "statusCheckRollup not accessible — retrying without it"
      continue
    fi
    break
  done
  rm -f "${stderr_file}"
  log_error "Failed to fetch PR ${1:-for current branch}"
  log_error "${gh_stderr:-}"
  return 1
}

if [[ -n "${PR_NUMBER}" ]]; then
  PR_JSON=$(_fetch_pr_json "${PR_NUMBER}") || exit 1
else
  PR_JSON=$(_fetch_pr_json) || exit 1
  PR_NUMBER=$(echo "${PR_JSON}" | jq -r '.number')
fi

PR_TITLE=$(echo "${PR_JSON}" | jq -r '.title')
REVIEW_DECISION=$(echo "${PR_JSON}" | jq -r '.reviewDecision // "NONE"')

# Extract and format CI check status
STATUS_CHECKS=$(echo "${PR_JSON}" | jq -r '.statusCheckRollup // [] | if length == 0 then "No CI checks configured" else .[] | "- \(.name): \(.status) (\(.conclusion // "pending"))" end' 2>&1) || {
  log_warn "Could not parse status checks"
  STATUS_CHECKS="Status checks unavailable"
}

log_info "PR #${PR_NUMBER}: ${PR_TITLE}"
log_info "Review decision: ${REVIEW_DECISION}"

# --- Merge Authorization Lock (early check — before flag gate, before Claude CLI) ---
# Authorization is checked here, BEFORE the non-interactive flag gate and before
# running the expensive Claude analysis. Authorization is the more fundamental
# gate: if the human hasn't authorized the merge, telling them to add
# --squash --delete-branch first is not useful.
#
# Background: when pre-merge-review.sh spawns the claude CLI, the Claude Code
# Bash tool stops surfacing output in the tool result (a known interaction
# between nested claude processes and the Bash tool's PTY capture). By checking
# authorization first, a "not authorized" failure exits fast (in < 1s, before
# claude runs), so the error message is visible in the tool result.
#
# After the early check passes, the SAFE_TO_MERGE block at the bottom no longer
# needs to re-check (authorization is already verified for this session).
#
# Must run after PR_NUMBER is resolved above (either parsed from args or
# fetched from the API): merge-lock.sh check "" is a usage error, not an
# "unauthorized" result, and would falsely block an already-authorized merge
# for the branch-tracking invocation (no explicit PR number on the CLI).
#
# Resolve the repo first: merge locks are keyed on repo + PR number, so the
# check must name the repo this merge targets. With an explicit --repo we
# parse OWNER/NAME directly (no CWD-dependent `gh repo view`). Without one,
# `gh repo view` resolves from CWD. If neither yields a repo, the lock script
# refuses rather than falling back to a repo-less match.
if [[ -n "${GH_REPO_OVERRIDE}" ]]; then
  REPO_OWNER="${GH_REPO_OVERRIDE%/*}"
  REPO_NAME="${GH_REPO_OVERRIDE#*/}"
else
  REPO_OWNER=$(command gh repo view --json owner -q '.owner.login' 2>&1) || {
    log_warn "Could not determine repo owner"
    REPO_OWNER=""
  }
  REPO_NAME=$(command gh repo view --json name -q '.name' 2>&1) || {
    log_warn "Could not determine repo name"
    REPO_NAME=""
  }
fi

LOCK_REPO_FLAG=()
LOCK_REPO_HINT=""
if [[ -n "${REPO_OWNER}" && -n "${REPO_NAME}" ]]; then
  LOCK_REPO_FLAG=(--repo "${REPO_OWNER}/${REPO_NAME}")
  LOCK_REPO_HINT=" --repo ${REPO_OWNER}/${REPO_NAME}"
fi

MERGE_LOCK="${HOME}/.claude/hooks/merge-lock.sh"
if [[ -x "${MERGE_LOCK}" ]]; then
  if ! "${MERGE_LOCK}" check "${PR_NUMBER}" "${LOCK_REPO_FLAG[@]}" >/dev/null 2>&1; then
    echo "" >&2
    log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_error "MERGE AUTHORIZATION REQUIRED"
    log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "" >&2
    log_error "Merge requires human authorization before review runs."
    log_error ""
    log_error "To authorize (valid 30 min):"
    log_error "  ~/.claude/hooks/merge-lock.sh authorize ${PR_NUMBER} \"reason\"${LOCK_REPO_HINT}"
    log_error ""
    log_error "Then retry: gh pr merge ${PR_NUMBER}"
    echo "" >&2
    # Write to stdout as well: Bash tool surfaces stdout more reliably than
    # stderr for commands that complete quickly (before any claude invocation).
    printf '🛑 MERGE AUTHORIZATION REQUIRED: run ~/.claude/hooks/merge-lock.sh authorize %s "reason"%s then retry gh pr merge %s\n' "${PR_NUMBER}" "${LOCK_REPO_HINT}" "${PR_NUMBER}"
    exit 1
  fi
  log_success "Merge authorization verified for ${REPO_OWNER:-?}/${REPO_NAME:-?}#${PR_NUMBER}"
fi

# Track lock file path for dedup guard below (empty if merge-lock is not in use).
# Mirrors merge-lock.sh's layout: merge-locks/<owner>/<repo>/pr-<N>.lock
MERGE_LOCK_FILE="${HOME}/.claude/merge-locks/${REPO_OWNER:-unknown}/${REPO_NAME:-unknown}/pr-${PR_NUMBER}.lock"

# --- Non-interactive flag gate ---
# When invoked from Claude Code (CLAUDECODE set), require --squash and --delete-branch.
# Without them the actual merge step will fail, wasting a full analysis cycle.
# Runs after the merge-lock check above: authorization is the more fundamental
# gate, so an unauthorized merge fails on that message rather than this one.
if [[ -n "${CLAUDECODE:-}" ]]; then
  _has_squash=false
  _has_delete_branch=false
  for _arg in "$@"; do
    case "${_arg}" in
      --squash) _has_squash=true ;;
      --delete-branch) _has_delete_branch=true ;;
      *) ;;
    esac
  done
  if [[ "${_has_squash}" != "true" || "${_has_delete_branch}" != "true" ]]; then
    log_error "Non-interactive merge requires --squash and --delete-branch"
    log_error "Retry with: gh pr merge ${PR_NUMBER:-<PR>} --squash --delete-branch"
    exit 1
  fi
fi

# --- Hard block: CHANGES_REQUESTED review state (issue #27) ---
# Do NOT delegate review state enforcement to Claude. Claude can rationalize
# CHANGES_REQUESTED reviews as "nice-to-have" (issue #27, 2026-01-20).
# This check runs before Claude is invoked so failures are fast and visible.
#
# Primary check: GitHub's computed reviewDecision rollup.
if [[ "${REVIEW_DECISION}" == "CHANGES_REQUESTED" ]]; then
  echo "" >&2
  log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_error "MERGE BLOCKED: Unresolved 'Request Changes' review"
  log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "" >&2
  log_error "GitHub reviewDecision: CHANGES_REQUESTED"
  log_error ""
  log_error "At least one reviewer has requested changes that are not yet resolved."
  log_error "Resolve all requested changes and obtain reviewer approval before merging."
  printf '🛑 MERGE BLOCKED: reviewDecision is CHANGES_REQUESTED — resolve reviewer feedback before merging\n'
  exit 1
fi

# Belt-and-suspenders: scan individual reviews for CHANGES_REQUESTED state.
# Catches cases where reviewDecision rollup is absent (repos without required
# reviewers configured). Dismissed reviews have state DISMISSED, not
# CHANGES_REQUESTED, so this correctly excludes them.
#
# Important: use only the LATEST review per author. The `reviews` field
# contains all historical reviews; a reviewer who requested changes and later
# approved would still appear in the raw list. Group by author, sort by
# submittedAt (ascending), and take the last entry per author before filtering.
_CHANGES_REQUESTED=$(echo "${PR_JSON}" | jq -r '
  .reviews // []
  | group_by(.author.login // "unknown")
  | map(sort_by(.submittedAt // "") | last)
  | map(select(.state == "CHANGES_REQUESTED"))
  | map(.author.login // "unknown")
  | .[]' 2>/dev/null || true)

if [[ -n "${_CHANGES_REQUESTED}" ]]; then
  echo "" >&2
  log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_error "MERGE BLOCKED: Unresolved 'Request Changes' reviews"
  log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "" >&2
  log_error "Reviewers with unresolved CHANGES_REQUESTED:"
  while IFS= read -r _reviewer; do
    log_error "  - ${_reviewer}"
  done <<<"${_CHANGES_REQUESTED}"
  log_error ""
  log_error "Resolve all requested changes and obtain reviewer approval before merging."
  printf '🛑 MERGE BLOCKED: reviewers have requested changes — resolve feedback before merging\n'
  exit 1
fi

# --- Check for NEUTRAL CI status (blocking) ---
# Some checks set status to "neutral" when there are unresolved comments.
# This is a hard block - don't proceed to AI analysis.
#
# Exclusions (NEUTRAL on these is NOT a block):
# - "Pages changed" / "Header rules" / "Redirect rules" — Netlify informational
#   checks that return NEUTRAL when nothing changed. Informational only.
# - "Seer Code Review" (and any "Seer*" check) — Sentry's Seer reports findings
#   via NEUTRAL conclusion, but it runs on Sentry infrastructure (flaky/rate-
#   limited). Treated as non-blocking advisory: Seer's inline comments still
#   flow through to the AI analysis below via the inline comments fetcher,
#   so any findings are surfaced as advisory input — just not as a hard block.
NEUTRAL_CHECKS=$(echo "${PR_JSON}" | jq -r '
  .statusCheckRollup // []
  | .[]
  | select(
      .conclusion == "NEUTRAL"
      and (.name | startswith("Pages changed") | not)
      and (.name | startswith("Header rules") | not)
      and (.name | startswith("Redirect rules") | not)
      and (.name | startswith("Seer") | not)
    )
  | "- \(.name): \(.conclusion)"
' 2>&1) || true

if [[ -n "${NEUTRAL_CHECKS}" ]]; then
  # Reached only when a non-Netlify, non-Seer check is NEUTRAL. Seer is
  # explicitly excluded by the filter above (treated as advisory), so its
  # findings are never the trigger for this branch.
  echo "" >&2
  log_error "CI checks with NEUTRAL status (indicates unresolved issues):"
  echo "${NEUTRAL_CHECKS}" >&2
  echo "" >&2
  log_error "NEUTRAL status means the check found issues that need attention."
  log_error "Common causes:"
  log_error "  - Non-Seer review bots: Inline comments on code requiring resolution"
  log_error "  - Coverage / quality gates: Threshold not met (soft-failing as NEUTRAL)"
  log_error "  - Other reviewers: Requested changes not yet addressed"
  echo "" >&2
  log_error "Actions:"
  log_error "  1. View PR comments: gh pr view ${PR_NUMBER} --comments"
  log_error "  2. Check inline code comments on GitHub"
  log_error "  3. Address all review findings"
  log_error "  4. Push fixes and wait for checks to pass"
  echo "" >&2
  echo "   💡 TIP: If you've already resolved these issues and the comments are outdated," >&2
  echo "      add a new PR comment explaining what was fixed, then attempt the merge again." >&2
  echo "      The reviewer will see your update and re-analyze the current state." >&2
  echo "" >&2
  log_error "Merge blocked - resolve NEUTRAL checks first"
  exit 1
fi

# --- Fetch detailed review comments ---
# Get review threads which include inline comments
REVIEW_COMMENTS=$(command gh pr view "${PR_NUMBER}" "${REPO_FLAG[@]}" --comments 2>&1) || {
  log_warn "Could not fetch detailed comments, continuing with basic review data"
  REVIEW_COMMENTS=""
}

# --- Fetch inline review comments (where Sentry bot posts) ---
# These are comments on specific lines of code, separate from review summaries.
# REPO_OWNER / REPO_NAME were resolved above, before the merge-lock check.
INLINE_COMMENTS=""
if [[ -n "${REPO_OWNER}" && -n "${REPO_NAME}" ]]; then
  log_info "Fetching inline review comments (including bot comments)..."
  INLINE_COMMENTS=$(command gh api "repos/${REPO_OWNER}/${REPO_NAME}/pulls/${PR_NUMBER}/comments" 2>&1) || {
    log_warn "Could not fetch inline review comments"
    INLINE_COMMENTS=""
  }

  # Filter out outdated comments (code has changed since comment was made)
  if [[ -n "${INLINE_COMMENTS}" && "${INLINE_COMMENTS}" != "[]" ]]; then
    INLINE_COMMENTS_FILTERED=$(echo "${INLINE_COMMENTS}" | jq '[.[] | select(.outdated != true)]' 2>&1) || {
      log_warn "Could not filter outdated comments, using all comments"
      INLINE_COMMENTS_FILTERED="${INLINE_COMMENTS}"
    }
  else
    INLINE_COMMENTS_FILTERED="[]"
  fi

  # Fetch review thread resolution status via GraphQL
  log_info "Checking review thread resolution status..."
  GRAPHQL_QUERY=$(
    cat <<'GRAPHQL_EOF'
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(last: 100) {
        nodes {
          id
          isResolved
          comments(first: 1) {
            nodes {
              databaseId
            }
          }
        }
      }
    }
  }
}
GRAPHQL_EOF
  )

  REVIEW_THREADS=$(command gh api graphql -f query="${GRAPHQL_QUERY}" -f owner="${REPO_OWNER}" -f name="${REPO_NAME}" -F number="${PR_NUMBER}" 2>&1) || {
    log_warn "Could not fetch review thread resolution status"
    REVIEW_THREADS=""
  }

  # Build a list of resolved thread comment IDs
  RESOLVED_COMMENT_IDS=""
  if [[ -n "${REVIEW_THREADS}" ]]; then
    RESOLVED_COMMENT_IDS=$(echo "${REVIEW_THREADS}" | jq -r '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == true) | .comments.nodes[].databaseId' 2>&1) || {
      log_warn "Could not extract resolved comment IDs"
      RESOLVED_COMMENT_IDS=""
    }
  fi

  # Filter out comments from resolved threads
  if [[ "${INLINE_COMMENTS_FILTERED}" != "[]" ]]; then
    # Build array of resolved comment IDs
    if [[ -z "${RESOLVED_COMMENT_IDS}" ]]; then
      RESOLVED_IDS_ARRAY="[]"
    else
      RESOLVED_IDS_ARRAY=$(echo "${RESOLVED_COMMENT_IDS}" | jq -R -s 'split("\n") | map(select(length > 0) | tonumber)')
    fi

    RESOLVED_COUNT=$(echo "${RESOLVED_IDS_ARRAY}" | jq 'length')
    if [[ "${RESOLVED_COUNT}" -gt 0 ]]; then
      log_info "Filtering ${RESOLVED_COUNT} resolved comment(s)"
      # Use index to check if comment ID exists in resolved IDs array
      INLINE_COMMENTS_FILTERED=$(echo "${INLINE_COMMENTS_FILTERED}" | jq --argjson resolved_ids "${RESOLVED_IDS_ARRAY}" '[.[] | select(.id as $id | $resolved_ids | index($id) | not)]' 2>&1) || {
        log_warn "Could not filter resolved comments"
      }
    fi
  fi

  # Format filtered comments for readability
  if [[ -n "${INLINE_COMMENTS_FILTERED}" && "${INLINE_COMMENTS_FILTERED}" != "[]" ]]; then
    COMMENT_COUNT=$(echo "${INLINE_COMMENTS_FILTERED}" | jq 'length')
    log_info "Found ${COMMENT_COUNT} active inline comment(s) (filtered out outdated/resolved)"

    INLINE_COMMENTS_FORMATTED=$(echo "${INLINE_COMMENTS_FILTERED}" | jq -r '.[] | "---\nAuthor: \(.user.login)\nFile: \(.path):\(.line // .original_line // "unknown")\nComment: \(.body)\n"' 2>&1) || {
      log_warn "Could not format inline comments, using raw JSON"
      INLINE_COMMENTS_FORMATTED="${INLINE_COMMENTS_FILTERED}"
    }
  else
    INLINE_COMMENTS_FORMATTED="No active inline comments (all outdated or resolved)"
  fi
else
  log_warn "Skipping inline comments fetch (repo info unavailable)"
  INLINE_COMMENTS_FORMATTED="Inline comments unavailable"
fi

# Get the full diff for context
PR_DIFF=$(command gh pr diff "${PR_NUMBER}" "${REPO_FLAG[@]}" 2>&1) || {
  log_warn "Could not fetch PR diff"
  PR_DIFF=""
}

# --- Build targeted diff context ---
# Extract files mentioned in inline comments - these are critical and must be included
COMMENTED_FILES=""
if [[ -n "${INLINE_COMMENTS_FILTERED}" && "${INLINE_COMMENTS_FILTERED}" != "[]" ]]; then
  # Filter out empty lines to prevent empty alternations in regex pattern
  COMMENTED_FILES=$(echo "${INLINE_COMMENTS_FILTERED}" | jq -r '.[].path' | grep -v '^[[:space:]]*$' | sort -u || true)
fi

DIFF_LINES=$(echo "${PR_DIFF}" | wc -l)

if [[ ${DIFF_LINES} -le 1000 ]]; then
  # Small diff - include everything
  log_info "Diff is ${DIFF_LINES} lines (under threshold), including full diff"
  TARGETED_DIFF="${PR_DIFF}"
else
  # Large diff - build smart targeted context
  log_info "Diff is large (${DIFF_LINES} lines), building smart targeted context..."

  # Check if CI passed
  CI_PASSED=false
  if echo "${STATUS_CHECKS}" | grep -qE "(SUCCESS|PASS)"; then
    CI_PASSED=true
    log_info "CI passed - enabling smart data file filtering"
  fi

  # Initialize counters (required before arithmetic operations with set -e)
  FULL_DIFF_COUNT=0
  SUMMARIZED_COUNT=0
  TRUNCATED_COUNT=0

  # Process each file based on classification
  PROCESSED_DIFF=""
  FILE_SUMMARIES=""

  while IFS= read -r file_path; do
    if [[ -z "${file_path}" ]]; then
      continue
    fi

    file_diff=$(extract_file_diff "${PR_DIFF}" "${file_path}")

    # Decision tree: Security-first design
    # Security-critical files are checked BEFORE data files to ensure
    # sensitive JSON/config files (credentials, secrets) are never summarized
    if is_security_critical "${file_path}"; then
      # Always show security-critical files in full
      PROCESSED_DIFF+="${file_diff}
"
      FULL_DIFF_COUNT=$((FULL_DIFF_COUNT + 1))

    elif has_inline_comments "${file_path}"; then
      # Always show files with inline comments in full
      PROCESSED_DIFF+="${file_diff}
"
      FULL_DIFF_COUNT=$((FULL_DIFF_COUNT + 1))

    elif is_data_file "${file_path}"; then
      if [[ "${CI_PASSED}" == true ]]; then
        # Data file + CI passed + no comments = summarize
        summary=$(summarize_data_file "${file_path}" "${file_diff}")
        FILE_SUMMARIES+="${summary}
"
        SUMMARIZED_COUNT=$((SUMMARIZED_COUNT + 1))
      else
        # CI failed - include data file for debugging
        PROCESSED_DIFF+="${file_diff}
"
        FULL_DIFF_COUNT=$((FULL_DIFF_COUNT + 1))
      fi

    elif [[ "${CI_PASSED}" == true ]]; then
      # Regular code file + CI passed + no comments = truncate
      truncated=$(truncate_code_diff "${file_diff}")
      PROCESSED_DIFF+="${truncated}
"
      TRUNCATED_COUNT=$((TRUNCATED_COUNT + 1))

    else
      # CI failed - show everything
      PROCESSED_DIFF+="${file_diff}
"
      FULL_DIFF_COUNT=$((FULL_DIFF_COUNT + 1))
    fi
  done < <(get_changed_files "${PR_DIFF}" || true)

  # Build final targeted diff
  TARGETED_DIFF="=== Smart Diff Context (${DIFF_LINES} total lines) ===

Files shown in full: ${FULL_DIFF_COUNT}
Files truncated (no comments, CI passed): ${TRUNCATED_COUNT}
Data files summarized (CI validated): ${SUMMARIZED_COUNT}

=== Full/Truncated Diffs ===

${PROCESSED_DIFF}

=== Data Files (CI Validated) ===

${FILE_SUMMARIES}"

  TARGETED_LINES=$(echo "${TARGETED_DIFF}" | wc -l)
  log_info "Smart diff built: ${TARGETED_LINES} lines (down from ${DIFF_LINES})"
fi

# Use targeted diff for analysis
PR_DIFF="${TARGETED_DIFF}"

# --- Build the analysis prompt ---
read -r -d '' ANALYSIS_PROMPT <<'PROMPT_EOF' || true
You are analyzing a GitHub PR to determine if it's safe to merge.

IMPORTANT: You are being invoked as a focused analysis tool with --no-session-persistence.
Do NOT output Protocol 0 environment check or any preamble.
Begin your response directly with the verdict in the specified format below.

IMPORTANT - PR DIFF FORMAT:
The PR diff provided uses smart filtering to reduce token usage while preserving critical context:
- **Full diffs**: Files with inline comments or security-critical files (auth, payment, db, etc.)
- **Truncated diffs**: Code files without comments (first/last 50 lines shown, CI passed)
- **Summarized**: Data files validated by CI (JSON, lock files, etc.)

If a file shows "CI validated data file (not shown)", trust CI validation unless:
1. The file type is security-critical (credentials, secrets)
2. Inline comments specifically flag issues with that file
3. CI checks show failures

Focus your review on:
1. Files with inline comments (highest priority - shown in full)
2. Security-critical code files (always shown in full)
3. Code logic in truncated files (meaningful sections shown)

Identify:
1. **Unresolved concerns** - Issues raised but not addressed in subsequent commits
2. **Requested changes** - Explicit change requests not yet implemented
3. **Blocking issues** - Security concerns, bugs flagged by reviewers
4. **CI failures** - Failed checks or tests
5. **Inline file comments** - CRITICAL: Check comments posted directly on code lines (especially from bots)

CRITICAL RULES:
- **CI CHECK STATUS**: Check status is provided in "CI Check Status" section
  - FAILURE/NEUTRAL conclusion = blocking issue that must be addressed
  - SUCCESS = CI passed, but still check inline comments for specific concerns
  - PENDING = check still running, cannot merge yet
- **SEER EXCEPTION**: "Seer Code Review" check is NON-BLOCKING regardless of
  conclusion (SUCCESS/FAILURE/NEUTRAL/PENDING). Seer runs on Sentry
  infrastructure (flaky/rate-limited) and reports findings via NEUTRAL
  conclusion. Its findings flow through as inline review comments below and
  are advisory only. Do not block merge on Seer check status — examine its
  inline comments alongside other input.
- **INLINE COMMENTS**: Bots like "sentry[bot]" and "Seer" post comments on specific code lines, NOT as review summaries
  - These appear in the "Inline Review Comments" section below
  - IMPORTANT: Outdated comments (code changed) and resolved threads are already filtered out
  - Only active, unresolved inline comments are shown
  - If no active inline comments exist, the issue was likely addressed
- If all remote CI checks pass, defer to CI unless reviewer explicitly flags security risk
- Review comments may reference code that was later fixed - check timestamps
- Distinguish "reviewer suggested" (non-blocking, use NON_BLOCKING_ISSUE block) from "reviewer blocked" (blocking, use BLOCK_MERGE)
- Automated reviewers (Seer, Claude bot, sentry[bot]) are informational - prioritize human reviewers and CI

Reviewer context:
- "Seer", "Claude", and "sentry[bot]" are automated bots
- sentry[bot] posts inline comments on specific code lines (not review summaries)
- Human reviewers override bots
- Passing CI indicates issues were addressed
- Inline comments below have been filtered: outdated comments (code changed) and resolved threads are excluded

Respond in this format:

VERDICT: [SAFE_TO_MERGE or BLOCK_MERGE]

[If BLOCK_MERGE, list each issue:]
ISSUE: [one-line description]
SOURCE: [reviewer or "CI" or "sentry[bot]"]
LOCATION: [file:line if inline comment]
STATUS: [UNRESOLVED or UNCLEAR]
DETAILS: [what needs to happen]

[If SAFE_TO_MERGE:]
All review comments (including inline comments) appear resolved or are non-blocking. [Brief summary]

If any reviewer (bot or human) mentioned a concern that is worth tracking but does not block the merge,
output one or more NON_BLOCKING_ISSUE blocks AFTER the SAFE_TO_MERGE verdict:

NON_BLOCKING_ISSUE:
TITLE: [concise one-line title suitable for a GitHub issue — do not use quotes]
SOURCE: [reviewer or bot name, e.g. Seer, code-reviewer, or inline comment by alice]
LOCATION: [file:line if applicable, or general]
DETAILS: [2-4 sentences: what was flagged, why it matters, suggested action]
VERIFIED: [optional — the command you actually ran and its observed output; see rules below]
END_ISSUE

IMPORTANT RULES for NON_BLOCKING_ISSUE:
- Only include concerns that were explicitly mentioned by a reviewer. Do NOT invent concerns.
- Omit this section entirely if there is nothing worth tracking.
- Each block must start with NON_BLOCKING_ISSUE: on its own line and end with END_ISSUE on its own line.
- DETAILS may span multiple lines.
- Do not use quotes in TITLE values.
- VERIFIABLE CLAIMS: YOU HAVE NO TOOLS. You cannot run commands, read files,
  or search the repo — you see only the PR data given to you above. So you are
  never in a position to check a factual claim, and must never write a
  VERIFIED: field describing a command as if you had run it.
- Your job here is to RELAY what reviewers said, not to re-derive it. When a
  reviewer asserts something checkable — what a SHA resolves to, what a file
  contains, whether a flag exists, how a tool or shell construct behaves —
  attribute it rather than restating it as established fact. Write "Seer
  reports that X" or "a reviewer flagged X", not "X is broken". The
  attribution is what lets a human tell a measured finding from a repeated
  guess.
- HOW A TOOL OR RUNTIME BEHAVES IS THE HIGHEST-RISK CLASS. "argv[1] is the
  script path", "if: failure() only covers the previous step", "grep -w splits
  on /", "that flag does not exist", "an empty object passes", "printf adds a
  trailing newline" — these read as authoritative and are frequently wrong.
  Six such findings in one session were asserted from memory and every one was
  false. Relay them attributed, or phrase them as the open question they are.
  Never promote one to a flat assertion of your own.
- VERIFIED: may span multiple lines and must come last in the block, after
  DETAILS. In this reviewer it should almost always be omitted: use it only to
  quote a command and output that ALREADY APPEAR in the PR data above, and say
  which reviewer produced them. Never omit attribution and never invent one.
- Findings that assert incorrectness with no VERIFIED: field are still filed,
  but carry an "unverified" label and a warning banner — past unverified
  assertions of exactly this shape were false and cost a human time to disprove.

Be conservative but pragmatic. If CI passes and concerns look addressed, allow merge.
PROMPT_EOF

# --- Build full prompt ---
FULL_PROMPT="${ANALYSIS_PROMPT}

PR #${PR_NUMBER}: ${PR_TITLE}
Review Decision: ${REVIEW_DECISION}

=== CI Check Status ===
${STATUS_CHECKS}

=== Review Data (JSON) ===
${PR_JSON}

=== Review Comments ===
${REVIEW_COMMENTS}

=== Active Inline Review Comments (outdated/resolved filtered out) ===
${INLINE_COMMENTS_FORMATTED}

=== PR Diff (for context) ===
\`\`\`diff
${PR_DIFF}
\`\`\`"

# --- Model selection ---
# Intentionally inherits the calling session's active model by default (no
# --model flag) rather than pinning to Haiku like run-review.sh's commit-time
# review. This gate runs once per merge attempt (low frequency) and is the last
# line of defense before code lands, so it should get the strongest model the
# human is already paying for in that session, not the cheapest one. Override
# via git config review.mergeModel if a fixed model is ever preferred over
# inheritance (e.g. to decouple this gate from whatever the interactive
# session happens to be running).
MERGE_REVIEW_MODEL=$(git config --get review.mergeModel 2>/dev/null || echo "")
MERGE_MODEL_ARGS=()
if [[ -n "${MERGE_REVIEW_MODEL}" ]]; then
  MERGE_MODEL_ARGS=(--model "${MERGE_REVIEW_MODEL}")
fi

# --- Call Claude CLI ---
PROMPT_SIZE=${#FULL_PROMPT}
PROMPT_LINES=$(echo "${FULL_PROMPT}" | wc -l)
log_info "Prompt size: ${PROMPT_SIZE} bytes, ${PROMPT_LINES} lines"

# Now that the prompt exists, size the timeout to it (or honor an override).
compute_effective_timeout "${PROMPT_SIZE}"

log_info "Analyzing review comments..."

# Unset CLAUDECODE so this can be invoked from within a Claude Code session.
# Claude CLI 2.1.50+ refuses to start if CLAUDECODE is set (anti-nesting check).
# Safe here because --no-session-persistence + piped input = non-interactive child process.
ANALYSIS_TEXT=$(echo "${FULL_PROMPT}" | timeout "${TIMEOUT_SECONDS}" env -u CLAUDECODE "${CLAUDE_CLI}" -p "${MERGE_MODEL_ARGS[@]}" --tools "" --no-session-persistence 2>&1) || {
  EXIT_CODE=$?
  if [[ ${EXIT_CODE} -eq 124 ]]; then
    # An infrastructure failure, NOT a review finding. Say so unambiguously:
    # a bare "timed out" line above an `exit 1` reads like the reviewer
    # objected to the PR, when in fact it never got far enough to have an
    # opinion about it at all.
    log_error "Analysis TIMED OUT after ${TIMEOUT_SECONDS}s (prompt: ${PROMPT_SIZE} bytes)."
    log_error "This is an infrastructure failure, not a review finding: the"
    log_error "analysis never completed and rendered NO opinion on this PR."
    log_error "Nothing was found wrong with the code - nothing was assessed."
    log_error ""
    log_error "What to do:"
    log_error "  1. Re-run the merge - the analysis often completes on a retry."
    log_error "  2. If it times out repeatedly, raise the ceiling explicitly:"
    log_error "       git config --global review.preMergeTimeout $((TIMEOUT_SECONDS * 2))"
    log_error "     That value is honored verbatim and disables both size-based"
    log_error "     scaling and the ${TIMEOUT_CEILING_SECONDS}s ceiling, so the suggestion above can"
    log_error "     exceed the ceiling. Set it deliberately, not just to silence this."
  else
    log_error "Claude CLI failed (exit code: ${EXIT_CODE})"
    log_error "${ANALYSIS_TEXT}"
  fi
  exit 1
}

if [[ -z "${ANALYSIS_TEXT}" ]]; then
  log_error "Empty response from Claude CLI"
  exit 1
fi

# --- Evaluate verdict ---
echo "" >&2
echo "${ANALYSIS_TEXT}" >&2
echo "" >&2

# Parse verdict - extract the line containing VERDICT and check its value
# This handles cases where environment check or other output appears before verdict
VERDICT_LINE=$(echo "${ANALYSIS_TEXT}" | grep -E "^VERDICT:" | head -1)

if [[ -z "${VERDICT_LINE}" ]]; then
  # Couldn't find verdict - fail safe (block merge)
  log_warn "Could not parse analysis verdict - no 'VERDICT:' line found"
  log_warn "Blocking merge out of caution - review output above"
  exit 1
fi

if echo "${VERDICT_LINE}" | grep -qE "SAFE_TO_MERGE"; then
  # Authorization was already verified at the top of this script (early check).
  log_success "PR review analysis passed - safe to merge"
  # Create GitHub issues for any non-blocking concerns found during review.
  # Guard: if the merge fails and Claude retries within the same authorization
  # window (30-min TTL), skip issue creation to prevent duplicates.
  if [[ -f "${MERGE_LOCK_FILE}" ]] && grep -q "^ISSUES_CREATED=1$" "${MERGE_LOCK_FILE}" 2>/dev/null; then
    log_info "Non-blocking issues already filed for PR #${PR_NUMBER} in this auth window — skipping"
  else
    create_nonblocking_issues "${ANALYSIS_TEXT}"
    # Mark so a retry within the same auth window skips issue creation.
    [[ -f "${MERGE_LOCK_FILE}" ]] && printf 'ISSUES_CREATED=1\n' >>"${MERGE_LOCK_FILE}" || true
  fi
  exit 0
elif echo "${VERDICT_LINE}" | grep -qE "BLOCK_MERGE"; then
  log_error "PR has unresolved review issues - merge blocked"
  echo "" >&2
  echo "   Address the issues above before merging." >&2
  echo "" >&2
  echo "   💡 TIP: If you've already resolved these issues and the comments are outdated," >&2
  echo "      add a new PR comment explaining what was fixed, then attempt the merge again." >&2
  echo "      The reviewer will see your update and re-analyze the current state." >&2
  echo "" >&2
  echo "   To bypass (emergency only):" >&2
  echo "   OBTAIN EXPLICIT PERMISSION and then command gh pr merge ${PR_NUMBER}" >&2
  echo "" >&2
  exit 1
else
  # Verdict line exists but contains neither expected value
  log_warn "Could not parse analysis verdict - unexpected format: ${VERDICT_LINE}"
  log_warn "Blocking merge out of caution - review output above"
  exit 1
fi
