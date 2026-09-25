#!/usr/bin/env bats
# Tests for issue #562: merge-lock authorize should accept any standard PR
# notation (bare N, #N, repo#N, owner/repo#N, a full PR URL), should suggest
# a sibling repo when a bare number does not exist in the resolved repo, and
# should only probe the cwd for a repo when the list actually needs one — a
# fully qualified list must work from a directory that is not a git checkout
# at all (the twistedmelonman/claude-config#562 comment reproduction).
#
# Run: bats tests/test_merge_lock_notation.bats

SCRIPT="${BATS_TEST_DIRNAME}/../hooks/merge-lock.sh"

setup() {
  # The real gh is an exported shell function; both halves must be cleared
  # or it shadows the PATH stub below (claude-config#514, #477).
  unset BASH_ENV
  unset CDPATH
  unset -f gh 2>/dev/null || true
  export -n gh 2>/dev/null || true

  TMP_HOME="$(mktemp -d)"
  readonly TMP_HOME
  export HOME="${TMP_HOME}"
  mkdir -p "${TMP_HOME}/bin"
  export PATH="${TMP_HOME}/bin:${PATH}"
  export GH_LOG="${TMP_HOME}/gh-calls.log"
}

teardown() {
  rm -rf "${TMP_HOME}"
}

lock_file() {
  echo "${TMP_HOME}/.claude/merge-locks/$2/pr-$1.lock"
}

# An argument-aware gh stub, extended from test_merge_lock_pr_exists.bats
# with `gh repo list OWNER` for the other-repos suggestion.
#
#   CWD_REPO      - what `gh repo view` (no slug) answers; unset/empty fails,
#                    standing in for a directory that is not a git checkout
#   KNOWN_REPOS   - space-separated repo slugs that resolve
#   EXISTING_PRS  - space-separated "repo#pr" pairs that resolve
#   OWNER_REPOS   - space-separated "owner:name" pairs `repo list` returns
install_gh_stub() {
  cat >"${TMP_HOME}/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${GH_LOG}"

if [[ "$1" == "repo" && "$2" == "view" && "$3" == --* ]]; then
  if [[ -n "${CWD_REPO:-}" ]]; then
    echo "${CWD_REPO}"
    exit 0
  fi
  echo "error: not a git repository" >&2
  exit 1
fi

if [[ "$1" == "repo" && "$2" == "view" ]]; then
  for r in ${KNOWN_REPOS:-}; do
    if [[ "$3" == "${r}" ]]; then
      echo "${r}"
      exit 0
    fi
  done
  echo "GraphQL: Could not resolve to a Repository with the name '$3'." >&2
  exit 1
fi

if [[ "$1" == "repo" && "$2" == "list" ]]; then
  owner="$3"
  for pair in ${OWNER_REPOS:-}; do
    o="${pair%%:*}"
    n="${pair#*:}"
    if [[ "${o}" == "${owner}" ]]; then
      echo "${n}"
    fi
  done
  exit 0
fi

if [[ "$1" == "pr" && "$2" == "view" ]]; then
  pr="$3"
  repo=""
  while [[ $# -gt 0 ]]; do
    [[ "$1" == "--repo" ]] && repo="$2"
    shift
  done
  for pair in ${EXISTING_PRS:-}; do
    if [[ "${pair}" == "${repo}#${pr}" ]]; then
      echo "{\"number\":${pr}}"
      exit 0
    fi
  done
  echo "GraphQL: Could not resolve to a PullRequest with the number of ${pr}." >&2
  exit 1
fi

exit 0
STUB
  chmod +x "${TMP_HOME}/bin/gh"
}

# --- notation forms -----------------------------------------------------------

@test "a leading-hash bare number resolves against the cwd repo like a plain number" {
  install_gh_stub
  export CWD_REPO="acme/widgets"
  export KNOWN_REPOS="acme/widgets"
  export EXISTING_PRS="acme/widgets#42"

  run bash "${SCRIPT}" auth "#42" "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 42 acme/widgets)" ]
}

@test "a short repo#N token borrows the owner from the cwd repo" {
  install_gh_stub
  export CWD_REPO="acme/widgets"
  export KNOWN_REPOS="acme/gadgets"
  export EXISTING_PRS="acme/gadgets#7"

  run bash "${SCRIPT}" auth "gadgets#7" "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 7 acme/gadgets)" ]
}

@test "a short repo#N token borrows the owner from --repo" {
  install_gh_stub
  export KNOWN_REPOS="acme/gadgets"
  export EXISTING_PRS="acme/gadgets#7"

  run bash "${SCRIPT}" auth "gadgets#7" "ok" --repo acme/widgets
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 7 acme/gadgets)" ]
}

