#!/usr/bin/env bats
# Tests for merge-lock mobile authorization: enroll / signers / redeem (issue #509).
# Run: bats tests/test_merge_lock_mobile_auth.bats

SCRIPT="${BATS_TEST_DIRNAME}/../hooks/merge-lock.sh"
SIGNER="${BATS_TEST_DIRNAME}/../scripts/merge-lock-sign.sh"

setup() {
  TMP_HOME="$(mktemp -d)"
  readonly TMP_HOME
  export HOME="${TMP_HOME}"

  # Locks are keyed on repo + PR; stub gh so cwd resolution stays offline.
  mkdir -p "${TMP_HOME}/bin"
  printf '#!/usr/bin/env bash\necho acme/widgets\n' >"${TMP_HOME}/bin/gh"
  chmod +x "${TMP_HOME}/bin/gh"
  export PATH="${TMP_HOME}/bin:${PATH}"

  # A throwaway "phone" keypair. Generated per test so nothing leaks between
  # them and no real key is ever involved.
  mkdir -p "${TMP_HOME}/.ssh"
  PHONE_KEY="${TMP_HOME}/.ssh/phone"
  ssh-keygen -t ed25519 -N "" -C "phone@test" -f "${PHONE_KEY}" -q
  export MERGE_LOCK_KEY="${PHONE_KEY}"

  SIGNERS="${TMP_HOME}/.claude/merge-locks/allowed_signers"
}

teardown() {
  rm -rf "${TMP_HOME}"
}

lock_file() {
  echo "${TMP_HOME}/.claude/merge-locks/${2:-acme/widgets}/pr-$1.lock"
}

enroll_phone() {
  bash "${SCRIPT}" enroll "${PHONE_KEY}.pub" phone
}

# Build a token directly, so tests can control the payload without going
# through the signing script.
make_token() {
  local payload="$1"
  local key="${2:-${PHONE_KEY}}"
  local sig
  sig=$(printf '%s' "${payload}" | ssh-keygen -Y sign -n merge-lock -f "${key}" - 2>/dev/null)
  printf '%s\n%s\n' "${payload}" "${sig}" | base64 | tr -d '\n'
}

# --- enroll ------------------------------------------------------------------

@test "enroll registers a public key" {
  run enroll_phone
  [ "${status}" -eq 0 ]
  [ -f "${SIGNERS}" ]
  grep -q "^phone ssh-ed25519 " "${SIGNERS}"
}

@test "enroll is idempotent for the same key" {
  enroll_phone
  run enroll_phone
  [ "${status}" -eq 0 ]
  [ "$(grep -c "ssh-ed25519" "${SIGNERS}")" -eq 1 ]
}

@test "enroll rejects a missing key file" {
  run bash "${SCRIPT}" enroll "${TMP_HOME}/nope.pub" phone
  [ "${status}" -ne 0 ]
  [ ! -f "${SIGNERS}" ]
}

@test "enroll rejects a file that is not a public key" {
  echo "just some text" >"${TMP_HOME}/not-a-key.pub"
  run bash "${SCRIPT}" enroll "${TMP_HOME}/not-a-key.pub" phone
  [ "${status}" -ne 0 ]
}

@test "enroll rejects a principal containing whitespace" {
  # Whitespace would shift the allowed_signers columns and change which key
  # the entry actually trusts.
  run bash "${SCRIPT}" enroll "${PHONE_KEY}.pub" "my phone"
  [ "${status}" -ne 0 ]
}

@test "signers lists an enrolled key" {
  enroll_phone
  run bash "${SCRIPT}" signers
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"phone"* ]]
  [[ "${output}" == *"ssh-ed25519"* ]]
}

@test "signers reports none when nothing is enrolled" {
  run bash "${SCRIPT}" signers
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"(none)"* ]]
}

# --- redeem: happy path ------------------------------------------------------

@test "redeem creates a lock for the repo and PR named in the token" {
  enroll_phone
  token=$(make_token "v1 acme/widgets#42 exp=$(($(date +%s) + 600))")
  run bash "${SCRIPT}" redeem "${token}"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 42)" ]
  grep -q "^PR_NUMBER=42$" "$(lock_file 42)"
  grep -q "^REPO=acme/widgets$" "$(lock_file 42)"
  grep -q "^REASON=mobile authorization by phone$" "$(lock_file 42)"
}

@test "redeem honors the token's repo over the cwd repo" {
  # The stub gh always answers acme/widgets; the token says otherwise, and the
  # token must win. This is the #471 failure mode in reverse.
  enroll_phone
  token=$(make_token "v1 other/project#7 exp=$(($(date +%s) + 600))")
  run bash "${SCRIPT}" redeem "${token}"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 7 other/project)" ]
  [ ! -f "$(lock_file 7)" ]
}

