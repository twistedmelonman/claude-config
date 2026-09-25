export const meta = {
  name: 'issue-convergence-loop',
  description: 'Work an issue backlog until follow-ups it spawns are also done, or the round cap is hit',
  whenToUse:
    'A backlog where fixing issues reliably spawns follow-up issues, and you want the follow-ups worked in the same effort rather than accumulating.',
  phases: [
    { title: 'Fix', detail: 'one agent per issue, isolated worktrees' },
    { title: 'Verify', detail: 'adversarially confirm each fix and harvest follow-ups' },
    { title: 'Integrate', detail: 'fetch verified branches out of their worktrees' },
    { title: 'Triage', detail: 'decide which follow-ups enter the next round' },
  ],
}

// ---------------------------------------------------------------------------
// The convergence contract
// ---------------------------------------------------------------------------
// A round takes a queue of issues, fixes each, verifies each fix, integrates
// what passed, and collects the follow-up concerns the work exposed. The loop
// ends on whichever fires first:
//
//   converged       nothing left to work                    (success)
//   diverging       spawn_ratio >= 1.0 two rounds running   (escalate)
//   no_progress     a round landed zero fixes               (stuck)
//   queue_explosion queue grew past 2x the seed set         (gate too loose)
//   capped          MAX_ROUNDS reached                      (fuse)
//
// spawn_ratio = admitted follow-ups / fixes landed. It is the real stopping
// rule; the round cap is only a fuse. A cap tells you the loop stopped, not
// whether the work was paying. Measured on the first real run of this script:
// 24 fixes produced 63 follow-ups (2.6x amplification, spawn_ratio 1.62 after
// deferring cosmetics) -- provably diverging, and invisible to a design that
// counted only rounds.
//
// Residue is always reported, never silently dropped.
// ---------------------------------------------------------------------------

const MAX_ROUNDS = args?.maxRounds ?? 3
const REPO = args?.repo ?? '(repo not specified — pass args.repo)'
const SEED = args?.issues ?? []

const FIX_SCHEMA = {
  type: 'object',
  required: ['issue', 'outcome', 'summary', 'followUps'],
  properties: {
    issue: { type: 'number' },
    outcome: {
      type: 'string',
      enum: ['fixed', 'no_change_needed', 'blocked'],
      description:
        'no_change_needed when the issue describes intended behavior or a stale/false-positive finding; blocked when the fix needs a decision you cannot make.',
    },
    summary: { type: 'string', description: 'What changed, or why nothing needed to change.' },
    filesTouched: { type: 'array', items: { type: 'string' } },
    testsAdded: { type: 'array', items: { type: 'string' } },
    commit: {
      type: 'string',
      description:
        'SHA of the commit you made in your worktree, or empty if you changed nothing. Required whenever filesTouched is non-empty.',
    },
    branch: { type: 'string', description: 'Branch name you committed on, from `git rev-parse --abbrev-ref HEAD`.' },
    worktreePath: { type: 'string', description: 'Absolute path of your worktree, from `git rev-parse --show-toplevel`.' },
    followUps: {
      type: 'array',
      description: 'Genuinely NEW concerns this work exposed. Empty is the expected common answer.',
      items: {
        type: 'object',
        required: ['title', 'rationale', 'severity'],
        properties: {
          title: { type: 'string' },
          rationale: { type: 'string' },
          severity: { type: 'string', enum: ['blocking', 'real', 'cosmetic'] },
          location: { type: 'string' },
        },
      },
    },
  },
}

const VERIFY_SCHEMA = {
  type: 'object',
  required: ['holds', 'reasoning'],
  properties: {
    holds: { type: 'boolean', description: 'false if the fix is wrong, incomplete, or breaks something' },
    reasoning: { type: 'string' },
    newConcerns: {
      type: 'array',
      items: {
        type: 'object',
        required: ['title', 'rationale', 'severity'],
        properties: {
          title: { type: 'string' },
          rationale: { type: 'string' },
          severity: { type: 'string', enum: ['blocking', 'real', 'cosmetic'] },
          location: { type: 'string' },
        },
      },
    },
  },
}

