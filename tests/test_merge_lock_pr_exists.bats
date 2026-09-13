#!/usr/bin/env bats
# Tests that authorize refuses a PR that does not exist in the resolved repo
# (issue #471). Run: bats tests/test_merge_lock_pr_exists.bats
#
# The failure this guards against is a well-formed repo paired with a
# well-formed PR number that do not belong together — which happens when the
# cwd is a different checkout than the PR. Every individual step succeeds; the
# composite answer is wrong, and the lock authorizes nothing.

SCRIPT="${BATS_TEST_DIRNAME}/../hooks/merge-lock.sh"

setup() {
  # The real gh is a shell wrapper, exported into the environment. Both halves
  # matter: unsetting BASH_ENV stops child shells re-sourcing functions.sh,
  # and unsetting the function itself drops the copy already exported here.
  # Without the second, the wrapper shadows the PATH stub below and every
  # call fails on its identity check rather than reaching the stub.
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
  echo "${TMP_HOME}/.claude/merge-locks/${2:-acme/widgets}/pr-$1.lock"
}

# An argument-aware gh stub. The older merge-lock tests stub gh as a blanket
# `echo acme/widgets`, which answers `gh pr view` "successfully" and would
# make every PR look like it exists. These tests need it to discriminate.
#
#   EXISTING_PRS - space-separated "repo#pr" pairs that resolve
#   KNOWN_REPOS  - space-separated repo slugs that resolve
#   GH_OFFLINE   - when set, every call fails, standing in for an outage
install_gh_stub() {
  cat >"${TMP_HOME}/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${GH_LOG}"

if [[ -n "${GH_OFFLINE:-}" ]]; then
  echo "error connecting to api.github.com" >&2
  exit 1
fi

# `gh repo view` with no slug: resolve from the cwd, like a real checkout.
if [[ "$1" == "repo" && "$2" == "view" && "$3" == --* ]]; then
  echo "${CWD_REPO:-acme/widgets}"
  exit 0
fi

# `gh repo view OWNER/NAME`: does the repo exist?
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

# `gh pr view N --repo OWNER/NAME`: does that pair exist?
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

# --- the reported failure ----------------------------------------------------

@test "refuses to authorize a PR that does not exist in the cwd repo" {
  # The live #471 reproduction: cwd is dev-env, the PR lives in dotfiles.
  install_gh_stub
  export CWD_REPO="acme/dev-env"
  export KNOWN_REPOS="acme/dev-env acme/dotfiles"
  export EXISTING_PRS="acme/dotfiles#305"

  run bash "${SCRIPT}" auth 305 "ok"
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 305 acme/dev-env)" ]
}

@test "the refusal names both halves of the pair" {
  install_gh_stub
  export CWD_REPO="acme/dev-env"
  export KNOWN_REPOS="acme/dev-env"
  export EXISTING_PRS=""

  run bash "${SCRIPT}" auth 305 "ok"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"acme/dev-env"* ]]
  [[ "${output}" == *"305"* ]]
}

@test "the refusal names the directory the repo came from" {
  # Naming the cwd is what makes this self-diagnosing: it is the input the
  # human did not realize they were supplying.
  install_gh_stub
  export CWD_REPO="acme/dev-env"
  export KNOWN_REPOS="acme/dev-env"
  export EXISTING_PRS=""

  run bash "${SCRIPT}" auth 305 "ok"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"current directory"* ]]
}

@test "the refusal points at --repo as the fix" {
  install_gh_stub
  export CWD_REPO="acme/dev-env"
  export KNOWN_REPOS="acme/dev-env"
  export EXISTING_PRS=""

  run bash "${SCRIPT}" auth 305 "ok"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"--repo"* ]]
}

# --- the happy path still works ----------------------------------------------

@test "authorizes a PR that does exist" {
  install_gh_stub
  export CWD_REPO="acme/widgets"
  export KNOWN_REPOS="acme/widgets"
  export EXISTING_PRS="acme/widgets#42"

  run bash "${SCRIPT}" auth 42 "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 42)" ]
}

@test "--repo is validated against, not bypassed" {
  install_gh_stub
  export CWD_REPO="acme/widgets"
  export KNOWN_REPOS="acme/widgets acme/gadgets"
  export EXISTING_PRS="acme/widgets#42"

  run bash "${SCRIPT}" auth 42 "ok" --repo acme/gadgets
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 42 acme/gadgets)" ]
}

@test "an explicit --repo that does contain the PR succeeds" {
  install_gh_stub
  export CWD_REPO="acme/dev-env"
  export KNOWN_REPOS="acme/dev-env acme/dotfiles"
  export EXISTING_PRS="acme/dotfiles#305"

  run bash "${SCRIPT}" auth 305 "ok" --repo acme/dotfiles
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 305 acme/dotfiles)" ]
}

