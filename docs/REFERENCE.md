# Reference Material — Andrew Rich

> **Note:** This is auxiliary documentation for `~/.claude/CLAUDE.md`
>
> **When to read:**
>
> - When setting up new repositories
> - When needing git/gh command references
> - When troubleshooting CI/CD issues
> - For communication preferences and style guidelines

## CI/CD Monitoring Commands

Use these commands during Protocol 5 (Post-Push Monitoring):

```bash
# List recent workflow runs
gh run list --limit 5

# Watch a run interactively
gh run watch

# View PR checks status
gh pr checks

# View failed logs
gh run view <run-id> --log-failed

# View PR comments (including automated review)
gh pr view --comments

# View specific workflow run details
gh run view <run-id>
```

### Common CI/CD Workflows

**After pushing a branch:**

1. `gh run list --limit 5` - Check if workflow triggered
2. `gh run watch` - Monitor progress interactively
3. `gh pr checks` - Verify all checks pass
4. `gh pr view --comments` - Read any automated feedback

**When CI fails:**

1. `gh run view <run-id> --log-failed` - Identify failure
2. Fix locally
3. `git add` + `git commit` (follow Protocol 4)
4. `git push` - Retry

---

## Repository Initialization

When initializing a new repository (e.g., via `/init` command), create a project-specific CLAUDE.md.

### Create Project-Specific CLAUDE.md

Create `$REPO/CLAUDE.md` with project-specific configuration:

```markdown
# Claude Code Configuration for [Project Name]

> **Note**: Common protocols and standards are in `~/.claude/CLAUDE.md` (global
> configuration). This file contains only project-specific additions and modifications.
>
> **For reviewers**: The global configuration file may not be accessible during review.
> This is expected - the global file provides common standards across all projects.

## Project Context

[Project-specific stack, architecture, key files]

## Testing Commands

[Project-specific test commands]
```

### Commit and Push

```bash
git add CLAUDE.md
git commit -m "chore(config): add project-specific CLAUDE.md"
git push
```

---

## Communication Preferences

### Addressing

- My name is **Andrew**. Not "the user."

### Style

- Print current system date at launch (training data is stale - see Protocol 0)
- Avoid hollow affirmations ("Perfect!", "Great idea!", "Absolutely right!")
- "Production-ready" means literally ready for App Store submission—don't use it for minor milestones
- When something fails: stop, explain what failed and your theory why, propose next step, wait for confirmation

### Output Format

- Be concise and direct
- Use GitHub-flavored markdown for formatting
- Output text to communicate; use tools for actions
- Never use Bash echo/printf to communicate—output text directly

---

## Important Reminders

### NEVER

- Disable tests instead of fixing them
- Make assumptions—verify with existing code
- Run git operations in parallel (lock contention)
- Say "Perfect!" meaning "I understand"
- Use emojis in prose (permitted only as structural anchors at the head of a defined block — the 📅 ✅ 🔍 markers in CLAUDE.md's required blocks are scan anchors, not decoration)
- Create documentation files unless explicitly requested

### ALWAYS

- Signify understanding of local and global instructions at session start — in the two-line form CLAUDE.md Protocol 0 specifies, not a longer acknowledgment
- Show your work
- Stop after 3 failed attempts and reassess
- Update plan documentation as you go
- Use specialized tools instead of bash commands when possible
- Follow the principle of least surprise

### Common Mistakes to Avoid

1. **Completion pressure** - Don't rush to declare work "done"
2. **Assumption accumulation** - Verify frequently, don't build on unvalidated beliefs
3. **Tool misuse** - Use Read for files, not `cat`; use Edit for changes, not `sed`
4. **Verification gaps** - More than 5 actions without reality check = danger zone
5. **Context switching** - Complete Protocol 5 before moving to next task

---

## Agent Reference

### When to Use Agents

| Task | Agent/Tool | Trigger |
|------|------------|---------|
| **Code Review** | `code-reviewer` | Before EVERY commit |
| **Adversarial Review** | `code-critic:adversarial-reviewer` | Every commit (via git hook) |
| **Architecture Review** | `architect-review` | Structural changes, new patterns |
| **Security Audit** | `security-auditor` | Auth, data handling, API security |
| **Library Docs** | `mcp__context7__*` | Framework/library questions |

### Agent Naming Conventions

- **Task tool** (interactive sessions): Use full format `plugin:agent` (e.g., `code-critic:adversarial-reviewer`)
- **CLI `--agent` flag** (git hooks, scripts): Use short name `agent` (e.g., `adversarial-reviewer`)

### Security-Critical File Patterns

`is_security_critical` in `~/.claude/hooks/lib-review-issues.sh` matches a file
path as a substring against:

`auth|oauth|jwt|password|session|login|register|payment|billing|stripe|paypal|checkout|transaction|db|database|model|migration|schema|security|crypto|encryption|secret|vault`

It has two uses. `pre-merge-review.sh` always sends these files' diffs to the
reviewer in full (never summarized or truncated). `lib-review-issues.sh` adds a
`security` label to a filed issue whose location matches. Commit-time review
(`run-review.sh`) does not treat these paths differently.

---

## Return to Main Documentation

For mandatory protocols and standards:
→ Return to `~/.claude/CLAUDE.md`

For philosophical guidance and decision frameworks:
→ See `~/.claude/docs/PHILOSOPHY.md`

For custom agent development:
→ See `~/.claude/docs/CUSTOM_AGENTS.md`