// Repo-specific context, supplied by the caller. Everything here propagates
// verbatim to every agent, so an error is an error made once and inherited N
// times -- most damagingly an incomplete verification command, which makes every
// agent's "no new failures" claim true of one suite and false of the repo.
//
// verifyCommand MUST run every suite. Enumerate them by scanning, not recall:
//   ls tests/ scripts/tests/ test/ spec/ 2>/dev/null
//   grep -rl 'bats\|pytest\|jest\|go test' --include='*.sh' --include='Makefile' .
//
// knownFailures pins the pre-existing baseline so agents do not chase failures
// they did not cause. Get it by running verifyCommand on a clean checkout of the
// base commit -- not from memory, and not from a tree that already has edits.
const FETCH_SCHEMA = {
  type: 'object',
  required: ['branchesRetrieved', 'fetchFailures'],
  properties: {
    branchesRetrieved: {
      type: 'array',
      items: { type: 'string' },
      description: 'Branch names that now resolve in the orchestrating repo.',
    },
    fetchFailures: {
      type: 'array',
      items: { type: 'string' },
      description: 'Branches whose fetch or rev-parse failed, with the error.',
    },
  },
}

const REPO_PATH = args?.repoPath ?? '.'
const VERIFY_COMMAND = args?.verifyCommand ?? 'echo "NO VERIFY COMMAND SUPPLIED"; false'
const KNOWN_FAILURES = args?.knownFailures ?? 'None recorded. Any failure is yours; investigate it.'
const HOUSE_RULES = args?.houseRules ?? ''

const REPO_CONTEXT = `
Repo: ${REPO_PATH}

VERIFICATION COMMAND — run all of this, not a subset. A repo often has more than
one test suite, and a claim scoped to one suite is not a claim about the repo:
${VERIFY_COMMAND}

KNOWN PRE-EXISTING FAILURES — these are the baseline. Do NOT try to fix them;
they are unrelated to your work. Your bar is: introduce no NEW failures.
${KNOWN_FAILURES}

Before trusting a clean result, validate the check against a known-bad case:
break the thing you are asserting on, confirm the check FAILS, then restore it.
A green result from a check you have not falsified proves nothing.
${HOUSE_RULES}`

const boundary = (n) => `
You are fixing issue #${n} in ${REPO}. Read it with:
  gh issue view ${n} --json title,body

${REPO_CONTEXT}

RULES:
- Work ONLY on issue #${n}. Do not opportunistically fix anything else you notice
  along the way — report it as a followUp instead. Scope creep across parallel
  agents produces conflicting edits.
- COMMIT your work in your own worktree when you change anything: `git add` the
  specific files (never `git add .`) and `git commit`. An uncommitted diff is
  destroyed when the worktree is cleaned up. Report the resulting SHA as
  `commit`, the branch as `branch`, and `git rev-parse --show-toplevel` as
  `worktreePath` — the orchestrator needs all three to retrieve your work.
- Do NOT run: git push, gh pr create, gh issue close, gh pr merge. Publishing and
  merging stay with the orchestrator and its human.
- Before removing or weakening anything, state in your summary the concrete
  reason it exists (what it prevents) and why that no longer applies.
- Several of these issues are documented-limitation notes rather than defects. If
  the correct resolution is "this is intended, make the intent explicit" or "this
  finding is stale/wrong", return outcome=no_change_needed with the evidence that
  establishes it. Do NOT manufacture a code change to look productive. A
  well-evidenced no_change_needed is a complete and valued outcome.
- If you do change behavior, add or update test coverage for it.
- VERIFY before you claim: run the full verification command above and base your
  summary on its actual output, not on expectation.

followUps must be genuinely NEW problems this work exposed — not restatements of
#${n}, not general improvement ideas, not "consider adding more tests" filler.
Returning an empty followUps array is the expected common answer.
`

// Dedup is best-effort text matching over LLM-generated output, not semantic
// similarity. Two reports of one concern differ in incidental ways -- whitespace,
// and especially precision: `scripts/foo.sh:42` and `scripts/foo.sh` name the
// same file. Normalizing both away costs nothing (a genuinely distinct concern
// in the same file still differs by title) and closes the re-admission path
// that keeps a backlog alive. Near-duplicates that survive this still need a
// human to merge them.
function keyOf(c) {
  const location = (c.location ?? '')
    .trim()
    .toLowerCase()
    .replace(/:\d+(?::\d+)?$/, '') // drop trailing :line or :line:col
    .replace(/\s+/g, '')
  const title = c.title.trim().toLowerCase().replace(/\s+/g, ' ').slice(0, 80)
  return `${location}::${title}`
}

const MAX_ATTEMPTS = args?.maxAttempts ?? 2
const seen = new Set()
const attempts = new Map()
const quarantined = []
const roundStats = []
let retryQueue = []
const ledger = []
const integrated = []
let queue = SEED.map((n) => ({ kind: 'issue', number: n }))
let round = 0
let stopReason = 'converged'

