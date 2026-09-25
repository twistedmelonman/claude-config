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

Both of those need the secret to be known in advance -- by the environment or
by a gitleaks rule. smartwatermelon/dev-env#156 recorded a live key that was
neither: fetched with `op read` (so no env var held it) and printed bare on
its own line, a shape gitleaks' generic-api-key rule never fires on (it needs
a `key = "..."` context). Measured with gitleaks 8.30.1 on 2026-09-24: 27 of
41 synthetic vendor-shaped keys, printed bare, produced no finding. Two more
detectors close that gap:

  3. Command-keyed. Some commands exist to print a credential (`op read`,
     `security find-generic-password -w`, `gcloud auth print-access-token`,
     `gh auth token`, ...). When one of them runs in command position and its
     stdout reaches the transcript -- not captured by `$(...)`, not
     redirected to a file, not piped into a consumer -- the whole stdout is
     replaced without trying to recognize what it holds. This is the prong
     that covers vendors nobody has written a rule for.

  4. Distinctive vendor prefixes gitleaks does not carry, for the vendors
     this machine uses (Pangram `sk-pg-`, 1Password `ops_eyJ`, ...). This
     covers the same keys arriving by other routes -- a Read of a .env file,
     a `cat` -- where no command gives them away. Deliberately narrow: each
     pattern needs a prefix that does not occur in prose plus a long body,
     so ordinary output (hashes, UUIDs, prose that names a prefix) is left
     alone.

Fails OPEN and loud. A detector crash must not wedge every tool call, but it
must never silently stop guarding -- that pattern is already on record here
six times over.

