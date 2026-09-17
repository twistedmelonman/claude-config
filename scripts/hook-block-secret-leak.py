#!/usr/bin/env python3
"""Detect commands that would print a live secret into the transcript.

Reads the command text on stdin. Writes one `VARNAME\treason` line per finding
to stdout; empty output means allow. Never writes a secret value anywhere.

Two prongs, because the two leak shapes are structurally different:

  Prong 1 (value match): the secret's literal value appears in the command.
  Prong 2 (expansion form): the command contains a construct that will expand
  a secret at runtime -- the command text itself is clean.

Prong 2 is the one that matters. Both real-world leaks of GH_TOKEN were
`${GH_TOKEN:-...}`, whose text contains nothing token-shaped.
"""

import os
import re
import sys

# A variable is a rotation candidate if its NAME suggests a credential. Name
# hints (not value patterns) because value patterns cannot distinguish a real
# token from a test fixture, and fixtures are common in this codebase.
#
# These match as substrings, so every entry must be a word that does not occur
# inside a common non-secret name. `PAT` is deliberately absent: it appears in
# PATH, PYTHONPATH, GOPATH, NODE_PATH and friends, which are long enough to
# clear MIN_SECRET_LEN and would make `echo "$PATH"` a blocked command.
NAME_HINTS = ("TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL")

# Hints that must match as a whole underscore-delimited word. `KEY` needs this:
# as a substring it also matches KEYBOARD, KEYMAP, MONKEYPATCH.
NAME_HINTS_WORD = ("KEY", "APIKEY", "PAT")

# Names that match a hint but are not secrets. Blocking on these would be a
# pure false positive.
NAME_EXCEPTIONS = frozenset(
    {
        "KEYBOARD",
        "SSH_AUTH_SOCK",
        "KEYMAP",
        "KEYTIMEOUT",
        # A path to a keystore is not the keystore's password.
        "KEBAB_RELEASE_KEYSTORE_PATH",
    }
)

# Below this length a "secret" is almost certainly a flag, an alias, or a short
# identifier, and short values produce substring false positives.
MIN_SECRET_LEN = 16


def secret_vars():
    """Live environment variables that look like credentials."""
    out = {}
    for name, value in os.environ.items():
        # Exported bash functions carry their whole body as the value; they
        # routinely contain the word "token" without being secrets.
        if name.startswith("BASH_FUNC_"):
            continue
        if name in NAME_EXCEPTIONS:
            continue
        upper = name.upper()
        substring_hit = any(h in upper for h in NAME_HINTS)
        word_hit = any(
            re.search(rf"(^|_){h}(_|$)", upper) for h in NAME_HINTS_WORD
        )
        if not (substring_hit or word_hit):
            continue
        if len(value) < MIN_SECRET_LEN:
            continue
        out[name] = value
    return out


def find_value_matches(cmd, secrets):
    """Prong 1: the literal secret value appears in the command text."""
    return [
        (name, "literal value present in command text")
        for name, value in secrets.items()
        if value in cmd
    ]


# Expansion forms that print the VALUE when the variable is set.
#   ${VAR:-x} / ${VAR-x}   substitute default -- prints value when set
#   ${VAR:=x} / ${VAR=x}   assign default     -- prints value when set
#   ${VAR:?x} / ${VAR?x}   error if unset     -- prints value when set
# Deliberately NOT flagged, because they cannot print the value:
#   ${VAR:+x}   prints the ALTERNATE, never the value
#   ${#VAR}     prints the length
_DANGEROUS_BRACE = r"\$\{%s:?[-=?]"

# A bare $VAR / ${VAR} reaching a command that writes to stdout/stderr.
#
# `printenv`, `declare -p` and friends belong here as well as in _DUMP: given a
# NAME argument they print that one variable's value without any `$` sigil, so
# the expansion patterns above would never see them. Note `\bprint\b` does not
# match inside `printenv`, which is why it is listed separately.
_ECHOING = (
    r"(\b(echo|printf|print|cat|tee|write|say|logger)\b"
    r"|\b(printenv|declare\s+-[px]+|typeset\s+-[px]+|export\s+-p)\b)"
)

# `env`, `printenv`, `export -p`, `declare -p`, `set` with no filtering all
# dump values.
# Bare `set` with no arguments dumps every variable AND every function body.
# `set -euo pipefail` and `set +x` do not match: they have arguments.
_DUMP = (
    r"(^|[;&|]\s*|\$\(\s*|`\s*)"
    r"(env|printenv|export\s+-p|declare\s+-[px]+|typeset\s+-[px]+|set)"
    r"\s*($|[;&|)`])"
)

