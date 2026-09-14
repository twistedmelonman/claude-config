#!/usr/bin/env bats
# Tests for repo-keyed merge-lock authorizations.
#
# Background: locks were keyed on PR number alone (pr-N.lock), so a lock
# created for repo A's PR 3 satisfied `check 3` for repo B. Locks now live
# at merge-locks/<owner>/<repo>/pr-N.lock and record REPO=owner/name.
#
# Run: bats tests/test_merge_lock_repo_keyed.bats

SCRIPT="${BATS_TEST_DIRNAME}/../hooks/merge-lock.sh"

setup() {
  # The real gh is an exported shell function, and it shadows the PATH stub
  # below unless both it and BASH_ENV are cleared. Without this, every call
  # fails on the wrapper's identity check instead of reaching the stub
  # (claude-config#514, #477).
  unset BASH_ENV
  unset CDPATH
  unset -f gh 2>/dev/null || true
  export -n gh 2>/dev/null || true

  TMP_HOME="$(mktemp -d)"
  readonly TMP_HOME
  export HOME="${TMP_HOME}"

  # gh stub, answering the three call shapes merge-lock.sh actually makes:
  #
  #   gh repo view --json nameWithOwner -q .nameWithOwner  -> cwd resolution
  #   gh repo view <repo> --json nameWithOwner             -> pr_exists step 1
  #   gh pr view <pr> --repo <repo> --json number          -> pr_exists step 2
  #
  # Empty STUB_REPO simulates "not inside a repo".
  #
  # PR existence matters because authorize calls pr_exists() (#471) and
  # refuses a PR that does not exist. A stub that cannot answer the pr view
  # call makes pr_exists return 2 ("cannot say"), which degrades open and
  # authorizes anyway — so these tests would pass even if the existence
  # check were deleted outright. MISSING_PRS lists "repo#number" records
  # that should report as absent; anything else exists.
  MOCK_BIN="${TMP_HOME}/bin"
  mkdir -p "${MOCK_BIN}"
  cat >"${MOCK_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "repo" && "$2" == "view" ]]; then
  # Qualified form (`gh repo view OWNER/NAME ...`) is pr_exists' reachability
  # probe: any repo resolves, so "cannot say" never fires in these tests.
  if [[ -n "${3:-}" && "${3}" != --* ]]; then
    echo "$3"
    exit 0
  fi
  if [[ -z "${STUB_REPO:-}" ]]; then
    echo "none of the git remotes configured for this repository point to a known GitHub host" >&2
    exit 1
  fi
  echo "${STUB_REPO}"
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  _pr="$3"
  _repo=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--repo" ]]; then
      _repo="$2"
      break
    fi
    shift
  done
  for _absent in ${MISSING_PRS:-}; do
    [[ "${_absent}" == "${_repo}#${_pr}" ]] && exit 1
  done
  printf '{"number":%s}\n' "${_pr}"
  exit 0
fi
echo "unexpected gh call: $*" >&2
exit 1
EOF
  chmod +x "${MOCK_BIN}/gh"
  export PATH="${MOCK_BIN}:${PATH}"
  export STUB_REPO="acme/widgets"
  export MISSING_PRS=""
}

teardown() {
  rm -rf "${TMP_HOME}"
}

lock_file() {
  # $1 = owner/name, $2 = PR number
  echo "${TMP_HOME}/.claude/merge-locks/$1/pr-$2.lock"
}

write_legacy_flat_lock() {
  local lock_dir="${TMP_HOME}/.claude/merge-locks"
  mkdir -p "${lock_dir}"
  {
    echo "PR_NUMBER=$1"
    echo "AUTHORIZED_BY=tester"
    echo "TIMESTAMP=$(date +%s)"
    echo "REASON=test"
  } >"${lock_dir}/pr-$1.lock"
}

# ── Keying ───────────────────────────────────────────────────────────────────

@test "authorize writes the lock under the cwd repo and records REPO=" {
  run bash "${SCRIPT}" authorize 3 "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file acme/widgets 3)" ]
  grep -q "^REPO=acme/widgets$" "$(lock_file acme/widgets 3)"
  grep -q "^PR_NUMBER=3$" "$(lock_file acme/widgets 3)"
}

@test "a lock for repo A does not authorize the same PR number in repo B" {
  STUB_REPO="acme/widgets" run bash "${SCRIPT}" authorize 3 "ok"
  [ "${status}" -eq 0 ]

  STUB_REPO="acme/gadgets" run bash "${SCRIPT}" check 3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Not authorized"* ]]
}

@test "check passes for the repo the lock was created in" {
  run bash "${SCRIPT}" authorize 3 "ok"
  [ "${status}" -eq 0 ]
  run bash "${SCRIPT}" check 3
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Authorized"* ]]
}

# ── Explicit --repo ──────────────────────────────────────────────────────────

@test "--repo overrides the cwd repo for authorize and check" {
  run bash "${SCRIPT}" authorize 7 "ok" --repo other/place
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file other/place 7)" ]
  [ ! -f "$(lock_file acme/widgets 7)" ]

  run bash "${SCRIPT}" check 7 --repo other/place
  [ "${status}" -eq 0 ]
  run bash "${SCRIPT}" check 7
  [ "${status}" -ne 0 ]
}