Exit 0 always. Emits JSON on stdout only when something was redacted.
"""

import datetime
import json
import os
import re
import shlex
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


# --- prong 3: command-keyed -------------------------------------------------
#
# Commands whose purpose is to print a credential. Keyed on the COMMAND, so
# the format of what comes back never matters.

# Downstream of a pipe, these hand their input straight back to stdout (or a
# transform of it that is still the secret). Anything else is treated as a
# consumer -- `op read X | gh auth login --with-token` prints nothing secret.
PASSTHROUGH = frozenset({
    "cat", "tee", "head", "tail", "tr", "cut", "sed", "awk", "jq", "yq",
    "grep", "egrep", "fgrep", "sort", "uniq", "fold", "rev", "base64",
    "xxd", "od", "hexdump", "strings", "less", "more", "column", "paste",
    "xargs",
})

# A captured `$(...)` is consumed by whatever holds it -- except these, which
# print their arguments. `echo "$(op read X)"` is `op read X` with extra steps.
PRINTERS = frozenset({"echo", "printf", "print", "cat"})

# Words that can precede the real command without changing where its stdout
# goes. The number is how many following non-flag words the wrapper consumes
# (`timeout 10 op read` -> skip `10`).
WRAPPERS = {
    "env": 0, "command": 0, "builtin": 0, "exec": 0, "sudo": 0, "time": 0,
    "nohup": 0, "nice": 0, "timeout": 1, "!": 0, "{": 0, "}": 0,
    "if": 0, "then": 0, "elif": 0, "else": 0, "do": 0, "while": 0,
    "until": 0,
}
# Wrapper flags that take a separate value word (`env -u NAME`, `sudo -u X`).
WRAPPER_VALUE_FLAGS = frozenset({"-u", "-g", "-C", "-S", "-n", "-k", "-s"})

# `op` global/subcommand flags that take a separate value word. Skipped when
# looking for the subcommand, so `op --account x read ...` still matches.
OP_VALUE_FLAGS = frozenset({
    "--account", "--config", "--encoding", "--session", "--vault",
    "--format", "--out-file", "-o", "--in-file", "-i", "--cache",
})

SHELLS = frozenset({"bash", "sh", "zsh", "dash", "ksh"})
ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")
CAPTURE_TOKEN = "__REDACT_CAPTURE_%d__"
CAPTURE_TOKEN_RE = re.compile(r"__REDACT_CAPTURE_(\d+)__")

# Shell operators, longest first so `&&` is not read as two `&`.
OPERATORS = ("&>>", "&&", "||", ";;", ">>", ">|", "&>", "|&", ">&", "<<<",
             "<<", "<&", ";", "&", "|", "(", ")", "<", ">")
STDOUT_REDIRECTS = frozenset({">", ">>", ">|", "&>", "&>>"})
SEPARATORS = frozenset({";", "&&", "||", "&", ";;", "(", ")"})
PIPES = frozenset({"|", "|&"})


def _positionals(args, value_flags=frozenset()):
    """Non-flag words, skipping the value word of any flag in value_flags."""
    out = []
    skip = False
    for a in args:
        if skip:
            skip = False
            continue
        if a.startswith("-"):
            if a in value_flags:
                skip = True
            continue
        out.append(a)
    return out


def emitter_label(argv):
    """Name the credential-printing command argv is, or None.

    argv[0] is the program (already stripped of wrappers and assignments).
    """
    if not argv:
        return None
    prog = os.path.basename(argv[0])
    args = argv[1:]
    pos = _positionals(args, OP_VALUE_FLAGS if prog == "op" else frozenset())
    flags = set(a.split("=", 1)[0] for a in args if a.startswith("-"))

    if prog == "op" and pos:
        if pos[0] == "read":
            return "op read"
        # `op inject -o FILE` writes the rendered secrets to a file.
        if pos[0] == "inject" and not flags & {"-o", "--out-file"}:
            return "op inject"
        if pos[:2] == ["item", "get"] and flags & {"--reveal", "--fields"}:
            return "op item get"
        if pos[0] == "signin" and "--raw" in flags:
            return "op signin --raw"
    if prog == "security" and pos[:1] in (["find-generic-password"],
                                          ["find-internet-password"]):
        # -w prints the password to stdout; -g prints it to STDERR.
        if "-w" in flags or "-g" in flags:
            return "security %s" % pos[0]
    if prog == "gcloud" and "auth" in pos and (
            "print-access-token" in pos or "print-identity-token" in pos):
        return "gcloud auth print-*-token"
    if prog == "gh" and pos[:2] == ["auth", "token"]:
        return "gh auth token"
    if prog == "gh" and pos[:2] == ["auth", "status"] and (
            flags & {"--show-token", "-t"}):
        return "gh auth status --show-token"
    if prog == "aws" and (pos[:2] in (["ecr", "get-login-password"],
                                      ["sts", "get-session-token"],
                                      ["configure", "get"],
                                      ["secretsmanager", "get-secret-value"])):
        return "aws %s %s" % tuple(pos[:2])
    if prog == "az" and pos[:2] == ["account", "get-access-token"]:
        return "az account get-access-token"
    if prog == "vault" and (pos[:1] == ["read"] or pos[:2] == ["kv", "get"]):
        return "vault read"
    if prog == "doppler" and pos[:2] in (["secrets", "get"],
                                         ["secrets", "download"]):
        return "doppler secrets"
    if prog == "pass" and pos[:1] == ["show"]:
        return "pass show"
    if prog == "git" and pos[:2] == ["credential", "fill"]:
        return "git credential fill"
    if prog == "heroku" and pos[:1] == ["auth:token"]:
        return "heroku auth:token"
    return None


def _extract_captures(cmd):
    """Replace each `$(...)`, `<(...)` and `>(...)` with a placeholder word.

    Returns (rewritten command, [inner command text, ...]). Done on the raw
    string so a capture inside double quotes -- `echo "k=$(op read X)"` -- is
    found too; a tokenizer would hand that back as one opaque word.
    """
    inners = []
    out = []
    i = 0
    n = len(cmd)
    while i < n:
        if cmd[i] in "$<>" and i + 1 < n and cmd[i + 1] == "(":
            depth = 1
            j = i + 2
            while j < n and depth:
                if cmd[j] == "(":
                    depth += 1
                elif cmd[j] == ")":
                    depth -= 1
                j += 1
            inner = cmd[i + 2:j - 1] if depth == 0 else cmd[i + 2:]
            out.append(" " if cmd[i] != "$" else "")
            out.append(CAPTURE_TOKEN % len(inners))
            inners.append(inner)
            i = j
            continue
        out.append(cmd[i])
        i += 1
    return "".join(out), inners


def _tokenize(cmd):
    """Split into words and operators. Raises ValueError on bad quoting."""
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    lex.commenters = ""
    tokens = []
    for tok in lex:
        # punctuation_chars glues adjacent operators into one token (`);`).
        if tok and all(c in "();<>|&" for c in tok):
            k = 0
            while k < len(tok):
                for op in OPERATORS:
                    if tok.startswith(op, k):
                        tokens.append(op)
                        k += len(op)
                        break
                else:
                    k += 1
        else:
            tokens.append(tok)
    return tokens


def _strip_prefix(words):
    """Drop assignments and wrappers ahead of the real command word."""
    i = 0
    while i < len(words):
        w = words[i]
        if ASSIGN_RE.match(w):
            i += 1
            continue
        if w in WRAPPERS:
            takes = WRAPPERS[w]
            i += 1
            while i < len(words) and words[i].startswith("-"):
                i += 2 if words[i] in WRAPPER_VALUE_FLAGS else 1
            i += takes
            continue
        break
    return words[i:]


def credential_commands(cmd, _depth=0):
    """Credential-printing commands in cmd whose output reaches the transcript.

    Returns a list of (label, streams) where streams is a set drawn from
    {"stdout", "stderr"}. Parse failure biases toward redacting: an unparsable
    command that names an emitter anywhere is reported as reaching stdout.
    Only non-empty output is ever replaced, so a wrong "reaches" costs
    nothing when the output was in fact empty.
    """
    if _depth > 5 or not cmd:
        return []
    # fd plumbing that does not move stdout: `2>&1`, `2>/dev/null`. `>&2`
    # DOES move stdout -- onto stderr, which is also in the transcript.
    to_stderr = bool(re.search(r"(?<![\w&>])1?>&2\b", cmd))
    cmd = re.sub(r"(?<![\w&>])[0-9]*>&[0-9]+-?", " ", cmd)
    cmd = re.sub(r"(?<![\w&>])2>>?\s*[^\s;&|]+", " ", cmd)
    cmd = re.sub(r"`([^`]*)`", r"$(\1)", cmd)
    cmd, inners = _extract_captures(cmd)
    inner_hits = [credential_commands(t, _depth + 1) for t in inners]

    try:
        tokens = _tokenize(cmd.replace("\n", " ; "))
    except ValueError:
        tokens = None
    if tokens is None:
        hits = []
        for part in re.split(r"[;&|\n()]+", cmd):
            label = emitter_label(_strip_prefix(part.split()))
            if label:
                hits.append((label, {"stdout", "stderr"}))
        return hits

    # Group into pipelines of simple commands: [[{words, redir}, ...], ...]
    pipelines = [[{"words": [], "redir": False}]]
    prev = None
    for tok in tokens:
        if tok in SEPARATORS:
            pipelines.append([{"words": [], "redir": False}])
        elif tok in PIPES:
            pipelines[-1].append({"words": [], "redir": False})
        elif tok in STDOUT_REDIRECTS:
            pipelines[-1][-1]["redir"] = True
        elif tok in {"<", "<<", "<<<", "<&", ">&"}:
            pass
        elif prev in STDOUT_REDIRECTS or prev in {"<", "<<", "<<<", "<&"}:
            pass  # redirect target, not an argument
        else:
            pipelines[-1][-1]["words"].append(tok)
        prev = tok

    hits = []
    for pipeline in pipelines:
        for idx, simple in enumerate(pipeline):
            argv = _strip_prefix(simple["words"])
            if not argv:
                continue
            prog = os.path.basename(argv[0])
            label = emitter_label(argv)
            streams = {"stdout"}
            if label is None and prog in SHELLS and "-c" in argv:
                c_at = argv.index("-c")
                if c_at + 1 < len(argv):
                    for sub_label, sub_streams in credential_commands(
                            argv[c_at + 1], _depth + 1):
                        label, streams = sub_label, sub_streams
            if label is None and prog in PRINTERS:
                # A printer handed a captured credential prints it.
                for w in argv[1:]:
                    for m in CAPTURE_TOKEN_RE.finditer(w):
                        k = int(m.group(1))
                        if k < len(inner_hits) and inner_hits[k]:
                            label = "%s $(%s)" % (prog, inner_hits[k][0][0])
            if label is None:
                continue
            if label.startswith("security") and "-g" in argv:
                streams = streams | {"stderr"}
            if to_stderr:
                streams = streams | {"stderr"}
            downstream = pipeline[idx + 1:]
            if simple["redir"]:
                continue
            if any(
                os.path.basename((_strip_prefix(d["words"]) or [""])[0])
                not in PASSTHROUGH or d["redir"]
                for d in downstream
            ):
                continue
            hits.append((label, streams))
    return hits


# --- prong 4: vendor prefixes gitleaks does not carry -----------------------
#
# Each entry: (rule id, pattern). Every pattern pairs a prefix that does not
# occur in ordinary prose with a long body, and refuses to start mid-word, so
# `desk-proj-plan` or a bare mention of "the sk-pg- prefix" is left alone.
# Measured against gitleaks 8.30.1: each of these, printed bare on its own
# line, produces no finding.
_B = r"(?<![A-Za-z0-9_-])"
VENDOR_PATTERNS = [
    ("pangram-api-key", re.compile(_B + r"sk-pg-[A-Za-z0-9_-]{24,}")),
    ("openai-project-key",
     re.compile(_B + r"sk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{40,}")),
    ("anthropic-oauth-token",
     re.compile(_B + r"sk-ant-(?:oat|ort|admin)[0-9]{2}-[A-Za-z0-9_-]{40,}")),
    ("1password-service-account-token",
     re.compile(_B + r"ops_eyJ[A-Za-z0-9+/=_-]{40,}")),
    ("sentry-org-token", re.compile(_B + r"sntrys_eyJ[A-Za-z0-9+/=_-]{40,}")),
    ("google-oauth-access-token", re.compile(_B + r"ya29\.[A-Za-z0-9_-]{40,}")),
    ("context7-api-key", re.compile(_B + r"ctx7sk-[A-Za-z0-9-]{24,}")),
    ("mercury-api-token",
     re.compile(r"secret-token:mercury_[a-z]+_[A-Za-z0-9_]{24,}")),
]


def redact_vendor(text):
    """Mask vendor-prefixed credentials by pattern. Returns (text, rule ids)."""
    hits = []
    for rule, pat in VENDOR_PATTERNS:
        text, n = pat.subn(PLACEHOLDER % rule, text)
        if n:
            hits.append(rule)
    return text, hits


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
        """Pattern prongs over one string. Returns (new_text, hit_names)."""
        new, hits = redact_exact(text, secrets)
        new, vrules = redact_vendor(new)
        new, grules = redact_gitleaks(new)
        return new, hits + vrules + grules

    # Prong 3: which streams a credential-printing command wrote to. Only the
    # Bash tool runs a shell command whose output lands in stdout/stderr.
    cmd_streams = {}
    tin = data.get("tool_input")
    if data.get("tool_name") == "Bash" and isinstance(tin, dict) \
            and isinstance(tin.get("command"), str):
        for label, streams in credential_commands(tin["command"]):
            for s in streams:
                cmd_streams.setdefault(s, label)

    # Bash and friends: top-level text fields. Only these are rewritten --
    # touching `interrupted` or `isImage` would break the shape contract, and
    # a replacement whose shape does not match is silently discarded.
    for key in ("stdout", "stderr"):
        text = resp.get(key)
        if not isinstance(text, str) or not text:
            continue
        if key in cmd_streams:
            # The whole stream: its format is unknown by construction.
            label = cmd_streams[key]
            updated[key] = PLACEHOLDER % ("%s of %s" % (key, label))
            changed = True
            all_hits.append("cmd:%s" % label)
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