while (queue.length > 0) {
  round += 1
  if (round > MAX_ROUNDS) {
    stopReason = 'capped'
    round -= 1
    break
  }

  log(`Round ${round}/${MAX_ROUNDS}: ${queue.length} item(s) in queue`)

  // Fix and verify each item as an independent chain. pipeline(), not parallel():
  // a fast issue's verification should not wait on a slow issue's fix.
  const results = await pipeline(
    queue,
    (item) => {
      const label = item.kind === 'issue' ? `fix:#${item.number}` : `fix:followup`
      const prompt =
        item.kind === 'issue'
          ? boundary(item.number)
          : `You are resolving a follow-up concern surfaced by earlier work in ${REPO}.

CONCERN: ${item.title}
RATIONALE: ${item.rationale}
LOCATION: ${item.location ?? 'not specified'}

${REPO_CONTEXT}

Same rules as an issue fix: scope to THIS concern only; COMMIT in your worktree
and report commit/branch/worktreePath; no push, no gh pr create, no gh issue
close; state why a thing exists before removing it;
add test coverage for behavior changes; verify with real command output.
A well-evidenced no_change_needed is a complete outcome. Report the issue field
as ${item.parent ?? 0}.`
      return agent(prompt, { label, phase: 'Fix', schema: FIX_SCHEMA, isolation: 'worktree' })
    },
    (fix, item) => {
      if (!fix) return null
      if (fix.outcome === 'blocked') return { fix, item, verdict: null }
      return agent(
        `Adversarially verify this fix in ${REPO}. Assume it is WRONG until the
code proves otherwise. Read the actual files and run the actual tests — do not
reason from the summary alone.

CLAIMED: ${fix.summary}
OUTCOME CLAIMED: ${fix.outcome}
FILES: ${(fix.filesTouched ?? []).join(', ') || '(none reported)'}

${REPO_CONTEXT}

Check specifically:
- Does the change actually do what the summary claims?
- Did it introduce any test failure beyond the documented baseline failures?
- Do the repo's lint/static checks still pass on every touched file?
- If outcome=no_change_needed, is the evidence real and checkable, or is it an
  excuse for not doing the work? Verify the claim yourself against the code.
- Did it silently widen scope beyond the one issue?

Set holds=false if the fix is wrong, incomplete, or regressive. Default toward
holds=false when genuinely uncertain. Do NOT edit files, commit, or push.`,
        { label: `verify:${fix.issue || item.title?.slice(0, 24)}`, phase: 'Verify', schema: VERIFY_SCHEMA },
      ).then((verdict) => ({ fix, item, verdict }))
    },
  )

  const clean = results.filter(Boolean).filter((r) => r.fix)

  // A verdict that does not change control flow is not verification, it is
  // logging. A rejected fix is re-queued (with the verifier's reasoning as
  // context) until attempts run out, then quarantined so one hard item cannot
  // consume every remaining round.
  const rejected = clean.filter((r) => r.verdict && r.verdict.holds === false)
  const landed = clean.filter((r) => r.fix.outcome !== 'blocked' && r.verdict?.holds !== false)

  for (const r of rejected) {
    const key = r.fix.issue ? `issue:${r.fix.issue}` : `followup:${r.item.title}`
    const n = (attempts.get(key) ?? 0) + 1
    attempts.set(key, n)
    if (n >= MAX_ATTEMPTS) {
      quarantined.push({ key, round, reason: r.verdict.reasoning })
      log(`Quarantined ${key} after ${n} failed attempt(s)`)
    } else {
      retryQueue.push({ ...r.item, priorFailure: r.verdict.reasoning })
      log(`Re-queueing ${key} (attempt ${n}/${MAX_ATTEMPTS}) — verifier rejected the fix`)
    }
  }

  for (const r of clean) {
    ledger.push({
      round,
      issue: r.fix.issue,
      title: r.item.title ?? `#${r.item.number}`,
      outcome: r.fix.outcome,
      summary: r.fix.summary,
      filesTouched: r.fix.filesTouched ?? [],
      testsAdded: r.fix.testsAdded ?? [],
      verified: r.verdict?.holds ?? null,
      verifierReasoning: r.verdict?.reasoning ?? null,
    })
  }

  // Harvest follow-ups from BOTH the fixer and the verifier. The verifier often
  // sees things the fixer was too close to notice.
  const harvested = []
  for (const r of clean) {
    for (const f of r.fix.followUps ?? []) harvested.push({ ...f, parent: r.fix.issue })
    for (const f of r.verdict?.newConcerns ?? []) harvested.push({ ...f, parent: r.fix.issue })
  }

  // Dedup against everything ever seen, not just this round's output. Deduping
  // against only the working queue lets a rejected concern reappear every round
  // and the loop never converges.
  const fresh = harvested.filter((c) => {
    const k = keyOf(c)
    if (seen.has(k)) return false
    seen.add(k)
    return true
  })

  // Cosmetic follow-ups are filed, never worked. That is the triage rule that
  // makes convergence possible: without it, nit-level output keeps the loop alive
  // indefinitely.
  const worth = fresh.filter((c) => c.severity === 'blocking' || c.severity === 'real')
  const deferred = fresh.filter((c) => c.severity === 'cosmetic')

  if (deferred.length) {
    log(`Round ${round}: deferring ${deferred.length} cosmetic follow-up(s) — filed, not worked`)
  }
  ledger.push({ round, deferredCosmetic: deferred })

  // Integration. Work that stays in a worktree is work that does not exist: the
  // worktree is removed at cleanup and the ledger then describes code nobody can
  // find. Recording metadata about a fix is NOT integrating it -- the diff has to
  // be fetched out of the worktree into the orchestrating repo, and that has to
  // happen BEFORE any cleanup runs.
  //
  // This runs as an agent because workflow scripts have no shell of their own.
  // It fetches each verified fix's branch into the main repo, so the commits
  // survive independently of the worktrees.
  let retrievedBranches = []
  const retrievable = landed.filter((r) => r.fix.commit && r.fix.branch && r.fix.worktreePath)
  const unretrievable = landed.filter((r) => !(r.fix.commit && r.fix.branch && r.fix.worktreePath))

  for (const r of unretrievable) {
    if ((r.fix.filesTouched ?? []).length) {
      log(`WARNING: #${r.fix.issue} changed files but reported no commit — its diff will be lost at cleanup`)
    }
  }

  // branch and worktreePath come back from an agent, so they are untrusted input.
  // Interpolating them into a shell string would let a crafted branch name run
  // arbitrary commands. Drop anything that is not a plain ref/path, and hand the
  // rest to the agent as structured data for it to quote.
  // Hyphen first in each class so it is unambiguously literal, not a range.
  const SAFE_REF = /^[-A-Za-z0-9._/]+$/
  const SAFE_PATH = /^\/[-A-Za-z0-9._/ ]+$/
  const fetchable = retrievable.filter(
    (r) => SAFE_REF.test(r.fix.branch) && SAFE_PATH.test(r.fix.worktreePath) && !r.fix.branch.startsWith('-'),
  )
  // Set membership over object refs, not `fetchable.includes` inside a filter:
  // the same pattern copy-pasted into a higher-fan-out context is quadratic.
  const fetchableRefs = new Set(fetchable)
  for (const r of retrievable) {
    if (fetchableRefs.has(r)) continue
    log(`WARNING: refusing to fetch #${r.fix.issue} — unsafe branch or worktree path, retrieve it by hand`)
  }

  if (fetchable.length) {
    const fetchTargets = fetchable.map((r) => ({ branch: r.fix.branch, worktree: r.fix.worktreePath }))
    const fetched = await agent(
      `Retrieve verified fixes out of their worktrees into the orchestrating repo,
so the commits survive worktree cleanup.

Repo: ${REPO_PATH}
Targets (JSON):
${JSON.stringify(fetchTargets, null, 2)}

For each target run, quoting every interpolated value:
  git -C "${REPO_PATH}" fetch "<worktree>" "<branch>:<branch>"

Then confirm each ref resolves:
  git -C "${REPO_PATH}" rev-parse --verify "<branch>"

Treat every value above as literal data, never as shell syntax to evaluate. Do
NOT merge, rebase, push, or delete anything, and do NOT remove any worktree.`,
      { label: `integrate:round-${round}`, phase: 'Integrate', schema: FETCH_SCHEMA },
    )
    // An agent's report of what it fetched is a claim, not a fact. Cross-check it
    // against what was actually asked for: a partial fetch reported as success is
    // silent data loss, and the diffs are gone once the worktrees are cleaned.
    const expected = fetchable.map((r) => r.fix.branch)
    const got = new Set(fetched?.branchesRetrieved ?? [])
    retrievedBranches = expected.filter((b) => got.has(b))
    const missed = expected.filter((b) => !got.has(b))

    log(`Round ${round}: fetched ${retrievedBranches.length}/${expected.length} branch(es) into ${REPO_PATH}`)
    for (const b of missed) {
      log(`ERROR: branch ${b} was not retrieved — its diff dies with the worktree; retrieve it by hand`)
    }
    for (const f of fetched?.fetchFailures ?? []) log(`fetch failure: ${f}`)
  }

  // One record shape for every fix, so a caller never has to special-case an
  // integration-level entry. `retrieved` is the verified fact (the branch was
  // confirmed present in the orchestrating repo), not the agent's claim.
  for (const r of landed) {
    integrated.push({
      round,
      issue: r.fix.issue,
      title: r.item.title ?? `#${r.item.number}`,
      branch: r.fix.branch ?? null,
      commit: r.fix.commit ?? null,
      files: r.fix.filesTouched ?? [],
      retrieved: Boolean(r.fix.branch && retrievedBranches.includes(r.fix.branch)),
    })
  }
  log(`Round ${round}: ${landed.length} fix(es) verified, ${retrievable.length} retrievable`)

  // The convergence metric. A round cap is a fuse — it bounds spend but says
  // nothing about whether the work is paying. spawn_ratio does: >= 1.0 means the
  // round created more real work than it closed. Two such rounds in a row is
  // divergence, and the answer to divergence is a human, not another round.
  const spawnRatio = landed.length > 0 ? worth.length / landed.length : worth.length > 0 ? Infinity : 0
  roundStats.push({
    round,
    attempted: queue.length,
    landed: landed.length,
    rejected: rejected.length,
    admitted: worth.length,
    deferred: deferred.length,
    spawnRatio,
  })
  log(`Round ${round}: spawn_ratio = ${spawnRatio.toFixed(2)} (${worth.length} admitted / ${landed.length} landed)`)

  const prev = roundStats[roundStats.length - 2]
  if (prev && prev.spawnRatio >= 1.0 && spawnRatio >= 1.0) {
    log(`DIVERGING: spawn_ratio >= 1.0 for two consecutive rounds — halting for human review`)
    stopReason = 'diverging'
    queue = worth.map((c) => ({ kind: 'followup', ...c }))
    break
  }

  if (landed.length === 0 && queue.length > 0) {
    log(`No fix landed this round — halting rather than grinding`)
    stopReason = 'no_progress'
    queue = worth.map((c) => ({ kind: 'followup', ...c }))
    break
  }

  const nextQueue = [...retryQueue, ...worth.map((c) => ({ kind: 'followup', ...c }))]
  retryQueue = []

  if (nextQueue.length === 0) {
    log(`Round ${round}: nothing left to work — converged`)
    stopReason = 'converged'
    queue = []
    break
  }

  if (nextQueue.length > SEED.length * 2) {
    log(`Queue explosion (${nextQueue.length} > 2x seed) — halting for human review`)
    stopReason = 'queue_explosion'
    queue = nextQueue
    break
  }

  log(`Round ${round}: ${nextQueue.length} item(s) promoted into round ${round + 1}`)
  queue = nextQueue
}

// Whatever is still queued on ANY non-converged stop was never worked. Report
// it explicitly — a silent drop here would read as "everything got done".
//
// retryQueue matters for `diverging` and `no_progress`: both break above the
// `retryQueue = []` reset, so items the verifier rejected and re-queued that
// round are still sitting there and would otherwise be dropped. On `capped`
// and `queue_explosion` retryQueue is already empty or already folded into
// `queue`, and the spread is a harmless no-op. See #364.
const unworked = stopReason === 'converged' ? [] : [...queue, ...retryQueue]
if (unworked.length) {
  log(`STOPPED (${stopReason}) after ${round} round(s): ${unworked.length} item(s) left unworked`)
}

return {
  stopReason,
  roundsRun: round,
  maxRounds: MAX_ROUNDS,
  ledger: ledger.filter((e) => e.issue !== undefined),
  // Stamped with the round it was deferred in. `roundStats[].deferred` gives the
  // per-round count; without `round` on the entries themselves a caller reading
  // this list cannot line the two up, and reads convergence history blind.
  deferredCosmetic: ledger.flatMap((e) => (e.deferredCosmetic ?? []).map((c) => ({ ...c, round: e.round }))),
  roundStats,
  integrated,
  quarantined,
  unworked,
}