@test "--repo=value form is accepted" {
  run bash "${SCRIPT}" authorize 7 "ok" --repo=other/place
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file other/place 7)" ]
}

@test "--repo does not consume the reason argument" {
  run bash "${SCRIPT}" authorize 7 --repo other/place "because"
  [ "${status}" -eq 0 ]
  grep -q "^REASON=because$" "$(lock_file other/place 7)"
}

@test "batch authorize keys every lock on the same repo" {
  run bash "${SCRIPT}" authorize 1,2 "ok" --repo other/place
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file other/place 1)" ]
  [ -f "$(lock_file other/place 2)" ]
}

# ── PR existence (#471) ──────────────────────────────────────────────────────
#
# These are the tests that fail if the existence check is removed. Before the
# stub answered `gh pr view`, pr_exists() returned 2 ("cannot say") for every
# call, merge-lock degraded open with "authorizing anyway", and every test in
# this file passed whether or not the check existed at all (#514).

@test "authorize refuses a PR that does not exist in the target repo" {
  MISSING_PRS="other/place#9" run bash "${SCRIPT}" authorize 9 "ok" --repo other/place
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no PR #9"* ]]
  [ ! -f "$(lock_file other/place 9)" ]
}

@test "a batch is refused whole when one of its PRs does not exist" {
  MISSING_PRS="other/place#9" run bash "${SCRIPT}" authorize 8,9 "ok" --repo other/place
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file other/place 8)" ]
  [ ! -f "$(lock_file other/place 9)" ]
}

@test "existence is checked against the target repo, not the cwd repo" {
  # PR 3 exists in acme/widgets (the cwd repo) but not in other/place. The
  # check must follow --repo, or a lock gets written for a PR that is absent
  # from the repo it names.
  MISSING_PRS="other/place#3" run bash "${SCRIPT}" authorize 3 "ok" --repo other/place
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file other/place 3)" ]
}

# ── Repo resolution failures ─────────────────────────────────────────────────

@test "authorize fails loudly when repo cannot be resolved and no --repo given" {
  STUB_REPO="" run bash "${SCRIPT}" authorize 3 "ok"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"--repo"* ]]
  [ ! -d "${TMP_HOME}/.claude/merge-locks/acme" ]
}

@test "check fails when repo cannot be resolved rather than matching a flat lock" {
  write_legacy_flat_lock 3
  STUB_REPO="" run bash "${SCRIPT}" check 3
  [ "${status}" -ne 0 ]
}

@test "malformed --repo values are rejected" {
  run bash "${SCRIPT}" authorize 3 "ok" --repo "no-slash"
  [ "${status}" -ne 0 ]
  run bash "${SCRIPT}" authorize 3 "ok" --repo "../escape/x"
  [ "${status}" -ne 0 ]
  run bash "${SCRIPT}" authorize 3 "ok" --repo "a/b/c"
  [ "${status}" -ne 0 ]
  [ ! -d "${TMP_HOME}/.claude/merge-locks/.." ] || [ ! -f "${TMP_HOME}/.claude/merge-locks/../escape/x/pr-3.lock" ]
}

# ── Legacy flat locks ────────────────────────────────────────────────────────

@test "a pre-existing flat pr-N.lock never satisfies check" {
  write_legacy_flat_lock 3
  run bash "${SCRIPT}" check 3
  [ "${status}" -ne 0 ]
}

@test "purge removes flat legacy locks with a warning" {
  write_legacy_flat_lock 3
  run bash "${SCRIPT}" list
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"legacy"* ]]
  [ ! -f "${TMP_HOME}/.claude/merge-locks/pr-3.lock" ]
}

# ── list / status / purge across repos ───────────────────────────────────────

@test "list shows the repo alongside the PR number" {
  run bash "${SCRIPT}" authorize 3 "ok" --repo acme/widgets
  run bash "${SCRIPT}" authorize 3 "ok" --repo acme/gadgets
  run bash "${SCRIPT}" list
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"acme/widgets#3"* ]]
  [[ "${output}" == *"acme/gadgets#3"* ]]
}

@test "status reports the repo it checked" {
  run bash "${SCRIPT}" authorize 3 "ok"
  run bash "${SCRIPT}" status 3
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"acme/widgets#3 is authorized"* ]]

  run bash "${SCRIPT}" status 3 --repo acme/gadgets
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"acme/gadgets#3 is NOT authorized"* ]]
}

@test "purge walks nested repo directories" {
  local ttl
  ttl=$(grep -m1 "^LOCK_TTL_SECONDS=" "${SCRIPT}" | cut -d= -f2 | grep -o '^[0-9]*')
  local dir="${TMP_HOME}/.claude/merge-locks/acme/gadgets"
  mkdir -p "${dir}"
  {
    echo "PR_NUMBER=9"
    echo "REPO=acme/gadgets"
    echo "AUTHORIZED_BY=tester"
    echo "TIMESTAMP=$(($(date +%s) - ttl - 60))"
    echo "REASON=test"
  } >"${dir}/pr-9.lock"

  run bash "${SCRIPT}" list
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Purged expired lock for acme/gadgets#9"* ]]
  [ ! -f "${dir}/pr-9.lock" ]
}
