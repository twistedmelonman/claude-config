# Custom Agents

This document explains where this configuration's custom agents live, and how
to add or change one.

> **Note for repository clones:** custom agents are **not** stored in this
> repository. They are published in a separate marketplace repo
> (`smartwatermelon/smartwatermelon-marketplace`) and installed by Claude Code
> into `~/.claude/plugins/`, which is runtime state. Cloning this repo does not
> give you the agents; install the marketplace instead (see
> [Installing](#installing-the-marketplace)). The git hooks degrade gracefully
> when `adversarial-reviewer` is absent — see [Hook
> behavior](#hook-behavior-when-the-agent-is-missing).

## Where custom agents live

Custom agents ship as **plugins in a marketplace you own**. The
`adversarial-reviewer` agent is the `code-critic` plugin:

```text
~/.claude/plugins/
├── marketplaces/
│   └── smartwatermelon-marketplace/          # cloned + updated by Claude Code
│       ├── .claude-plugin/marketplace.json
│       └── plugins/
│           └── code-critic/
│               ├── .claude-plugin/plugin.json
│               └── agents/
│                   └── adversarial-reviewer.md
└── cache/
    └── smartwatermelon-marketplace/
        └── code-critic/1.4.0/                # resolved version actually used
```

Marketplace source: <https://github.com/smartwatermelon/smartwatermelon-marketplace>

Owning the marketplace is what makes this safe. An earlier layout kept agents
in a local-only directory (`~/.claude/agents-local/`) specifically to stop a
third-party package update from overwriting them. That directory no longer
exists, and the concern no longer applies: nobody else publishes to this
marketplace, so an update can only deliver your own changes.

**Everything under `~/.claude/plugins/` is runtime state.** Claude Code clones
and updates it. Do not track it in this repo, do not symlink it from
`install.sh`, and do not hand-edit an installed agent — edits there are
overwritten on the next update, and they are not the source of truth.

## How discovery works

Claude Code scans `~/.claude/plugins/marketplaces/` for plugins and registers
each agent it finds. No install step is needed beyond adding the marketplace,
and no restart is needed after an agent file changes.

**Agent IDs are not always the bare `name:` from the frontmatter.** The
installed ID depends on the plugin, and getting it wrong fails silently — a
mistyped ID errors per-invocation without blocking the commit, so reviews
quietly stop happening. To list the real IDs:

```bash
claude --agent bogus -p "x"    # the error lists every available agent ID
```

Current IDs:

| Agent | ID to use |
| --- | --- |
| adversarial-reviewer | `adversarial-reviewer` (bare name; unique) |
| code-reviewer | `comprehensive-review:comprehensive-review-code-reviewer` |

The second one doubles the plugin name because that is what the
`comprehensive-review` plugin's own frontmatter declares. Verify, don't assume.

**Usage:**

- **Git hooks / CLI**: `claude --agent adversarial-reviewer -p "..."`
- **Agent tool**: `subagent_type: "code-critic:adversarial-reviewer"`
  (the full `plugin:agent` form)

## Installing the marketplace

```bash
claude plugin marketplace add smartwatermelon/smartwatermelon-marketplace
claude plugin install code-critic@smartwatermelon-marketplace
```

Verify the agent resolves:

```bash
find -L ~/.claude/plugins/marketplaces -name "adversarial-reviewer.md" -type f
```

That `find` is the same check `hooks/run-review.sh` uses to decide whether the
agent is available.

## Hook behavior when the agent is missing

`hooks/run-review.sh` runs `code-reviewer` and `adversarial-reviewer` in
parallel. If the `find` check above returns nothing, it logs a warning and
falls back to running `code-reviewer` alone. Commits still work; you simply
lose the adversarial pass and the arbiter that reconciles the two when they
disagree.

## Adding or changing an agent

Agents are edited in the **marketplace repo**, not here and not in
`~/.claude/plugins/`.

### 1. Clone the marketplace repo

```bash
git clone git@github.com:smartwatermelon/smartwatermelon-marketplace.git
```

### 2. Add or edit the agent file

Add a plugin directory with an `agents/` subdirectory, or edit an existing
agent file. Agent frontmatter:

```markdown
---
name: my-agent
description: What this agent does, and when it should be chosen.
model: opus  # or sonnet, haiku
---

# Agent Prompt

Your agent's system prompt here...
```

The `description` is what a dispatching agent reads to decide whether to pick
this agent. Write it as selection criteria, not as a title.

### 3. Bump both version numbers

Bump `version` in the plugin's `.claude-plugin/plugin.json` **and** in the
marketplace's `.claude-plugin/marketplace.json` entry. These are two separate
files and drift apart easily — as of 1.4.0 they already have.

### 4. Commit, push, then update locally

```bash
claude plugin marketplace update smartwatermelon-marketplace
```

### 5. Confirm the new version resolved

```bash
ls ~/.claude/plugins/cache/smartwatermelon-marketplace/code-critic/
```

Scope the tools in frontmatter (`tools:` / `allowed-tools:` /
`disallowed-tools:`) — see [Writing a thrifty dispatch
prompt](#writing-a-thrifty-dispatch-prompt) for why a narrow agent is cheaper
than a generic one.

## Current custom agents

- **code-critic / adversarial-reviewer** (`model: opus`): single-pass skeptical
  review that assumes the code is wrong until proven otherwise. Used by
  `hooks/run-review.sh` for the per-commit adversarial pass, the full-diff
  review, the codebase-mode scan, and as the arbiter when `code-reviewer` and
  `adversarial-reviewer` disagree.

## Subagent Lifetime Budget

A subagent is expected to finish within **5 minutes or 2.3M tokens, whichever
comes first**. An agent that cannot is a signal that the task's scope is too
large: break it into smaller pieces rather than raising the limit.

The token half is enforced by `scripts/hook-budget-guard.sh` on `SubagentStop`
(`BUDGET_SUBAGENT_TOKENS`, default 2300000). Primary agents must not raise it
without affirmative approval from Andrew — it is not a default that can be
waived unilaterally.

### Where 2.3M comes from

Measured across 447 real subagent transcripts (2026-09-02). A well-behaved
agent averages **416,286 tokens/min**; five minutes of that is 2.08M, plus a
10% buffer gives 2.3M. It is the token expression of the five-minute limit,
not an independent number — of the 93 agents this ceiling blocks, 85 (91%)
also ran over five minutes.

For scale: the cheapest of all 447 agents spent **32,996 tokens**. A ceiling
in the tens of thousands sits below the observed floor.

### What actually drives the cost

Cost is dominated by `cache_read` — every turn re-reads the whole accumulated
context, so spend tracks `turns x context size`. Continuing is the expense,
not repeating. Two consequences:

- A long agent at high context costs far more than several short ones.
- Trimming what an agent carries pays off on *every* turn, not once.

### Writing a thrifty dispatch prompt

Measured on a real incident: ~33K of a ~40K per-agent entry cost was
self-inflicted by prompt wording, not harness overhead. Subagents start cold,
so none of it is cache-amortized.

- **Hand over interfaces and contracts, not whole files.** The specific
  anti-pattern is "read X in full" for a file the agent will not modify. One
  agent was told to read a 1,685-line test harness (~17K tokens) when it
  needed ~19 function signatures and one sample test (~750 tokens) — a 96%
  reduction on the largest single item.
- **Scope the tools.** Agent frontmatter supports `tools:` / `allowed-tools:` /
  `disallowed-tools:`. Prefer a narrow purpose-built agent over a generic
  `general-purpose` spawn.
- **State the design decision before dispatching a build agent.** The single
  largest line item in the incident was building the wrong thing: 12 requests
  preceded a dispatch that was killed 5 minutes later, discarding 1.63M
  tokens. If the deciding evidence is not already in hand, ask first.

There is **no** flag to suppress `CLAUDE.md` injection —
`skipProjectInstructions` and `systemPromptAppend` return zero hits in the
v2.1.259 binary. Do not hunt for one. The harness baseline (~7.3K) is small;
the prompt is where the savings are.

### Why the cap cannot terminate a running agent

A blocking `SubagentStop` (exit 2) does **not** kill the subagent. Verified in
the v2.1.259 binary: the blocking message is appended to the conversation,
`stop_hook_active` is set, and the turn loop continues — the agent keeps
running with the block as new context. Blocking is itself capped at
`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` (default 8), and applies to `Stop` and
`SubagentStop` alike.

So the guard is a post-hoc circuit breaker, not a live cap, and each wasted
block costs a full-context turn. This is why `hook-budget-guard.sh` honors
`stop_hook_active` and exits 0 rather than blocking repeatedly.

The only mechanisms that genuinely bound an agent's lifetime are harness-level:
`CLAUDE_CODE_MAX_TURNS`, `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`,
`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`, `CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION`,
`CLAUDE_ASYNC_AGENT_STALL_TIMEOUT_MS`. For `claude` invoked from a shell (the
review hooks), `timeout` supplies the wall-clock bound — those call sites
already use it, with per-call budgets tuned to prompt size.
