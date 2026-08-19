#!/usr/bin/env python3
"""check_style.py — the conventions from STYLE.md that a machine can check.

Five checks, in rough order of how much time each one saves:

1. **Balanced braces.** A truncated generation is a real failure mode when six
   agents are writing several thousand lines each with no compiler. An
   unbalanced file is almost always a file that stopped mid-write.
2. **No bare TODO / FIXME / unimplemented().** The convention is
   `// WAVE n (Un): …` — attributable, and it tells the next agent whose job it
   is. `fatalError` is confined to the one signatures-only file.
3. **No force unwrap outside Tests.** `!`, `try!`, `as!`.
4. **Filename matches its primary type**, with a short allow-list for the files
   that group a vocabulary.
5. **The frozen British-spelling glossary.** Spelling drift is the cheapest
   source of cross-agent mismatch; Apple's own symbols are exempt via
   sdk_allowlist.txt.

Exits non-zero listing every problem.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
KIT = os.path.join(ROOT, "PencilLoopKit")
SOURCES = os.path.join(KIT, "Sources")
TESTS = os.path.join(KIT, "Tests")

FATALERROR_ALLOWED = {"AnchorResolver.swift"}

MARKERS = re.compile(r"\b(TODO|FIXME|XXX|HACK)\b|\bunimplemented\s*\(")
WAVE_MARKER = re.compile(r"//\s*WAVE\s+\d+\s+\(U\d+\):")

# `x!`, `x!.y`, `]!`, `)!` — but not `!=`, and not a prefix `!flag`.
FORCE_UNWRAP = re.compile(r"[A-Za-z0-9_\)\]\?]!(?!=)")
TRY_BANG = re.compile(r"\btry!")
AS_BANG = re.compile(r"\bas!")

TYPE_DECL = re.compile(
    r"^\s*(?:@[\w:.()\s,]+\s*)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|package\s+|final\s+|"
    r"open\s+|indirect\s+|@objc\s+)*"
    r"(struct|class|enum|protocol|actor)\s+([A-Za-z_][A-Za-z0-9_]*)"
)

BANNED_SPELLINGS = {
    "normaliz": "normalis…",
    "recogniz": "recognis…",
    "finaliz": "finalis…",
    "organiz": "organis…",
    "synchroniz": "synchronis…",
    "serializ": "serialis…",
    "analyz": "analys…",
    "materializ": "materialis…",
    "behavior": "behaviour",
    "canceled": "cancelled",
    "labeled": "labelled",
}

TOKEN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def _raw_string_hashes(text, i):
    """Number of leading '#' if a raw string literal opens at i, else 0."""
    h = 0
    while i + h < len(text) and text[i + h] == "#":
        h += 1
    if h and i + h < len(text) and text[i + h] == '"':
        return h
    return 0


def strip_swift(text):
    """Blank out comments and string literals, preserving offsets and newlines.

    Every check below runs on the stripped text, so a `// TODO` inside a doc
    comment about TODOs, or a `!` inside a string, does not trip anything.
    """
    out = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if ch == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
        elif ch == "/" and nxt == "*":
            depth = 1
            out.append("  ")
            i += 2
            while i < n and depth:
                if text[i] == "/" and i + 1 < n and text[i + 1] == "*":
                    depth += 1
                    out.append("  ")
                    i += 2
                elif text[i] == "*" and i + 1 < n and text[i + 1] == "/":
                    depth -= 1
                    out.append("  ")
                    i += 2
                else:
                    out.append("\n" if text[i] == "\n" else " ")
                    i += 1
        elif ch == "#" and _raw_string_hashes(text, i):
            # Swift raw string: #"..."# / ##"""..."""## and friends. The escape
            # rules differ from ordinary literals, so scan for the literal
            # closing delimiter rather than tracking backslashes.
            hashes = _raw_string_hashes(text, i)
            opener = "#" * hashes + ('"""' if text.startswith('"""', i + hashes) else '"')
            closer = ('"""' if opener.endswith('"""') else '"') + "#" * hashes
            out.append(" " * len(opener))
            i += len(opener)
            while i < n and not text.startswith(closer, i):
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            out.append(" " * len(closer))
            i += len(closer)
        elif ch == "#" and re.match(r'#+"', text[i:]):
            # Raw string literal: #"…"#, ##"…"##, #"""…"""#.
            hashes = 0
            j = i
            while j < n and text[j] == "#":
                hashes += 1
                j += 1
            if text.startswith('"""', j):
                closing = '"""' + "#" * hashes
                body = j + 3
            else:
                closing = '"' + "#" * hashes
                body = j + 1
            out.append(" " * (body - i))
            end = text.find(closing, body)
            if end == -1:
                end = n
            for c in text[body:end]:
                out.append("\n" if c == "\n" else " ")
            out.append(" " * len(closing))
            i = min(end + len(closing), n)
        elif text.startswith('"""', i):
            out.append("   ")
            i += 3
            while i < n and not text.startswith('"""', i):
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            out.append("   ")
            i += 3
        elif ch == '"':
            out.append(" ")
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\" and i + 1 < n:
                    out.append("  ")
                    i += 2
                    continue
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            out.append(" ")
            i += 1
        else:
            out.append(ch)
            i += 1
    return "".join(out)


