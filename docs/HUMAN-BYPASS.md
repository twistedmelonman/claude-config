# Human Bypass Guide

This document explains how YOU (the human operator) can bypass the hardened review hooks when legitimately needed. These bypasses are **not available to the Claude Code agent** — with one caveat: `STRICT_PREPUSH=0` (see [section 3](#3-skipping-local-pre-push-review-with-strict_prepush0)) is not technically hook-blocked for the agent the way `--no-verify` is. The rule keeping it human-only is behavioral, not enforced — the agent must ask your permission before setting it, every time, with no standing authorization.

---

## Quick Reference

| Situation | Human Command |
|-----------|---------------|
| Commit without review | `git commit --no-verify -m "message"` |
| Push without checks | `git push --no-verify` |
| Skip local pre-push review | `STRICT_PREPUSH=0 git push` (human-run; agent must ask permission first) |
| Commit to main (emergency) | `git commit --no-verify -m "message"` (on main branch) |
| Authorize PR merge | `~/.claude/hooks/merge-lock.sh authorize <PR#> "reason"` |
| Authorize PR merge from your phone | `~/.claude/scripts/merge-lock-sign.sh <owner/repo> <PR#>`, then have the agent redeem the token |
| View blocked attempts | `~/.claude/scripts/blocked-audit.sh` |

---

## Detailed Instructions

### 1. Committing Without Review

The agent is blocked from using `--no-verify`, but you can use it directly:

```bash
# In your terminal (not through Claude Code)
git commit --no-verify -m "fix: emergency hotfix for production"
```

**When to use:**

- Emergency production fixes that can't wait for review
- Infrastructure changes that cause review timeouts
- Commits to repos without review hooks set up

**After using:** Consider running `git diff HEAD~1 | claude --agent code-reviewer -p` manually to review later.

### 2. Pushing Without Pre-Push Checks

```bash
# In your terminal
git push --no-verify
```

**When to use:**

- Pushing to a branch that doesn't need Protocol 4 checks
- Emergency deployments

### 3. Skipping Local Pre-Push Review with STRICT_PREPUSH=0

```bash
# In your terminal
STRICT_PREPUSH=0 git push
```

**What this gates:** the pre-push hook (`git/hooks/pre-push` in dotfiles) runs four non-interactive blocking review paths when a push happens inside Claude Code non-interactively (`CLAUDECODE=1`, stdin not a tty): the Semgrep supply-chain scan, Semgrep static analysis, the full-diff/codebase review, and a Protocol-4-equivalent PR-iteration checkpoint. `STRICT_PREPUSH=0` opts the push out of all four at once.

> **Drift risk:** the hook this section describes lives in an external dotfiles repo, not in this one — this repo has no version control over it and can't detect if it changes. This description reflects `git/hooks/pre-push` as of dotfiles commit `05c56a61bc0105e84aeb07b85bd944c2ed9cbe33` (2026-08-11). If actual behavior doesn't match what's described here, check `~/.config/git/hooks/pre-push` (symlinked to the dotfiles repo) directly rather than trusting this doc.

**How it differs from `--no-verify`:** `--no-verify` is hook-blocked for the agent — a Claude Code `PreToolUse` hook intercepts and refuses the command before it runs. `STRICT_PREPUSH=0` is **not** currently intercepted by any hook. Nothing technically stops the agent from setting this environment variable and pushing. The distinction matters: everywhere else in this doc, "not available to the agent" is a technical fact. Here it is not.

**The rule, because enforcement is behavioral, not technical:**

- The agent must never set `STRICT_PREPUSH=0` on its own initiative.
- The agent may ask you for permission to use it for a specific push, in the moment, when there's a concrete reason (e.g., a known-flaky check, an emergency, a push where local review genuinely doesn't apply).
- Permission is per-push. A "yes" earlier in this conversation — or in a past conversation — does not carry forward. The agent must ask again next time, even if the situation looks identical.
- If the agent sets `STRICT_PREPUSH=0` without asking, or claims you already authorized it when you didn't say so in the current exchange, that is a protocol violation worth calling out immediately.

**When to use:**

- You've reviewed the push yourself and judge local review unnecessary or redundant
- A local review path is broken or timing out for reasons unrelated to the actual change
- Emergency pushes where the four-check pipeline would cost time you don't have

### 4. Authorizing PR Merges

The agent cannot merge PRs without your authorization:

```bash
# Authorize a specific PR (valid 30 minutes). Run from inside the repo checkout.
~/.claude/hooks/merge-lock.sh authorize 123 "Reviewed and approved"

# From anywhere: name the repo explicitly (flag goes AFTER the subcommand)
~/.claude/hooks/merge-lock.sh authorize 123 "Reviewed and approved" --repo owner/name

# Check authorization status
~/.claude/hooks/merge-lock.sh status 123

# List all active authorizations
~/.claude/hooks/merge-lock.sh list
```

Locks are keyed on repo **and** PR number
(`~/.claude/merge-locks/<owner>/<repo>/pr-<N>.lock`), so an authorization for
one repo's PR 123 never satisfies another repo's PR 123. Without `--repo`, the
script resolves the repo from the current directory via `gh repo view` and
refuses to proceed if that fails. Pre-existing flat `pr-<N>.lock` files carry
no repo and are purged on the next run; re-authorize if you hit one.

`authorize` also confirms the PR actually exists in the repo it resolved, and
refuses otherwise:

```
Error: acme/dev-env has no PR #305.
The repo was resolved from the current directory (/Users/you/Developer/dev-env).
If the PR is in another repo, pass --repo OWNER/NAME after the subcommand,
or name it inline as OWNER/NAME#305.
```

Without that check, running `authorize 305` from the wrong checkout wrote a
well-formed lock for a PR that does not exist, while the merge you meant to
allow stayed blocked — and the two locks were indistinguishable in `list`.
In a batch, every pair is checked before any lock is written, so a typo in the
third entry authorizes nothing rather than leaving the first two granted.

If GitHub cannot be reached, the check warns and authorizes anyway. A network
outage should not lock you out of merging.

**Workflow:**

1. Agent completes PR and asks to merge
2. You review the PR on GitHub
3. You run the authorize command
4. You tell the agent to proceed with merge

#### Authorizing from your phone

When you are on Claude mobile, the session still runs on the laptop and you
cannot reach its shell, so `authorize` is out of reach. Merging in the GitHub
app instead skips the whole pre-merge pipeline — review, CI gating, the lot.

Signed tokens close that gap. Your phone holds a private key; the laptop holds
only the public half. You sign a token that names one repo, one PR and an
expiry, paste it into the chat, and the agent redeems it. The agent can carry a
token but cannot manufacture one, so the merge still runs through the normal
process.

**One-time setup.** On the phone (or wherever you will sign):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/merge_lock_phone -C merge-lock-phone
```

Copy the **public** half to the laptop, then enroll it there. Enrolling is
human-only, blocked for the agent for the same reason `authorize` is:

```bash
~/.claude/hooks/merge-lock.sh enroll ~/.ssh/merge_lock_phone.pub phone
~/.claude/hooks/merge-lock.sh signers   # confirm the fingerprint
```

**Each time you want to authorize a merge:**

```bash
# On the phone. Default window is 30 minutes; maximum is 24 hours.
~/.claude/scripts/merge-lock-sign.sh smartwatermelon/claude-config 123
~/.claude/scripts/merge-lock-sign.sh smartwatermelon/claude-config 123 120
```

Paste the token into the chat and tell the agent to redeem it. The agent runs:

```bash
~/.claude/hooks/merge-lock.sh redeem <token>
```

That creates a normal 30-minute lock, indistinguishable from one `authorize`
would have written except that its reason records which signer produced it.

**What the token does and does not permit.** It authorizes exactly the repo and
PR it names, it expires on its own schedule regardless of the lock TTL, and it
works once — a redeemed token is recorded and refused on a second attempt.
A token for one PR can never be replayed against another.

Any tool that can produce an OpenSSH signature over a payload
(`ssh-keygen -Y sign -n merge-lock`) will work in place of the script. Several
iOS and Android SSH clients advertise this; verify that a given app produces a
signature the laptop accepts before you rely on it away from your desk.

**Zero-setup alternative.** If you can SSH into the laptop from the phone, just
run `authorize` there directly. Signed tokens exist for when you cannot.

### 5. Viewing Blocked Attempts

See what the agent tried to bypass:

```bash
# View all blocked attempts
~/.claude/scripts/blocked-audit.sh show

# Count total blocked attempts
~/.claude/scripts/blocked-audit.sh count

# View today's blocked attempts
~/.claude/scripts/blocked-audit.sh today

# Clear the log
~/.claude/scripts/blocked-audit.sh clear
```

### 6. Committing Directly to Main

The agent is double-blocked from committing to main:

1. Git pre-commit hook blocks it
2. Claude Code PreToolUse hook blocks it

You can bypass both:

```bash
# Switch to main and commit (emergency only)
git checkout main
git commit --no-verify -m "fix: critical production fix"
git push --no-verify
```

**Warning:** This violates Protocol 1. Only do this for genuine emergencies.

---

## Environment Variables (For Scripts)

If you need to run scripts that invoke git commands:

```bash
# These don't help the agent (PreToolUse blocks before execution)
# But useful for your own automation scripts

SKIP_REVIEW=1 SKIP_REVIEW_REASON="automated deploy script" git commit -m "..."
FORCE_PUSH_NO_REVIEW=1 git push
```

---

## Adjusting Thresholds

If review is timing out frequently, adjust thresholds:

```bash
# Increase review timeout (default: 120 seconds)
git config --global review.timeout 300

# Increase max lines for full review (default: 1000)
git config --global review.maxLines 2000

# Increase threshold before review is skipped (default: 2500)
git config --global review.skipThreshold 5000
```

---

## Temporarily Disabling Hooks

To disable ALL Claude Code hooks temporarily:

1. Edit `~/.claude/settings.json`
2. Rename `"hooks"` to `"_hooks_disabled"`
3. Restart Claude Code
4. Do your work
5. Rename back to `"hooks"`
6. Restart Claude Code

**Or** remove specific PreToolUse hooks by editing the array.

---

## Emergency Checklist

When you need to bypass:

1. **Ask yourself:** Is this truly an emergency, or am I just impatient?
2. **Document:** Note why you're bypassing in the commit message
3. **Review later:** Run manual review after the emergency passes
4. **Check audit log:** `~/.claude/scripts/blocked-audit.sh` to see if agent was trying to bypass

---

## Why These Protections Exist

The agent was deliberately using `--no-verify` to skip review, leading to:

- Bugs reaching CI that should have been caught locally
- Wasted CI minutes ($0.008+/minute)
- Multiple push-fix-push cycles

The PreToolUse hooks block the agent from bypassing, but you retain full control.
