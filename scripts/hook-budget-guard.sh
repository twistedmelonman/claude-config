#!/usr/bin/env bash
# Hook: Session/subagent spend circuit-breaker.
#
# WHY THIS IS NOT A LOOP DETECTOR (read before "improving" it).
#
# This guard exists because of session 91ef0da0 (huddle-transcribe,
# 2026-08-31), which cost $42.04 in 2h16m. That session was reported as "a
# recursive loop of review cycles". Forensics showed it was not one:
#
#   run-review.sh invocations .......... 3
#   pre-merge-review.sh invocations .... 0
#   reviewer agents spawned ............ 2 (one parallel batch, never re-run)
#   git commit --amend ................. 0
#   max spawn depth .................... 1 (no subagent spawned an agent)
#   max assistant turns between two
#     consecutive human messages ....... 33
#
# That last number is the important one. Every cycle-counting design -- "halt
# after N review rounds", "halt after N turns without user input" -- is tuned
# somewhere in the 50-100 range. All of them would have watched this session
# burn $42 and fired zero times. A round counter cannot see this failure
# because the failure was not repetition.
#
# What it actually was, from cost-state:
#
#   cache_read ..... 51,204,875 tokens   (~93% of the bill)
#   cache_create ......  799,936
#   output ............  271,215
#   input .............   25,788
#
# A 189:1 read-to-write ratio. The session paid to re-read a large context on
# every one of ~370 API turns. Cost is not driven by how many cycles run; it
# is driven by (turns x context size), and context grows monotonically within
# a turn chain. Two hours of forward progress at 200K context costs more than
# ten review rounds at 20K.
#
# So the metric here is spend, measured in cache-read tokens, not cycles.
# A guard on spend catches a diverging loop as a side effect -- a loop is
# just one way to spend a lot -- while a guard on cycles cannot catch
# expensive linear work. Spend strictly dominates as a trigger.
#
# WHERE THE MONEY WENT, AND HENCE WHY SubagentStop IS THE PRIMARY HOOK.
# Per-thread attribution (deduped by requestId):
#
#   a78eb5a7  general-purpose  "fix review findings"  134 req  19.20M  38%
#   main thread                                        97 req  12.09M  24%
#   a360be39  security reviewer                        54 req   3.66M   7%
#   aa023f3a  general-purpose  build #2                31 req   3.09M   6%
#   a962c964  adversarial reviewer                     30 req   2.15M   4%
#   a6447e0d  general-purpose  build #1 (KILLED)       22 req   1.63M   3%
#
# ONE subagent was 46% of the session. It edited a single 1029-line file 30
# times and re-ran the test suite 29 times, each against a 100K-204K context.
# Subagents are where the spend concentrates, they start cold (no cache to
# amortize), and the parent cannot see their burn until they return. A
# per-subagent ceiling is the single highest-value check in this file.
#
# WHY THE HOOK MUST PARSE A TRANSCRIPT AT ALL.
# Cumulative token usage and cost are deliberately NOT exposed to hooks --
# not in the hook input JSON, not in the environment. There is no
# $CLAUDE_SESSION_COST. The only machine-readable record of spend available
# to a hook is the transcript's per-message `usage` object, so this script
# sums it. Verified reproducible: summing cache_read_input_tokens over
# requestId-deduped entries of 91ef0da0's transcript yields 12,092,622 for
# the main thread, matching the independent cost-state figure.
#
# Called by: SubagentStop and Stop hooks (see settings.json).

set -euo pipefail
unset CDPATH

input=$(cat)

# FAIL OPEN ON UNPARSEABLE INPUT. `set -e` plus a jq parse error would abort
# the script with jq's exit 5. That does not block (only 2 blocks), but it
# prints a parse error on every malformed payload and leaves the guard's
# behaviour dependent on an exit code it never chose. Default to empty and
# fall through to the no-op arm instead.
event=$(printf '%s\n' "${input}" | jq -r '.hook_event_name // empty' 2>/dev/null) || event=""
[[ -n "${event}" ]] || exit 0