@test "a repo-qualified inline entry is validated against its own repo" {
  install_gh_stub
  export CWD_REPO="acme/widgets"
  export KNOWN_REPOS="acme/widgets acme/dotfiles"
  export EXISTING_PRS="acme/dotfiles#305"

  run bash "${SCRIPT}" auth "acme/dotfiles#305" "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 305 acme/dotfiles)" ]
}

# --- batch behavior ----------------------------------------------------------

@test "one nonexistent PR rejects the entire batch" {
  # A typo in the third entry must authorize nothing, rather than leaving the
  # first two written and the operator unsure how far it got.
  install_gh_stub
  export CWD_REPO="acme/widgets"
  export KNOWN_REPOS="acme/widgets"
  export EXISTING_PRS="acme/widgets#100 acme/widgets#204"

  run bash "${SCRIPT}" auth "100,204,999" "ok"
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 100)" ]
  [ ! -f "$(lock_file 204)" ]
  [ ! -f "$(lock_file 999)" ]
}

@test "a batch where every PR exists is written in full" {
  install_gh_stub
  export CWD_REPO="acme/widgets"
  export KNOWN_REPOS="acme/widgets"
  export EXISTING_PRS="acme/widgets#100 acme/widgets#204 acme/widgets#553"

  run bash "${SCRIPT}" auth "100,204,553" "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 100)" ]
  [ -f "$(lock_file 204)" ]
  [ -f "$(lock_file 553)" ]
}

@test "a cross-repo batch validates each entry against its own repo" {
  install_gh_stub
  export CWD_REPO="acme/widgets"
  export KNOWN_REPOS="acme/widgets acme/gadgets"
  export EXISTING_PRS="acme/widgets#100 acme/gadgets#7"

  run bash "${SCRIPT}" auth "acme/widgets#100,acme/gadgets#7" "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 100)" ]
  [ -f "$(lock_file 7 acme/gadgets)" ]
}

@test "a cross-repo batch fails if any one pair is wrong" {
  install_gh_stub
  export CWD_REPO="acme/widgets"
  export KNOWN_REPOS="acme/widgets acme/gadgets"
  export EXISTING_PRS="acme/widgets#100"

  run bash "${SCRIPT}" auth "acme/widgets#100,acme/gadgets#7" "ok"
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 100)" ]
  [ ! -f "$(lock_file 7 acme/gadgets)" ]
}

# --- degraded network --------------------------------------------------------

@test "an unreachable API warns but still authorizes" {
  # This check puts a network call on a path that previously made none. An
  # outage must degrade to the old behavior, not lock the human out of
  # merging.
  install_gh_stub
  export CWD_REPO="acme/widgets"
  export GH_OFFLINE=1

  # cwd resolution needs gh, so name the repo explicitly; the point of the
  # test is the PR-existence probe failing, not repo resolution.
  run bash "${SCRIPT}" auth 42 "ok" --repo acme/widgets
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 42)" ]
  [[ "${output}" == *"Could not reach GitHub"* ]]
}

@test "the unreachable warning appears once, not once per batch entry" {
  install_gh_stub
  export GH_OFFLINE=1

  run bash "${SCRIPT}" auth "100,204,553" "ok" --repo acme/widgets
  [ "${status}" -eq 0 ]
  count=$(grep -c "Could not reach GitHub" <<<"${output}" || true)
  [ "${count}" -eq 1 ]
}

@test "a missing repo is treated as unreachable, not as a missing PR" {
  # `gh repo view` fails identically for "repo is gone" and "cannot reach
  # GitHub". Neither is evidence that the PR does not exist, so both must
  # warn rather than hard-fail.
  install_gh_stub
  export KNOWN_REPOS=""
  export EXISTING_PRS=""

  run bash "${SCRIPT}" auth 42 "ok" --repo acme/absent
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 42 acme/absent)" ]
}

# --- unchanged behavior ------------------------------------------------------

@test "syntactic validation still runs before any network call" {
  install_gh_stub
  export CWD_REPO="acme/widgets"
  export KNOWN_REPOS="acme/widgets"
  export EXISTING_PRS="acme/widgets#100"

  run bash "${SCRIPT}" auth "100,abc" "ok"
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 100)" ]
  # A malformed entry should be caught without asking GitHub about it.
  run grep -c "pr view" "${GH_LOG}"
  [ "${output}" = "0" ]
}

@test "check and status make no PR-existence call" {
  # Only authorize validates the pair. A check against an expired or absent
  # lock must not depend on the network.
  install_gh_stub
  export CWD_REPO="acme/widgets"
  export KNOWN_REPOS="acme/widgets"
  export EXISTING_PRS="acme/widgets#42"

  run bash "${SCRIPT}" check 42
  [ "${status}" -ne 0 ]
  run grep -c "pr view" "${GH_LOG}"
  [ "${output}" = "0" ]
}
