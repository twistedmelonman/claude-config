#!/usr/bin/env python3
"""Pre-flight check commit messages against the conventional-commits format.

The git commit-msg hook (in dotfiles) runs AFTER pre-commit. pre-commit
includes a 60-120s AI code review. If the commit message is malformed, the
review runs anyway and only gets rejected post-review by commit-msg. That
wastes review compute.

This PreToolUse hook catches obvious format failures BEFORE the review
starts, so operators don't burn a minute on review before finding out the
summary line needs fixing.

Contract with the commit-msg hook:
- Uses the SAME regex as dotfiles/git/hooks/commit-msg (CONV_COMMIT_RE).
- If extraction is ambiguous (complex heredoc, multiple -m args, etc.)
  exits 0 (fail-open) so the authoritative commit-msg hook still gates.
- Never attempts shell evaluation — only text parsing of the raw command.

Called by: hook-block-all.sh (PreToolUse Bash hook chain).

Input: JSON on stdin with `.tool_input.command`.
Exit: 0 = pass / not applicable; 2 = block (malformed summary).
"""

from __future__ import annotations

import datetime
import json
import os
import re
import sys


# Mirror of the regex in dotfiles/git/hooks/commit-msg. Manual sync — there
# is no shared source. The `!?` allows the optional breaking-change marker
# per conventional-commits v1.0.0.
CONV_COMMIT_RE = re.compile(
    r"^(feat|fix|docs|style|refactor|test|chore|perf|ci|build|revert)"
    r"(\([a-z0-9-]+\))?!?: .{1,}"
)


# git as leading verb at cmd start or after a shell-operator boundary, with
# optional interposed flags (-C /path, -c key=value, --no-pager) before the
# `commit` subcommand.
GIT_COMMIT_RE = re.compile(r"(?:^|[;&|(`])\s*git(?:\s+-\S+(?:\s+[^-]\S*)?)*\s+commit\b")


def is_git_commit_with_m(cmd: str) -> bool:
    """Command invokes `git commit` (optionally with flags) AND uses -m/--message."""
    if not GIT_COMMIT_RE.search(cmd):
        return False
    return bool(re.search(r"(?:\s|^)(-m|--message)(\s|=)", cmd))


def extract_file_summary(cmd: str) -> str | None:
    """First non-blank line of the file named by the commit's -F/--file.

    The approval gate (hook-block-personify.sh) sends every commit through
    `-F <approved file>`, so without this the -m-only check above never ran on
    a normal commit (claude-config#548).

    Only the commit's own arguments are searched: the text after `commit` up to
    the next shell separator, so a chained `gh pr create -F <body>` is not read
    as a commit message. Returns None (fail open, the commit-msg hook still
    gates) for anything this hook cannot read the same way git will: a
    relative path, `-` for stdin, or a missing or unreadable file.
    """
    git_commit = GIT_COMMIT_RE.search(cmd)
    if not git_commit:
        return None
    args = re.split(r"&&|\|\||[;|\n]", cmd[git_commit.end():], maxsplit=1)[0]
    flag = re.search(
        r"(?:^|\s)(?:-F\s*|--file(?:=|\s+))(?:\"([^\"]+)\"|'([^']+)'|([^\s\"']+))",
        args,
    )
    if not flag:
        return None
    path = next(g for g in flag.groups() if g is not None)
    if not path.startswith("/"):
        return None
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                # git's default cleanup for -F is `whitespace`: leading blank
                # lines go, `#` lines stay. Mirror that.
                if line.strip():
                    return line.strip()
    except OSError:
        return None
    return None