# THE RELEASE VALVE, AND WHY IT IS THE FIRST THING WE CHECK.
#
# Claude Code caps consecutive Stop/SubagentStop blocks. From the binary
# (v2.1.252): `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP??8`, with the accompanying
# guidance string "For Stop/SubagentStop hooks, check stop_hook_active in the
# input and return success while it's true."
#
# Note that the cap covers BOTH events. Public write-ups claiming
# SubagentStop is uncapped are wrong; the default-8 expression is shared.
#
# Honoring this is not politeness, it is correctness. A guard that keeps
# blocking past the cap gets overridden by the harness with a warning, which
# means the block silently stops working exactly when it matters most. Worse,
# a budget guard that blocks unconditionally would itself become an expensive
# loop -- each block costs a full-context turn to re-read the refusal. Return
# success while stop_hook_active is true and let the turn end; the ceiling
# has already been reported once, which is the whole point.
_stop_active=$(printf '%s\n' "${input}" | jq -r '.stop_hook_active // false' 2>/dev/null) || _stop_active=false
if [[ "${_stop_active}" == 'true' ]]; then
  exit 0
fi

# Thresholds. Env-overridable so a genuinely large task can raise them for
# one session without editing this file, and so the bats suite can drive
# small values instead of synthesizing 5M-token fixtures.
#
# Defaults are set from measurement, deliberately below what a runaway
# session actually spends so they fire DURING it rather than after:
#
#   subagent 2.3M -- derived, not guessed. Measured across 447 real subagent
#                   transcripts on 2026-09-02: a well-behaved agent (finished
#                   within 5 min, under the prior 5M ceiling, ran >=15s so
#                   startup does not dominate the rate; n=281) averages
#                   416,286 tokens/min. Five minutes of that is 2.08M; +10%
#                   buffer gives 2.3M.
#
#                   WHY A RATE, NOT A TOTAL: averaging the totals of agents
#                   that happened to finish quickly lets a swarm of 20-second
#                   lookups drag the mean down, throttling exactly the agents
#                   the cap should permit.
#
#                   This is the token expression of a 5-minute lifetime, so
#                   the two limits describe one constraint instead of one
#                   silently dominating. Confirmed against the same corpus:
#                   of the 93 agents this ceiling blocks, 85 (91%) also ran
#                   over 5 minutes -- both limits catch the same population.
#
#                   The filter is not doing the work; varying it (30-300s,
#                   <2M cap, no runaway cap) moves the answer by under 4%.
#                   For scale, the cheapest of all 447 agents spent 32,996
#                   tokens, so a ceiling in the tens of thousands sits below
#                   the observed floor and would block every agent measured.
#
#   session 25M  -- trips at roughly 16:10, about an hour before the
#                   expensive half of the session. The 10M soft-warn lands
#                   earlier still, as a nudge with no block.
BUDGET_SUBAGENT_TOKENS="${BUDGET_SUBAGENT_TOKENS:-2300000}"
BUDGET_SESSION_TOKENS="${BUDGET_SESSION_TOKENS:-25000000}"
BUDGET_SESSION_WARN_TOKENS="${BUDGET_SESSION_WARN_TOKENS:-10000000}"

