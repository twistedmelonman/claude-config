#!/usr/bin/env python3
"""Redact live secrets from tool OUTPUT before it reaches the transcript.

The companion PreToolUse hook (hook-block-secret-leak.py) inspects
`.tool_input.command` and blocks a command that WOULD leak. Measured against
one day of transcripts, zero leaks arrived that way: 84 sites, 12 distinct
values, all of them in tool RESULTS, assistant text, or attachments. See
twistedmelonman/claude-config#537.

This hook covers the largest of those channels -- tool results -- by rewriting
the output with `updatedToolOutput`. Verified on Claude Code 2.1.274: the
replacement reaches both the model's context AND the on-disk transcript JSONL,
which is the property that matters, because a durable record is what forces a
rotation.

Two detectors, because neither subsumes the other:

  1. Exact-value match against the live environment. Catches ANY
     credential-shaped variable regardless of format -- including ones no
     scanner has a rule for. Cannot false-positive on a fixture, because a
     fixture is not in the environment.

  2. gitleaks, when available. Catches known credential formats that are NOT
     in this environment -- a token in a config file being cat'd, a colleague's
     key in a paste. Measured 6/6 on real tokens and 6/6 correct rejections on
     fixtures, because its entropy model separates the two classes where a
     bare `ghp_[A-Za-z0-9]{36}` regex cannot.

Fails OPEN and loud. A detector crash must not wedge every tool call, but it
must never silently stop guarding -- that pattern is already on record here
six times over.

Exit 0 always. Emits JSON on stdout only when something was redacted.
"""

import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

# Mirrors hook-block-secret-leak.py. Substring hints must be words that do not
# occur inside common non-secret names: `PAT` is absent because it matches
# PATH, PYTHONPATH, GOPATH.
NAME_HINTS = ("TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL")
NAME_HINTS_WORD = ("KEY", "APIKEY", "PAT")
NAME_EXCEPTIONS = frozenset(
    {"KEYBOARD", "SSH_AUTH_SOCK", "KEYMAP", "KEYTIMEOUT",
     "KEBAB_RELEASE_KEYSTORE_PATH"}
)

# Below this, a "secret" is a flag or short identifier and substring matching
# produces false positives.
MIN_SECRET_LEN = 16

# Redacting a huge payload costs more than it protects, and gitleaks on a
# multi-megabyte string stalls the tool call. Exact-value matching still runs
# on oversized output; only the gitleaks pass is skipped.
MAX_GITLEAKS_BYTES = 1_000_000

PLACEHOLDER = "[redacted: %s]"


def _warn(msg):
    """Report a degraded prong. Never a secret value.

    Goes to stderr, which the harness surfaces. A prong that stops working
    must say so: the alternative is a redactor that reports success while
    redacting nothing.
    """
    sys.stderr.write("⚠️  secret-output redactor: %s\n" % msg)


def secret_vars():
    """Live environment variables whose NAME suggests a credential."""
    out = {}
    for name, value in os.environ.items():
        # Exported bash functions carry their body as the value and routinely
        # contain the word "token" without being secrets.
        if name.startswith("BASH_FUNC_"):
            continue
        if name in NAME_EXCEPTIONS:
            continue
        upper = name.upper()
        if not (
            any(h in upper for h in NAME_HINTS)
            or any(re.search(rf"(^|_){h}(_|$)", upper) for h in NAME_HINTS_WORD)
        ):
            continue
        if len(value) < MIN_SECRET_LEN:
            continue
        out[name] = value
    return out


def redact_exact(text, secrets):
    """Replace live credential values with a named placeholder.

    Longest first: if one secret is a substring of another, replacing the
    shorter one first would corrupt the longer without redacting it.
    """
    hits = []
    for name, value in sorted(
        secrets.items(), key=lambda kv: len(kv[1]), reverse=True
    ):
        if value and value in text:
            text = text.replace(value, PLACEHOLDER % name)
            hits.append(name)
    return text, hits