# The gap between a printing command and a `$VAR` must not cross a newline.
#
# `[^|;&]*` (no newline exclusion) made an `echo` on ANY earlier line poison
# every later secret expansion in the same multi-line command: `echo "hi"` on
# line 1 plus `GH_TOKEN="$GH_TOKEN_NOS" gh api` on line 2 blocked, while line 2
# alone allowed. That shape -- a survey script with a heading -- is routine, and
# the spurious blocks trained exactly the "just work around the hook" reflex a
# security guard cannot afford.
#
# A backslash-newline is a line CONTINUATION, not a separator: `echo \<newline>
# "$GH_TOKEN"` is one logical command and must still block. So the gap allows
# an escaped newline while rejecting a bare one.
_GAP = r"(?:[^|;&\n]|\\\n)*"

# A heredoc delimiter word, used to tell `<<EOF` (body is expanded) from
# `<<'EOF'` (body is literal).
_HEREDOC_ID = r"[A-Za-z_][A-Za-z0-9_]*"

# A dump piped into something that keeps only the NAME half is safe, and is a
# genuinely useful idiom -- it is how you answer "is this set?" for many vars
# at once. Without this exemption the hook blocks `env | cut -d= -f1`, which
# prints no values at all.
_NAMES_ONLY = (
    r"awk[^|]*(-F\s*=[^|]*)?\{[^}]*print\s+\$1"
    r"|awk[^|]*-F\s*=[^|]*\$1"
    r"|cut\s+(-d\s*=?\s*)?-f\s*1"
    r"|cut\s+-d\s*=\s*-f\s*1"
    r"|sed\s+[^|]*s/=\.\*//"
    r"|grep\s+-o\s+[^|]*\^\[\^=\]"
    r"|compgen\s+-v"
)


def find_expansion_forms(cmd, secrets):
    """Prong 2: the command will expand a secret when the shell runs it."""
    findings = []

    for name in secrets:
        esc = re.escape(name)

        if re.search(_DANGEROUS_BRACE % esc, cmd):
            findings.append(
                (name, "${VAR:-...} style default expands the value when set")
            )
            continue

        # Bare expansion feeding a command that prints.
        #
        # The ONLY operators after the name that cannot print any part of the
        # value are `:+` and `+` (substitute an alternate when set). Everything
        # else reveals some or all of it:
        #   ${VAR:0:4}  first 4 chars      ${VAR:1}    all but the first
        #   ${VAR#pfx}  strips a prefix    ${VAR%sfx}  strips a suffix
        #   ${VAR/a/b}  search & replace
        # `${#VAR}` (length) is not affected by this lookahead: its `#` comes
        # BEFORE the name, so the pattern never reaches this point for it.
        bare = rf"{_ECHOING}{_GAP}\$\{{?{esc}\b(?!:?\+)"
        if re.search(bare, cmd):
            findings.append((name, "bare $VAR passed to a command that prints"))
            continue

        # `printenv GH_TOKEN` / `declare -p GH_TOKEN` take the NAME with no `$`
        # and print the value.
        named_dump = rf"\b(printenv|declare\s+-[px]+|typeset\s+-[px]+)\b{_GAP}\b{esc}\b"
        if re.search(named_dump, cmd):
            findings.append((name, "prints this variable's value by name"))
            continue

        # An UNQUOTED heredoc delimiter leaves the body subject to expansion, so
        # `cat <<EOF` ... `$SECRET` ... `EOF` prints the value. Before the _GAP
        # fix this was caught only incidentally, by the gap spanning newlines;
        # scoping the gap to one line would have silently dropped it. It is a
        # real leak shape, so it gets its own rule rather than riding on a bug.
        #
        # `<<'EOF'` and `<<"EOF"` disable expansion entirely -- the body reaches
        # the file verbatim -- so a quoted delimiter is NOT flagged. That is what
        # makes writing a script that references a secret var possible at all.
        if re.search(rf"<<-?\s*(?![\"']){_HEREDOC_ID}", cmd) and re.search(
            rf"\$\{{?{esc}\b(?!:?\+)", cmd
        ):
            findings.append(
                (name, "unquoted heredoc expands this variable into output")
            )

    # A dump is not attributable to one variable; it exposes all of them.
    dump = re.search(_DUMP, cmd)
    if dump:
        tail = cmd[dump.end() :]
        if not re.search(_NAMES_ONLY, tail):
            findings.append(
                ("<all environment>", "dumps every variable's value")
            )

    return findings


def main():
    cmd = sys.stdin.read()
    if not cmd.strip():
        return 0

    secrets = secret_vars()
    if not secrets:
        return 0

    findings = find_value_matches(cmd, secrets)
    findings += find_expansion_forms(cmd, secrets)

    # Deduplicate while preserving order; a command can trip both prongs.
    seen = set()
    for name, reason in findings:
        if name in seen:
            continue
        seen.add(name)
        print(f"{name}\t{reason}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