def extract_summary_candidate(cmd: str) -> str | None:
    """Best-effort first line of the commit message. None when uncertain.

    Returning None on ambiguity lets the commit-msg hook gate authoritatively.
    False-blocks here are worse than false-passes — the authoritative hook
    runs after this one.
    """
    # Strategy 1 — heredoc body. `-m "$(cat <<'EOF' ... EOF)"` puts the message
    # inside a heredoc; the first non-blank line after the opener is the summary.
    heredoc = re.search(
        r"<<[-~]?\s*['\"]?[A-Za-z_][A-Za-z0-9_]*['\"]?\s*\n([^\n]*)",
        cmd,
    )
    if heredoc:
        first = heredoc.group(1).strip()
        if first:
            return first

    # Strategy 2a — --message="..." / --message='...' (equals + quotes).
    eq_quoted = re.search(r'(?:-m|--message)=["\']([^"\']+)["\']', cmd)
    if eq_quoted:
        return eq_quoted.group(1).split("\n", 1)[0].strip()

    # Strategy 2b — --message=VALUE / -m=VALUE (equals without quotes).
    # First char must NOT be a quote (those are handled by Strategy 2a).
    eq_form = re.search(r"(?:-m|--message)=([^\s\"'][^\s]*)", cmd)
    if eq_form:
        return eq_form.group(1).split("\n", 1)[0].strip()

    # Strategy 3 — -m "..." / -m '...' simple quoted form (single line).
    # Explicitly does NOT match when the arg starts with $( or ` — those are
    # command substitutions, and Strategy 1 handles the common heredoc case.
    # Punt on other substitutions.
    for pattern in (
        r'(?:-m|--message)\s+"(?![$`])([^"]+)"',
        r"(?:-m|--message)\s+'(?![$`])([^']+)'",
    ):
        match = re.search(pattern, cmd)
        if match:
            return match.group(1).split("\n", 1)[0].strip()

    # Strategy 4 — unquoted single-token -m arg (unusual).
    unquoted = re.search(
        r"(?:-m|--message)\s+([^-$\s\"'`][^\s]*)",
        cmd,
    )
    if unquoted:
        return unquoted.group(1).strip()

    return None


def log_block(cmd: str) -> None:
    """Append a block event to ~/.claude/blocked-commands.log. Failure must not block."""
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    log_path = os.path.expanduser("~/.claude/blocked-commands.log")
    try:
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(f"{ts} BLOCKED COMMIT-MSG-FORMAT: {cmd}\n")
    except OSError:
        pass


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0  # Unparseable input — fail open.

    cmd = data.get("tool_input", {}).get("command", "")
    if not cmd:
        return 0

    if is_git_commit_with_m(cmd):
        summary = extract_summary_candidate(cmd)
    else:
        summary = extract_file_summary(cmd)
    if summary is None:
        return 0  # Ambiguous — let commit-msg hook gate.

    if CONV_COMMIT_RE.match(summary):
        return 0  # Valid.

    log_block(cmd)

    print("", file=sys.stderr)
    print(
        "🛑 BLOCKED: Commit message does not match conventional-commits format.",
        file=sys.stderr,
    )
    print("", file=sys.stderr)
    print(f"  Extracted summary line: {summary!r}", file=sys.stderr)
    print("", file=sys.stderr)
    print(
        "  Expected: <type>(<scope>)!?: <description>   (scope optional; ! marks breaking change)",
        file=sys.stderr,
    )
    print(
        "  Valid types: feat, fix, docs, style, refactor, test, chore, perf, ci, build, revert",
        file=sys.stderr,
    )
    print("", file=sys.stderr)
    print("  Examples:", file=sys.stderr)
    print("    feat(auth): add JWT refresh", file=sys.stderr)
    print("    fix: resolve memory leak", file=sys.stderr)
    print("    feat!: drop Node 10 (breaking change)", file=sys.stderr)
    print("", file=sys.stderr)
    print(
        "  This is a pre-flight check to save the 60-120s AI review cycle that",
        file=sys.stderr,
    )
    print(
        "  runs in the git pre-commit hook. The git commit-msg hook is still the",
        file=sys.stderr,
    )
    print("  authoritative validator.", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
