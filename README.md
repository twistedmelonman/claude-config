# Claude Code Configuration

Personal Claude Code configuration for Andrew Rich.

## Setup

**Do NOT clone this repo directly into `~/.claude`.** The repo lives in your
development directory and symlinks its tracked files into `~/.claude`.

```bash
# 1. Clone into your development directory
git clone git@github.com:smartwatermelon/claude-config.git ~/Developer/claude-config

# 2. Run the install script to create symlinks into ~/.claude
~/Developer/claude-config/install.sh
```

That's it. All tracked files are now symlinked from `~/Developer/claude-config`
into `~/.claude`. Runtime state (sessions, projects, telemetry, etc.) stays in
`~/.claude` untouched.

### How it works

`install.sh` discovers tracked files via `git ls-files` and creates per-file
symlinks from the repo into `~/.claude`. Submodule directories get
directory-level symlinks. Repo-meta files (`.github/`, tests, README, etc.)
are excluded.

```
~/Developer/claude-config/settings.json  -->  ~/.claude/settings.json  (symlink)
~/Developer/claude-config/hooks/run-review.sh  -->  ~/.claude/hooks/run-review.sh  (symlink)
```

Edits to symlinked files (by you or Claude Code) write through to the repo,
so changes show up as unstaged diffs in `~/Developer/claude-config`.

### install.sh flags

| Flag | Effect |
|------|--------|
| `--dry-run` | Show what would be done without making changes |
| `--repair` | Fix broken symlinks (atomic write recovery) |
| `--help` | Show usage |

The script is idempotent — safe to run repeatedly.

### Ongoing maintenance: update-tools.sh

`scripts/update-tools.sh` is called automatically by the `updates` shell
command (via `_claude_update()`). It:

1. **Repairs** broken symlinks via `install.sh --repair`
2. **Audits** `~/.claude` — categorizes entries as symlinked (repo-managed),
   known-runtime (Claude Code managed), or unknown (needs human triage)

### Submodules

None. This repo tracks no submodules.

Marketplaces — `superpowers-marketplace` included — are cloned and updated by
Claude Code itself under `~/.claude/plugins/marketplaces/`, registered in
`~/.claude/plugins/known_marketplaces.json`. They are runtime state, not repo
content, so there is no pointer here to bump.

## Installed Plugins

Plugins are sourced from marketplaces registered in
`~/.claude/plugins/known_marketplaces.json` and managed by Claude Code.
Enabled state is tracked in `settings.json`.

### From superpowers-marketplace

- **superpowers** ✓ — core skills library for TDD, debugging, collaboration, and development workflows

### From claude-code-workflows

- **comprehensive-review** ✓ — 3 agents: code-reviewer, architect-review, security-auditor
- **tdd-workflows** ✓ — test-driven development workflows
- **debugging-toolkit** ✓ — debugging and error analysis
- **frontend-mobile-development** — React, Next.js, React Native patterns (disabled on some machines — see [Per-Machine Notes](#per-machine-notes))
- git-pr-workflows, error-debugging, code-refactoring, dependency-management, code-documentation, backend-development, unit-testing, security-compliance, incident-response, team-collaboration (available, not enabled)

### From smartwatermelon-marketplace

- **code-critic** ✓ — adversarial code review agent
- **react-native-3d** — 3D rendering with React Three Fiber, expo-gl, Three.js (disabled on some machines — see [Per-Machine Notes](#per-machine-notes))

### From claude-plugins-official

- **frontend-design** ✓ — production-grade frontend UI generation

### From personify

- **personify** ✓ — strips AI-writing tells from prose before it's sent, published, or shipped; replaces the retired blader/humanizer submodule

### From pr-review

- **pr-review** ✓ — deep-dive review of a teammate's GitHub pull request, staged as a pending review for explicit approval before anything is posted

## Per-Machine Notes

`settings.json` is shared across every machine via the symlink install, so
plugin choices are global by default. Machines with a narrower purpose
disable what they don't need rather than forking the config:

| Machine | Purpose | Deviates from default by |
|---|---|---|
| Beacon Biosignals work laptop (`arich@...`, provisioned 2026-07-12) | Senior SRE work: Python/Bash, infra CLIs, web-based tools, ssh. No app/mobile dev. | `frontend-mobile-development` and `react-native-3d` disabled — no Android/iOS/Expo/React Native work happens on this machine. |

When setting up a new machine: check this table first. If the new machine's
purpose matches an existing entry, replicate its deviations; if it's closer
to the personal-dev default, leave everything enabled and don't add a row
just to say so. Add a row only when a machine's plugin set actually diverges
from the tracked default.

## Architecture

### Plugin Loading

```
~/.claude/
├── plugins/
│   └── marketplaces/
│       ├── claude-code-workflows         # Plugin marketplace
│       ├── claude-plugins-official       # Plugin marketplace
│       ├── smartwatermelon-marketplace   # Personal marketplace
│       ├── superpowers-marketplace       # Upstream obra/superpowers-marketplace
│       ├── personify                     # Plugin marketplace
│       └── pr-review                     # Plugin marketplace
├── settings.json                         # enabledPlugins and hook configuration
│                                          # (notable keys documented in docs/INFRASTRUCTURE.md § Settings Rationale)
├── plugins/installed_plugins.json        # Runtime state (not tracked)
└── plugins/known_marketplaces.json       # Runtime state (not tracked)
```

### Runtime State

The following files are generated by Claude Code and are NOT tracked in git:

- `plugins/installed_plugins.json` - Contains absolute install paths
- `plugins/known_marketplaces.json` - Contains absolute marketplace locations

These files are regenerated based on the marketplace structure and the `enabledPlugins` map in `settings.json`.

## Git Hooks

Automated code review and safety hooks are configured in `hooks/` and `scripts/`:

- **hooks/pre-merge-review.sh** — AI review gate before merging PRs
- **hooks/run-review.sh** — per-commit AI code review runner
- **hooks/merge-lock.sh** — merge authorization lock (30-min TTL, keyed on repo + PR number)
- **scripts/hook-block-all.sh** — dispatches all PreToolUse hook-block scripts
- **scripts/hook-block-api-merge.sh** — blocks REST/GraphQL merge bypasses
- **scripts/hook-block-no-verify.sh** — blocks `--no-verify` flag usage
- **scripts/hook-block-main-commit.sh** — blocks commits directly to main
- **scripts/hook-session-start.sh** — injects session context on startup
- **scripts/status-line.sh** — custom Claude Code status line

See `CLAUDE.md` for protocol documentation.

## Commands

`install.sh` links these into `~/.local/bin`, pointing at the deployed copy in `~/.claude`:

- **claude-incognito** (`scripts/claude-incognito.sh`) — one-shot `claude -p` run that leaves no transcript, `/resume` entry, or `history.jsonl` line (print mode only). Defaults to `--permission-mode bypassPermissions` and turns claude.ai connectors off so the Slack plugin loads; see the script header

## Reference

- Main config: [CLAUDE.md](./CLAUDE.md)
- Superpowers marketplace: <https://github.com/smartwatermelon/superpowers-marketplace> (fork of obra/superpowers-marketplace)
- claude-code-workflows: <https://github.com/smartwatermelon/claude-code-workflows-agents> (fork of wshobson/agents)
- Personify skill: <https://github.com/twistedmelonman/personify>
- pr-review skill: <https://github.com/smartwatermelon/pr-review>