@test "redeem tolerates whitespace and newlines inside the token" {
  enroll_phone
  token=$(make_token "v1 acme/widgets#42 exp=$(($(date +%s) + 600))")
  wrapped=$(printf '%s\n  %s\n' "${token:0:40}" "${token:40}")
  run bash "${SCRIPT}" redeem "${wrapped}"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 42)" ]
}

# --- redeem: rejection cases -------------------------------------------------

@test "redeem refuses when no signers are enrolled" {
  token=$(make_token "v1 acme/widgets#42 exp=$(($(date +%s) + 600))")
  run bash "${SCRIPT}" redeem "${token}"
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 42)" ]
}

@test "redeem rejects a token signed by an unenrolled key" {
  enroll_phone
  ssh-keygen -t ed25519 -N "" -C "attacker" -f "${TMP_HOME}/.ssh/evil" -q
  token=$(make_token "v1 acme/widgets#42 exp=$(($(date +%s) + 600))" "${TMP_HOME}/.ssh/evil")
  run bash "${SCRIPT}" redeem "${token}"
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 42)" ]
}

@test "redeem rejects a token whose payload was altered after signing" {
  enroll_phone
  token=$(make_token "v1 acme/widgets#42 exp=$(($(date +%s) + 600))")
  # Swap the PR number in the decoded payload, then re-encode with the
  # original signature attached.
  decoded=$(printf '%s' "${token}" | base64 -d)
  tampered=$(printf '%s' "${decoded}" | sed '1s/#42/#99/')
  bad_token=$(printf '%s' "${tampered}" | base64 | tr -d '\n')
  run bash "${SCRIPT}" redeem "${bad_token}"
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 99)" ]
  [ ! -f "$(lock_file 42)" ]
}

@test "redeem rejects an expired token" {
  enroll_phone
  token=$(make_token "v1 acme/widgets#42 exp=$(($(date +%s) - 60))")
  run bash "${SCRIPT}" redeem "${token}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"expired"* ]]
  [ ! -f "$(lock_file 42)" ]
}

@test "redeem rejects a token whose lifetime exceeds the maximum" {
  enroll_phone
  token=$(make_token "v1 acme/widgets#42 exp=$(($(date +%s) + 86400 * 30))")
  run bash "${SCRIPT}" redeem "${token}"
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 42)" ]
}

@test "redeem rejects an unknown token version" {
  enroll_phone
  token=$(make_token "v2 acme/widgets#42 exp=$(($(date +%s) + 600))")
  run bash "${SCRIPT}" redeem "${token}"
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 42)" ]
}

@test "redeem rejects a token with a traversing repo slug" {
  enroll_phone
  token=$(make_token "v1 ../../etc#42 exp=$(($(date +%s) + 600))")
  run bash "${SCRIPT}" redeem "${token}"
  [ "${status}" -ne 0 ]
}

@test "redeem rejects a token with a zero PR number" {
  enroll_phone
  token=$(make_token "v1 acme/widgets#0 exp=$(($(date +%s) + 600))")
  run bash "${SCRIPT}" redeem "${token}"
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 0)" ]
}

@test "redeem rejects a token that is not valid base64" {
  enroll_phone
  run bash "${SCRIPT}" redeem "!!!not-base64!!!"
  [ "${status}" -ne 0 ]
}

@test "redeem rejects a token missing its signature" {
  enroll_phone
  bare=$(printf 'v1 acme/widgets#42 exp=%s\n' "$(($(date +%s) + 600))" | base64 | tr -d '\n')
  run bash "${SCRIPT}" redeem "${bare}"
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 42)" ]
}

# --- replay ------------------------------------------------------------------

@test "a token cannot be redeemed twice" {
  enroll_phone
  token=$(make_token "v1 acme/widgets#42 exp=$(($(date +%s) + 600))")
  run bash "${SCRIPT}" redeem "${token}"
  [ "${status}" -eq 0 ]
  rm -f "$(lock_file 42)"
  run bash "${SCRIPT}" redeem "${token}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"already been redeemed"* ]]
  [ ! -f "$(lock_file 42)" ]
}

# --- signing script ----------------------------------------------------------

@test "the signing script produces a token redeem accepts" {
  enroll_phone
  token=$(bash "${SIGNER}" acme/widgets 42 2>/dev/null)
  run bash "${SCRIPT}" redeem "${token}"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 42)" ]
}

@test "the signing script refuses a lifetime past the maximum" {
  run bash "${SIGNER}" acme/widgets 42 99999
  [ "${status}" -ne 0 ]
}

@test "the signing script refuses an invalid repo slug" {
  run bash "${SIGNER}" "not-a-slug" 42
  [ "${status}" -ne 0 ]
}

@test "the signing script refuses an invalid PR number" {
  run bash "${SIGNER}" acme/widgets 0
  [ "${status}" -ne 0 ]
}

@test "the signing script reports a missing key file" {
  export MERGE_LOCK_KEY="${TMP_HOME}/.ssh/absent"
  run bash "${SIGNER}" acme/widgets 42
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ssh-keygen"* ]]
}