@test "a full github.com PR URL authorizes without any cwd or --repo" {
  install_gh_stub
  export KNOWN_REPOS="acme/widgets"
  export EXISTING_PRS="acme/widgets#42"

  run bash "${SCRIPT}" auth "https://github.com/acme/widgets/pull/42" "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 42 acme/widgets)" ]
}

@test "a full github.com PR URL mixes with other notations in one batch" {
  install_gh_stub
  export CWD_REPO="acme/widgets"
  export KNOWN_REPOS="acme/widgets acme/gadgets"
  export EXISTING_PRS="acme/widgets#42 acme/gadgets#7"

  run bash "${SCRIPT}" auth "https://github.com/acme/gadgets/pull/7,42" "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 7 acme/gadgets)" ]
  [ -f "$(lock_file 42 acme/widgets)" ]
}

@test "an empty repo before # via the short form is still rejected" {
  install_gh_stub
  export CWD_REPO="acme/widgets"

  run bash "${SCRIPT}" auth "#" "ok"
  [ "${status}" -ne 0 ]
}

# --- cwd resolution only when the list needs it (issue #562 comment) --------

@test "a fully qualified list authorizes from a directory that is not a git checkout" {
  install_gh_stub
  # CWD_REPO unset: `gh repo view` (no slug) fails, exactly like running
  # merge-lock from a non-repo directory.
  export KNOWN_REPOS="twistedmelonman/personify"
  export EXISTING_PRS="twistedmelonman/personify#97"

  run bash "${SCRIPT}" auth "twistedmelonman/personify#97" "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 97 twistedmelonman/personify)" ]
  # The cwd probe must never have run.
  run grep -c '^repo view --json' "${GH_LOG}"
  [ "${output}" = "0" ]
}

@test "a PR URL also authorizes from a directory that is not a git checkout" {
  install_gh_stub
  export KNOWN_REPOS="twistedmelonman/personify"
  export EXISTING_PRS="twistedmelonman/personify#97"

  run bash "${SCRIPT}" auth "https://github.com/twistedmelonman/personify/pull/97" "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 97 twistedmelonman/personify)" ]
}

@test "a bare number in an otherwise-qualified list still needs a resolvable repo" {
  install_gh_stub
  # No CWD_REPO: cwd cannot resolve. The qualified entry alone would work
  # from anywhere, but the bare '42' still needs a repo and there is none.
  export KNOWN_REPOS="acme/widgets"
  export EXISTING_PRS="acme/widgets#7"

  run bash "${SCRIPT}" auth "acme/widgets#7,42" "ok"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"could not determine the GitHub repo"* ]]
  [ ! -f "$(lock_file 7 acme/widgets)" ]
}

@test "--repo still resolves normally and does not probe the cwd" {
  install_gh_stub
  export KNOWN_REPOS="acme/widgets"
  export EXISTING_PRS="acme/widgets#42"

  run bash "${SCRIPT}" auth 42 "ok" --repo acme/widgets
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 42 acme/widgets)" ]
}

# --- suggesting a sibling repo for a missed bare number ----------------------

@test "a missed bare number suggests a sibling repo under the same owner" {
  install_gh_stub
  export CWD_REPO="acme/widgets"
  export KNOWN_REPOS="acme/widgets"
  export EXISTING_PRS=""
  export OWNER_REPOS="acme:widgets acme:gadgets"
  # 42 doesn't exist in widgets, but does in gadgets.
  export EXISTING_PRS="acme/gadgets#42"

  run bash "${SCRIPT}" auth 42 "ok"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Did you mean"* ]]
  [[ "${output}" == *"acme/gadgets#42"* ]]
  [ ! -f "$(lock_file 42 acme/gadgets)" ]
}

@test "a missed bare number with no sibling match prints no suggestion" {
  install_gh_stub
  export CWD_REPO="acme/widgets"
  export KNOWN_REPOS="acme/widgets"
  export EXISTING_PRS=""
  export OWNER_REPOS="acme:widgets acme:gadgets"

  run bash "${SCRIPT}" auth 999 "ok"
  [ "${status}" -ne 0 ]
  [[ "${output}" != *"Did you mean"* ]]
}

@test "a miss on an already-qualified token does not trigger the suggestion search" {
  install_gh_stub
  export CWD_REPO="acme/widgets"
  export KNOWN_REPOS="acme/widgets acme/gadgets"
  export EXISTING_PRS=""
  export OWNER_REPOS="acme:widgets acme:gadgets"

  run bash "${SCRIPT}" auth "acme/gadgets#42" "ok"
  [ "${status}" -ne 0 ]
  [[ "${output}" != *"Did you mean"* ]]
  run grep -c '^repo list' "${GH_LOG}"
  [ "${output}" = "0" ]
}