def redact_gitleaks(text):
    """Mask known credential formats not present in this environment.

    Two behaviors of gitleaks 8.30.1 this depends on, both verified rather
    than assumed:

      - `--report-path /dev/stdout` yields NOTHING on stdout. The report must
        go to a real file, which is why this uses a temp file.
      - `--redact` masks the `Secret` field IN THE REPORT. Since the report is
        exactly where the value to replace comes from, --redact must NOT be
        passed here; the masking is done below instead.

    Returns the text unchanged if gitleaks is unavailable or errors -- prong 1
    has already run either way.
    """
    # Not installed is a deployment choice, not a malfunction: prong 1 still
    # runs and covers every credential the environment holds. Silent by
    # design. Installed-but-failing is different and is reported below.
    if not shutil.which("gitleaks"):
        return text, []
    if len(text.encode("utf-8", "replace")) > MAX_GITLEAKS_BYTES:
        _warn("output over %d bytes; gitleaks pass skipped" % MAX_GITLEAKS_BYTES)
        return text, []

    try:
        with tempfile.TemporaryDirectory() as tmpdir:
            report = os.path.join(tmpdir, "report.json")
            proc = subprocess.run(
                ["gitleaks", "stdin", "--no-banner",
                 "--report-format", "json", "--report-path", report],
                input=text, capture_output=True, text=True, timeout=10,
            )
            # Exit 0 = nothing found, 1 = findings. Anything else is an error
            # this does not try to interpret -- but it must not pass silently,
            # or a broken install drops prong 2 forever with no signal.
            if proc.returncode not in (0, 1):
                _warn("gitleaks exited %d; prong 2 skipped" % proc.returncode)
                return text, []
            try:
                with open(report, encoding="utf-8") as fh:
                    body = fh.read()
            except OSError as exc:
                _warn("gitleaks report unreadable (%s)" % type(exc).__name__)
                return text, []
    except subprocess.TimeoutExpired:
        _warn("gitleaks timed out; prong 2 skipped")
        return text, []
    except OSError as exc:
        _warn("gitleaks failed to run (%s)" % type(exc).__name__)
        return text, []

    try:
        findings = json.loads(body) if body.strip() else []
    except json.JSONDecodeError:
        _warn("gitleaks report was not valid JSON; prong 2 skipped")
        return text, []
    if not isinstance(findings, list):
        _warn("gitleaks report was not a list; prong 2 skipped")
        return text, []

    rules = []
    for f in findings:
        if not isinstance(f, dict):
            continue
        val = f.get("Secret") or ""
        if len(val) < MIN_SECRET_LEN:
            continue
        rules.append((val, f.get("RuleID") or "secret"))

    for val, rule in sorted(rules, key=lambda r: len(r[0]), reverse=True):
        if val in text:
            text = text.replace(val, PLACEHOLDER % rule)

    return text, sorted({r for _, r in rules})


def log(names):
    """Record variable NAMES and rule ids. Never a value."""
    try:
        path = os.path.join(os.path.expanduser("~"), ".claude",
                            "blocked-commands.log")
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        with open(path, "a", encoding="utf-8") as fh:
            fh.write("%s REDACTED FROM OUTPUT: %s\n" % (stamp, ",".join(names)))
    except OSError:
        pass


def main():
    raw = sys.stdin.read()
    if not raw.strip():
        return 0
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return 0

    resp = data.get("tool_response")
    if not isinstance(resp, dict):
        return 0

    secrets = secret_vars()
    updated = json.loads(json.dumps(resp))  # deep copy; nested edits below
    all_hits = []
    changed = False

    def scrub(text):
        """Both prongs over one string. Returns (new_text, hit_names)."""
        new, hits = redact_exact(text, secrets)
        new, grules = redact_gitleaks(new)
        return new, hits + grules

    # Bash and friends: top-level text fields. Only these are rewritten --
    # touching `interrupted` or `isImage` would break the shape contract, and
    # a replacement whose shape does not match is silently discarded.
    for key in ("stdout", "stderr"):
        text = resp.get(key)
        if not isinstance(text, str) or not text:
            continue
        new, hits = scrub(text)
        if new != text:
            updated[key] = new
            changed = True
        all_hits.extend(hits)

    # Read: content nests under `file.content`, with no stdout anywhere.
    # Measured on this machine's transcripts, Read accounted for 4 of 12
    # attributable tool_result leak sites (33%) -- a file holding a credential
    # being read into context. A stdout-only redactor misses every one.
    rfile = resp.get("file")
    if isinstance(rfile, dict) and isinstance(rfile.get("content"), str):
        text = rfile["content"]
        if text:
            new, hits = scrub(text)
            if new != text:
                updated["file"]["content"] = new
                changed = True
            all_hits.extend(hits)

    if not changed:
        return 0

    log(sorted(set(all_hits)))
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "updatedToolOutput": updated,
        }
    }))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001
        # Fail open, but never silently.
        #
        # Exit 1, not 0: exit 0's stderr is DISCARDED, so exiting 0 here would
        # leave output unredacted with no signal at all -- a guard that
        # quietly stopped guarding, which is the exact pattern this infra has
        # six recorded instances of. The sibling PreToolUse hook chose exit 1
        # for this same reason. Neither blocks the tool call.
        sys.stderr.write(
            "⚠️  secret-output redactor failed (%s); output NOT redacted.\n"
            % type(exc).__name__
        )
        sys.exit(1)
