#!/usr/bin/env bats
# Tests for gh() wrapper extension — blocks gh api .../pulls/NNN/merge
#
# The Claude Code PreToolUse hook (hook-block-api-merge.sh) is the primary
# defense, but the gh() bash function wrapper provides a second layer:
# it also blocks `gh api .../pulls/NNN/merge` so the bypass is caught
# even when the hook isn't in play (e.g., direct terminal use).
#
# Root cause documented in post-mortems:
#   - PR #813: gh pr merge failed silently → gh api used as workaround
#   - v1.11.0: pattern reused → 9-second unauthorized production merge
#
# Run: bats ~/.claude/tests/test_gh_wrapper_api_merge.bats

# gh() lives in gh-wrapper.sh; functions.sh only sources it (and keeps a
# fail-closed stub for when it is missing). Resolved here, at file load, from
# the real HOME -- the tests swap HOME for a sandbox before loading.
GH_WRAPPER_SH="${HOME}/.config/bash/gh-wrapper.sh"

setup() {
  # GH_TOKEN must be unset for the whole test file. The wrapper refuses to run
  # whenever GH_TOKEN is set and it cannot resolve that token to a login
  # (the GH_TOKEN identity gate); resolution calls a real `gh api user`, which the
  # PATH stub below answers with a bare `exit 0`. The refusal then fires
  # before any test reaches the api-merge blocking logic under test. The
  # wrapper prescribes this remedy directly: "If it is a test stub, unset
  # GH_TOKEN for the test so this check is skipped."
  #
  # Same cause and same fix as test_gh_wrapper.bats and
  # test_gh_binary_wrapper.bats; see the fuller note in the former.
  unset GH_TOKEN

  # The wrapper's review-script location is an exported override
  # (_gh_wrapper_review_script). If the developer's interactive shell exported
  # it -- and sourcing gh-wrapper.sh does exactly that -- bats inherits the
  # value, and it wins over the sandboxed HOME below. The mock hook would then
  # be ignored in favour of the real one, which fails for reasons unrelated to
  # anything under test. Unset it so HOME is genuinely the only input.
  # See smartwatermelon/dotfiles#222 and #360.
  unset _gh_wrapper_review_script

  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  export PATH="${MOCK_DIR}:${PATH}"

  # Mock gh binary that just exits 0
  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  # Build mock HOME with a review script that records calls
  MOCK_HOME="${MOCK_DIR}/home"
  export MOCK_HOME
  mkdir -p "${MOCK_HOME}/.claude/hooks"

  cat >"${MOCK_HOME}/.claude/hooks/pre-merge-review.sh" <<EOF
#!/usr/bin/env bash
echo "called" >"${MOCK_DIR}/review_called"
exit 0
EOF
  chmod +x "${MOCK_HOME}/.claude/hooks/pre-merge-review.sh"
}

teardown() {
  rm -rf "${MOCK_DIR}"
}

# Load gh() from gh-wrapper.sh into the current shell with MOCK_HOME active,
# the same way functions.sh does in a real shell (it sources this file). See
# the fuller note on the guards in test_gh_wrapper.bats: a load that silently
# leaves the inherited real wrapper in scope makes these tests assert against
# the ambient environment instead of the function they name. A false PASS is
# worse than a failure, so every way the load can go wrong fails loudly.
_load_gh_fn() {
  export HOME="${MOCK_HOME}"

  # Drop any gh() inherited from the caller's shell, so the checks below can
  # only succeed if the definition came from GH_WRAPPER_SH.
  unset -f gh

  if [[ ! -f "${GH_WRAPPER_SH}" ]]; then
    echo "FATAL: gh wrapper not found: ${GH_WRAPPER_SH}" >&2
    return 1
  fi

  # shellcheck source=/dev/null
  if ! source "${GH_WRAPPER_SH}"; then
    echo "FATAL: sourcing ${GH_WRAPPER_SH} failed" >&2
    return 1
  fi

  # extdebug makes `declare -F` report the file a function was defined in.
  local def_src
  def_src="$(shopt -s extdebug && declare -F gh)" || def_src=""
  if [[ "${def_src}" != *" ${GH_WRAPPER_SH}" ]]; then
    echo "FATAL: gh() is not defined by ${GH_WRAPPER_SH} after sourcing it" >&2
    echo "       declare -F gh reported: '${def_src}'" >&2
    return 1
  fi
}

@test "gh api .../pulls/NNN/merge is blocked by wrapper" {
  _load_gh_fn

  run gh api repos/owner/repo/pulls/813/merge --method PUT

  [ "$status" -ne 0 ]
}

@test "gh api .../pulls/NNN/merge block message mentions gh pr merge alternative" {
  _load_gh_fn

  run gh api repos/owner/repo/pulls/813/merge --method PUT

  [ "$status" -ne 0 ]
  [[ "$output" == *"gh pr merge"* ]]
}

@test "gh api .../pulls/NNN/merge does NOT call pre-merge-review.sh (wrapper blocks before reaching review)" {
  _load_gh_fn

  run gh api repos/owner/repo/pulls/813/merge --method PUT

  [[ ! -f "${MOCK_DIR}/review_called" ]]
}

@test "gh api .../pulls/NNN/comments passes through (not the merge endpoint)" {
  _load_gh_fn

  run gh api repos/owner/repo/pulls/813/comments

  [ "$status" -eq 0 ]
}

@test "gh api repos/.../git/refs/heads/branch --method DELETE passes through (branch cleanup)" {
  _load_gh_fn

  run gh api repos/owner/repo/git/refs/heads/my-branch --method DELETE

  [ "$status" -eq 0 ]
}

@test "gh pr merge 123 still calls review script (not broken by api merge block)" {
  _load_gh_fn

  gh pr merge 123 --squash

  [[ -f "${MOCK_DIR}/review_called" ]]
}

@test "gh status still passes through (not broken by api merge block)" {
  _load_gh_fn

  run gh status

  [ "$status" -eq 0 ]
  [[ ! -f "${MOCK_DIR}/review_called" ]]
}

@test "gh api .../pulls/NNN/merge --help is still blocked (--help does not bypass merge block)" {
  # Regression guard: the --help early-return must not run before the API merge check.
  # gh api repos/.../pulls/NNN/merge --help should be blocked even when --help is present,
  # because the intent to use the merge endpoint is what matters.
  _load_gh_fn

  run gh api repos/owner/repo/pulls/813/merge --method PUT --help

  [ "$status" -ne 0 ]
}

@test "gh api graphql with mergePullRequest mutation is blocked" {
  # GraphQL merge bypass: gh api graphql -f query="mutation { mergePullRequest(...) }"
  # Same class of bypass as REST merge endpoint.
  _load_gh_fn

  run gh api graphql -f 'query=mutation { mergePullRequest(input: {pullRequestId: "PR_kwDO"}) { pullRequest { merged } } }'

  [ "$status" -ne 0 ]
}

@test "gh api graphql with non-merge query passes through" {
  # Legitimate GraphQL queries (e.g., fetching PR data) must not be blocked.
  _load_gh_fn

  run gh api graphql -f 'query=query { repository(owner: "o", name: "r") { pullRequest(number: 1) { title } } }'

  [ "$status" -eq 0 ]
}

@test "gh api .../pulls/NNN/merge_status does NOT match (suffix boundary)" {
  # Hypothetical endpoint: pulls/NNN/merge_status is NOT the merge trigger.
  # The regex must not have false positives on suffixed paths.
  _load_gh_fn

  run gh api repos/owner/repo/pulls/813/merge_status

  [ "$status" -eq 0 ]
}