# Sum cache_read + cache_creation + input + output over a transcript.
#
# Takes a mode: "live" counts only entries after the last compaction boundary
# (the spend the session is still carrying); "lifetime" counts the whole file.
#
# WHY COMPACTION RESETS THE LIVE COUNT.
# Compaction rewrites the context in place -- same session, same transcript
# file -- and the pre-compaction `usage` entries stay on disk forever. Summing
# them unconditionally bills the session for context it no longer has, so the
# guard tightens as the operator does the exact thing that relieves the
# pressure. Measured on a real auto-compacted session (huddle-transcribe,
# 2026-09-08, 167,127 -> 11,604 tokens): the whole-file sum reads 18.5M and
# trips the 10M soft-warn, while the post-boundary sum is 5.4M. 13.1M of the
# reported spend was context that had already been dropped.
#
# Both triggers reset. `trigger` is "manual" (/compact) or "auto", and auto is
# the one that matters most here -- the harness compacts on its own, so a
# lifetime-only count penalises the operator for a decision they never made.
# The justification is the same either way: this guard's own model is that
# cost is (turns x context size), and after a boundary the context genuinely
# is smaller, whoever shrank it.
#
# LIFETIME IS STILL COMPUTED, but only to REPORT, never to trigger. Both
# thresholds gate on live spend; when lifetime differs it is appended to the
# message so the full cost of a long session is never hidden. Warning on
# lifetime was tried first and rejected on measurement -- see the note above
# the soft-warn branch.
#
# Only `subtype` is read from the boundary. compactMetadata carries trigger,
# preTokens, postTokens and cumulativeDroppedTokens, but none of them are
# needed to locate the split, and depending on their shape would couple this
# guard to a payload that has already changed once.
#
# WHY DEDUP BY requestId: the transcript stores a retried or streamed request
# under the same requestId more than once (in 91ef0da0, 65 entries appeared
# twice and 17 three times). Summing raw lines therefore overcounts spend by
# roughly 2x and would fire the guard at half the stated ceiling. Falls back
# to .message.id, then to the line's own uuid, so an entry with no requestId
# is counted exactly once rather than dropped.
#
# WHY jq -s IS NOT USED: `jq -s` must hold the whole file in memory, and
# these transcripts reach megabytes. `jq -n` with `inputs` streams instead.
# `? // empty` swallows malformed lines -- the transcript is written live and
# is NOT guaranteed flushed at hook time, so a truncated final line is
# expected, not exceptional.
#
# Dedup runs AFTER the boundary split, so a requestId that appears on both
# sides of a compaction still counts once within the live window.
_sum_tokens() {
  local path="$1" mode="${2:-live}"
  [[ -r "${path}" ]] || {
    printf '0\n'
    return 0
  }
  jq -nr --arg mode "${mode}" '
    [ inputs? // empty | select(type == "object") ] as $all
    | ( if $mode == "lifetime" then 0
        else ( [ $all | to_entries[]
                 | select(.value.type? == "system")
                 | select(.value.subtype? == "compact_boundary")
                 | .key ] | last // -1 ) + 1
        end ) as $from
    | [ $all[$from:][]
      | select(.message? | type == "object")
      | select(.message.usage? | type == "object")
      | { k: ((.requestId // .message.id // .uuid) | tostring)
        , t: ( (.message.usage.cache_read_input_tokens // 0)
             + (.message.usage.cache_creation_input_tokens // 0)
             + (.message.usage.input_tokens // 0)
             + (.message.usage.output_tokens // 0) )
        }
    ]
    | group_by(.k) | map(.[0].t) | add // 0
    | floor
  ' "${path}" 2>/dev/null || printf '0\n'
}

# Render a token count as millions, for messages a human reads under time
# pressure. "19.2M" is legible; "19203471" is not.
_fmt_m() {
  awk -v n="$1" 'BEGIN { printf "%.1fM", n / 1000000 }'
}

case "${event}" in
  SubagentStop)
    # Per-subagent ceiling. This is the check that would have mattered most
    # in 91ef0da0: it fires on the 19.2M agent and stays silent on the three
    # agents under 3.1M.
    agent_transcript=$(printf '%s\n' "${input}" | jq -r '.agent_transcript_path // empty' 2>/dev/null) || agent_transcript=""
    agent_type=$(printf '%s\n' "${input}" | jq -r '.agent_type // "unknown"' 2>/dev/null) || agent_type="unknown"
    [[ -n "${agent_transcript}" ]] || exit 0

    spent=$(_sum_tokens "${agent_transcript}")
    [[ "${spent}" -gt "${BUDGET_SUBAGENT_TOKENS}" ]] || exit 0

    _spent_h=$(_fmt_m "${spent}")
    _ceil_h=$(_fmt_m "${BUDGET_SUBAGENT_TOKENS}")

    # Blocking a SubagentStop does not roll back what the agent already did,
    # and must not imply it did. The agent's work stands; what is being
    # refused is the parent silently accepting an unbounded bill and
    # dispatching the next one. So the message is addressed to the PARENT's
    # next decision, and it names the specific 91ef0da0 failure the parent
    # is most likely repeating -- re-dispatching a fresh cold agent to
    # continue the same work, which pays the ~40K-token instruction re-read
    # entry cost again and starts a new unbounded budget.
    {
      printf '🛑 SUBAGENT BUDGET EXCEEDED\n\n'
      printf 'Agent type: %s\n' "${agent_type}"
      printf 'This agent spent %s tokens (ceiling %s).\n\n' \
        "${_spent_h}" "${_ceil_h}"
      printf 'Its work is done and still stands. Do NOT re-dispatch a fresh\n'
      printf 'agent to continue it -- a cold agent re-reads its whole\n'
      printf 'instruction set (~40K tokens in the measured case) before doing\n'
      printf 'anything, then starts its own unbounded budget.\n\n'
      printf 'Before spending more, answer these in your next message:\n'
      printf '  1. What did this agent actually land? Verify it, do not assume.\n'
      printf '  2. Is the REMAINING work smaller than what was just done?\n'
      printf '     If not, the task was mis-scoped -- say so and stop.\n'
      printf '  3. Report the spend to the user and let them choose.\n\n'
      printf 'Raise the ceiling for this session only if the user asks:\n'
      printf '  BUDGET_SUBAGENT_TOKENS=%s\n' "$((BUDGET_SUBAGENT_TOKENS * 2))"
    } >&2
    exit 2
    ;;

  Stop)
    transcript=$(printf '%s\n' "${input}" | jq -r '.transcript_path // empty' 2>/dev/null) || transcript=""
    [[ -n "${transcript}" ]] || exit 0

    # Two numbers, two jobs. `spent` is post-compaction spend and gates the
    # hard block; `lifetime` is the whole file and drives the soft warn, so a
    # repeatedly-compacted session still surfaces instead of running silent.
    spent=$(_sum_tokens "${transcript}" live)
    lifetime=$(_sum_tokens "${transcript}" lifetime)
    _spent_h=$(_fmt_m "${spent}")
    _life_h=$(_fmt_m "${lifetime}")
    _ceil_h=$(_fmt_m "${BUDGET_SESSION_TOKENS}")

    # Only worth mentioning when compaction actually moved the number.
    _compact_note=""
    if [[ "${lifetime}" -gt "${spent}" ]]; then
      _compact_note=" since last compaction; ${_life_h} lifetime"
    fi

    # NOTE ON SCOPE: this counts the MAIN thread only. Subagent spend lives
    # in separate transcripts under <session>/subagents/ and is caught by the
    # SubagentStop arm above, per-agent. Do not "fix" this by summing the
    # subagent files in here -- in 91ef0da0 the main thread was 12.09M of a
    # 51.2M session, so a main-thread ceiling of 25M is intentionally a
    # ceiling on MAIN-THREAD burn, and folding in subagent totals would
    # change what the number means without changing the number.
    if [[ "${spent}" -gt "${BUDGET_SESSION_TOKENS}" ]]; then
      {
        printf '🛑 SESSION BUDGET EXCEEDED\n\n'
        printf 'Main thread has spent %s tokens%s (ceiling %s).\n\n' \
          "${_spent_h}" "${_compact_note}" "${_ceil_h}"
        printf 'At this context size each further turn costs real money before\n'
        printf 'it does any work. Continuing is the expense.\n\n'
        printf 'Do NOT keep working. In your next message:\n'
        printf '  1. State what is DONE and verified, and what is NOT.\n'
        printf '  2. State the spend and hand the user the decision.\n'
        printf '  3. If work remains, propose /compact or a FRESH session --\n'
        printf '     both drop the accumulated context that is making every\n'
        printf '     turn expensive, and this ceiling counts only what has\n'
        printf '     been spent since the last compaction.\n\n'
        printf 'Raise for this session only if the user asks:\n'
        printf '  BUDGET_SESSION_TOKENS=%s\n' "$((BUDGET_SESSION_TOKENS * 2))"
      } >&2
      exit 2
    fi

    # Soft warning: advisory, never blocks. Exists so the first signal a
    # human gets is not a hard stop. Goes to stdout as systemMessage (shown
    # to the user) rather than stderr, because there is no decision for the
    # model to make here yet -- blocking on a warning is how a guard becomes
    # the thing burning the tokens.
    #
    # WARN ON LIVE SPEND, NOT LIFETIME -- measured, not assumed.
    #
    # The first draft of this fix warned on lifetime, reasoning that a session
    # which has compacted through 40M should still be visible. Checked against
    # all 19 compacted transcripts on this machine: 16 of them exceed the 10M
    # warn on lifetime while only 1 exceeds it on live spend. Two sit above
    # the 25M HARD ceiling on lifetime (25.6M and 24.3M) while actually
    # carrying 8.4M and 8.0M.
    #
    # A warning that fires on essentially every session that has ever
    # compacted is not a signal, it is the nagging this fix exists to remove,
    # and it trains the operator to raise BUDGET_SESSION_WARN_TOKENS until the
    # warn is dead for real runaways too. Lifetime stays in the message when
    # it differs, so the number is never hidden -- it just does not trigger.
    if [[ "${spent}" -gt "${BUDGET_SESSION_WARN_TOKENS}" ]]; then
      if [[ -n "${_compact_note}" ]]; then
        _warn_msg="💸 Session spend: ${_life_h} tokens lifetime, ${_spent_h} since last compaction (hard stop at ${_ceil_h})."
      else
        _warn_msg="💸 Session spend: ${_spent_h} tokens (hard stop at ${_ceil_h})."
      fi
      jq -nc --arg m "${_warn_msg}" '{systemMessage: $m}'
    fi
    exit 0
    ;;

  *)
    # Unknown event: do nothing. This hook is wired to two events; if it is
    # ever attached to a third, silence is the safe default.
    exit 0
    ;;
esac
