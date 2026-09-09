#!/usr/bin/env bash
# View blocked command attempts

set -euo pipefail

LOG_FILE="${HOME}/.claude/blocked-commands.log"

if [[ ! -f "${LOG_FILE}" ]]; then
  echo "No blocked commands logged yet."
  exit 0
fi

case "${1:-show}" in
  show)
    echo "=== Blocked Command Attempts ==="
    cat "${LOG_FILE}"
    ;;
  count)
    # Assigned separately (rather than inline) so `wc`'s exit status is not
    # masked by the surrounding substitution -- the form SC2312 asks for.
    # LOG_FILE is guaranteed to exist by the guard above.
    count=$(wc -l <"${LOG_FILE}")
    echo "Total blocked attempts: ${count// /}"
    ;;
  today)
    today=$(date -u +%Y-%m-%d)
    echo "=== Blocked Today (${today}) ==="
    grep "^${today}" "${LOG_FILE}" || echo "None"
    ;;
  clear)
    echo "Clearing log..."
    rm -f "${LOG_FILE}"
    echo "Log cleared."
    ;;
  *)
    echo "Usage: $0 {show|count|today|clear}"
    ;;
esac
