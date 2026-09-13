#!/usr/bin/env bash
# merge-lock-sign.sh — produce a signed mobile merge-authorization token.
#
# Runs on whatever device holds the private key (phone, tablet, second
# laptop). It never touches the merge-locks directory and never needs to: the
# output is a text token you paste to the Claude Code session, which redeems
# it with `merge-lock.sh redeem <token>`.
#
#   ./merge-lock-sign.sh owner/repo 42              # default 30 minute window
#   ./merge-lock-sign.sh owner/repo 42 120          # 2 hour window
#
# The key must already be enrolled on the laptop:
#   merge-lock.sh enroll ~/.ssh/merge_lock_phone.pub phone
#
# Only the matching public key can be enrolled, so a token this script
# produces authorizes exactly the one repo and PR named on the command line,
# and only until it expires.

set -euo pipefail
unset CDPATH

KEY_FILE="${MERGE_LOCK_KEY:-${HOME}/.ssh/merge_lock_phone}"
SIG_NAMESPACE="merge-lock"
# Not locally authoritative. The laptop enforces the real ceiling via
# TOKEN_MAX_LIFETIME_SECONDS in merge-lock.sh (86400 seconds = 24 hours); this
# mirrors it only so an over-long request fails here instead of after a paste.
# If that constant moves, this must move with it.
SHARED_MAX_LIFETIME_MINUTES=1440 # 24 hours

usage() {
  echo "Usage: $0 <owner/repo> <pr-number> [minutes]" >&2
  echo "" >&2
  echo "  minutes defaults to 30, maximum ${SHARED_MAX_LIFETIME_MINUTES}." >&2
  echo "  Key file: ${KEY_FILE} (override with MERGE_LOCK_KEY)" >&2
  exit 1
}

REPO="${1:-}"
PR="${2:-}"
MINUTES="${3:-30}"

[[ -n "${REPO}" && -n "${PR}" ]] || usage

if [[ ! "${REPO}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Error: '${REPO}' is not a valid OWNER/NAME repo slug." >&2
  exit 1
fi
if [[ ! "${PR}" =~ ^[0-9]+$ ]] || [[ "${PR}" -le 0 ]]; then
  echo "Error: '${PR}' is not a valid PR number." >&2
  exit 1
fi
if [[ ! "${MINUTES}" =~ ^[0-9]+$ ]] || [[ "${MINUTES}" -le 0 ]]; then
  echo "Error: '${MINUTES}' is not a valid number of minutes." >&2
  exit 1
fi
# Reject here rather than clamping: the laptop would refuse the token anyway,
# and finding that out after pasting it is a wasted round trip.
if [[ "${MINUTES}" -gt "${SHARED_MAX_LIFETIME_MINUTES}" ]]; then
  echo "Error: ${MINUTES} minutes exceeds the ${SHARED_MAX_LIFETIME_MINUTES}-minute maximum." >&2
  exit 1
fi

if [[ ! -f "${KEY_FILE}" ]]; then
  echo "Error: no signing key at ${KEY_FILE}" >&2
  echo "" >&2
  echo "Create one, then enroll its public half on the laptop:" >&2
  echo "  ssh-keygen -t ed25519 -f ${KEY_FILE} -C merge-lock-phone" >&2
  echo "  merge-lock.sh enroll ${KEY_FILE}.pub phone" >&2
  exit 1
fi

EXPIRY=$(($(date +%s) + MINUTES * 60))
PAYLOAD="v1 ${REPO}#${PR} exp=${EXPIRY}"

SIG=$(printf '%s' "${PAYLOAD}" | ssh-keygen -Y sign -n "${SIG_NAMESPACE}" -f "${KEY_FILE}" - 2>/dev/null)
if [[ -z "${SIG}" ]]; then
  echo "Error: signing failed. Is ${KEY_FILE} a valid private key?" >&2
  exit 1
fi

# base64 -w0 is GNU-only; macOS and BusyBox need the tr fallback, and this
# script is expected to run on whatever the human happens to be holding.
TOKEN=$(printf '%s\n%s\n' "${PAYLOAD}" "${SIG}" | base64 | tr -d '\n')

echo "${TOKEN}"
echo "" >&2
echo "Token authorizes ${REPO}#${PR} for ${MINUTES} minute(s)." >&2
echo "Paste it to Claude and ask it to run: merge-lock.sh redeem <token>" >&2