MACRO_ENTRY = re.compile(r"^#[A-Za-z_]\w*$")


def read_list(name):
    """Entries from an allow-list file.

    `#` starts a comment, except when it opens a macro entry — `#Preview`,
    `#Predicate` — which check_decls.py allow-lists with the hash attached so
    that the bare word stays undeclared. The spelling check below matches on
    bare tokens, so a macro entry never exempts anything here; it is read only
    so that the two scripts agree about what this file says.
    """
    path = os.path.join(HERE, name)
    if not os.path.exists(path):
        return set()
    entries = set()
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            for word in line.split():
                if MACRO_ENTRY.match(word):
                    entries.add(word)
                    continue
                if word.startswith("#"):
                    break
                entries.add(word)
    return entries


def swift_files(directory):
    for base, _dirs, names in os.walk(directory):
        for name in sorted(names):
            if name.endswith(".swift"):
                yield os.path.join(base, name)


def line_of(text, index):
    return text.count("\n", 0, index) + 1


def main():
    if not os.path.isdir(KIT):
        print("check_style: no PencilLoopKit yet — nothing to check.")
        return 0

    multi_type_files = read_list("style_allowlist.txt")
    sdk_names = read_list("sdk_allowlist.txt")
    problems = []

    paths = list(swift_files(SOURCES)) if os.path.isdir(SOURCES) else []
    test_paths = list(swift_files(TESTS)) if os.path.isdir(TESTS) else []

    for path in paths + test_paths:
        relative = os.path.relpath(path, ROOT)
        name = os.path.basename(path)
        is_test = path in test_paths
        with open(path, "r", encoding="utf-8") as handle:
            raw = handle.read()
        code = strip_swift(raw)

        # 1 · braces
        opens = code.count("{")
        closes = code.count("}")
        if opens != closes:
            problems.append(
                f"{relative}: unbalanced braces — {opens} open, {closes} close. "
                f"A file that stops mid-write looks exactly like this."
            )

        # 2 · markers — scanned in the RAW text, because a marker lives in a
        # comment and the stripped copy has no comments left in it.
        for match in MARKERS.finditer(raw):
            number = line_of(raw, match.start())
            problems.append(
                f"{relative}:{number}: bare `{match.group(0).strip()}` — use "
                f"`// WAVE n (Un): …` so the marker has an owner (STYLE.md § 4)."
            )
        for match in re.finditer(r"\bfatalError\s*\(", code):
            if name not in FATALERROR_ALLOWED:
                number = line_of(code, match.start())
                problems.append(
                    f"{relative}:{number}: fatalError is allowed only in "
                    f"{', '.join(sorted(FATALERROR_ALLOWED))}. Throw a "
                    f"PencilLoopError or return an empty value (STYLE.md § 4)."
                )

        # 3 · force unwrapping
        if not is_test:
            for pattern, label in (
                (TRY_BANG, "try!"),
                (AS_BANG, "as!"),
                (FORCE_UNWRAP, "force unwrap"),
            ):
                for match in pattern.finditer(code):
                    number = line_of(code, match.start())
                    problems.append(
                        f"{relative}:{number}: {label} — use guard let, ??, or "
                        f"throw (STYLE.md § 5)."
                    )

        # 4 · filename matches primary type
        declared = []
        depth = 0
        for line in code.splitlines():
            match = TYPE_DECL.match(line)
            if match and depth == 0:
                declared.append(match.group(2))
            depth += line.count("{") - line.count("}")
        stem = name[: -len(".swift")]
        if declared and stem not in multi_type_files and declared[0] != stem:
            problems.append(
                f"{relative}: primary type is `{declared[0]}` but the file is "
                f"`{name}`. One public type per file, filename == type name "
                f"(STYLE.md § 3)."
            )
        if len(declared) > 1 and stem not in multi_type_files:
            problems.append(
                f"{relative}: declares {len(declared)} top-level types "
                f"({', '.join(declared)}). Split them, or ask the lead to "
                f"allow-list the file (STYLE.md § 3)."
            )

        # 5 · spelling
        for match in TOKEN.finditer(code):
            token = match.group(0)
            if token in sdk_names:
                continue
            lowered = token.lower()
            for banned, correct in BANNED_SPELLINGS.items():
                if banned in lowered:
                    number = line_of(code, match.start())
                    problems.append(
                        f"{relative}:{number}: `{token}` uses the American "
                        f"spelling; this project writes `{correct}`. If it is an "
                        f"Apple symbol, add it to tooling/lint/sdk_allowlist.txt "
                        f"(STYLE.md § 2)."
                    )
                    break

    for problem in problems:
        print(f"check_style: {problem}")
    if problems:
        print(f"check_style: {len(problems)} problem(s).")
        return 1
    print(f"check_style: OK ({len(paths) + len(test_paths)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
