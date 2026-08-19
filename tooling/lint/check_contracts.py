#!/usr/bin/env python3
"""check_contracts.py — every conformance actually implements its protocol.

This is the check that is only possible because the signatures were frozen
first. For each `: SomeProtocol` in the repo, it reads the protocol's required
members out of Core/Contracts and looks for a matching member on the conforming
type — matching on name, argument labels, `async`, `throws` and `static`, since
those four are what a Wave 1 agent gets subtly wrong when working from memory.

Regex, not a parser. That is fine here precisely because the contract text is
frozen and written in one house style; it is not fine for arbitrary Swift, and
this script does not pretend otherwise. False negatives are possible, false
positives are rare, and a missing method reported here is always real.

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

# Where the frozen protocols live.
CONTRACT_DIRS = [os.path.join(SOURCES, "Core", "Contracts")]
CONTRACT_FILES = [os.path.join(SOURCES, "AppUI", "Support", "AppEnvironment.swift")]

MODIFIERS = (
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|package\s+|final\s+|"
    r"open\s+|override\s+|nonisolated\s+|static\s+|class\s+|mutating\s+|"
    r"@discardableResult\s+|@inlinable\s+|@MainActor\s+|@objc\s+|"
    r"private\(set\)\s+|public\(set\)\s+|internal\(set\)\s+|"
    r"fileprivate\(set\)\s+|lazy\s+|weak\s+|unowned\s+|isolated\s+)*"
)

PROTOCOL_DECL = re.compile(
    r"^\s*(?:public\s+|package\s+)?protocol\s+([A-Za-z_]\w*)", re.MULTILINE
)
TYPE_DECL = re.compile(
    r"^\s*(?:@[\w:.()\s,]+\s*)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|package\s+|final\s+|"
    r"open\s+|nonisolated\s+)*"
    r"(?:struct|class|actor|enum)\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*:\s*([^{]+)\{",
    re.MULTILINE,
)
EXTENSION_DECL = re.compile(
    r"^\s*(?:public\s+|package\s+)?extension\s+([A-Za-z_][\w.]*)\s*(?::\s*([^{]+?))?\s*(?:where[^{]*)?\{",
    re.MULTILINE,
)
FUNC_DECL = re.compile(
    r"^\s*" + MODIFIERS + r"func\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*\(", re.MULTILINE
)
VAR_DECL = re.compile(
    r"^\s*" + MODIFIERS + r"(?:var|let)\s+([A-Za-z_]\w*)\s*:", re.MULTILINE
)


def _raw_string_hashes(text, i):
    """Number of leading '#' if a raw string literal opens at i, else 0."""
    h = 0
    while i + h < len(text) and text[i + h] == "#":
        h += 1
    if h and i + h < len(text) and text[i + h] == '"':
        return h
    return 0


def strip_swift(text):
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


def swift_files(directory):
    for base, _dirs, names in os.walk(directory):
        for name in sorted(names):
            if name.endswith(".swift"):
                yield os.path.join(base, name)


def matching_brace(code, open_index):
    """Index just past the `}` matching the `{` at open_index."""
    depth = 0
    i = open_index
    while i < len(code):
        if code[i] == "{":
            depth += 1
        elif code[i] == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return len(code)


def split_top_level(text, separator=","):
    """Split on separators outside (), [] and <>. `->` is masked first."""
    text = text.replace("->", "\x00\x00")
    parts = []
    depth = 0
    current = []
    for ch in text:
        if ch in "([<":
            depth += 1
        elif ch in ")]>":
            depth -= 1
        if ch == separator and depth == 0:
            parts.append("".join(current))
            current = []
        else:
            current.append(ch)
    parts.append("".join(current))
    return [p.replace("\x00\x00", "->").strip() for p in parts if p.strip()]


def parameter_labels(params_text):
    labels = []
    for part in split_top_level(params_text):
        head = split_top_level(part, ":")
        if not head:
            continue
        words = head[0].split()
        if not words:
            continue
        labels.append(words[0])
    return labels


def function_signature(code, start_index, name):
    """Build `name(a:b:) [static] [async] [throws]` from a declaration."""
    open_paren = code.index("(", start_index)
    depth = 0
    i = open_paren
    while i < len(code):
        if code[i] == "(":
            depth += 1
        elif code[i] == ")":
            depth -= 1
            if depth == 0:
                break
        i += 1
    params = code[open_paren + 1:i]
    tail = code[i + 1:i + 120].split("\n")[0]
    labels = parameter_labels(params)
    flags = []
    line_start = code.rfind("\n", 0, start_index) + 1
    head = code[line_start:open_paren]
    if re.search(r"\bstatic\b", head):
        flags.append("static")
    if re.search(r"\basync\b", tail):
        flags.append("async")
    if re.search(r"\bthrows\b|\brethrows\b", tail):
        flags.append("throws")
    key = "{}({})".format(name, "".join(label + ":" for label in labels))
    if flags:
        key += " " + " ".join(flags)
    return key


def members_in(code, body_start, body_end):
    """Every func and stored/computed property declared directly in a body."""
    funcs = set()
    variables = set()
    segment = code[body_start:body_end]
    offset = body_start
    for match in FUNC_DECL.finditer(segment):
        funcs.add(function_signature(code, offset + match.start(), match.group(1)))
    for match in VAR_DECL.finditer(segment):
        variables.add(match.group(1))
    return funcs, variables


def main():
    if not os.path.isdir(SOURCES):
        print("check_contracts: no PencilLoopKit/Sources yet — nothing to check.")
        return 0

    problems = []
    contract_paths = []
    for directory in CONTRACT_DIRS:
        if os.path.isdir(directory):
            contract_paths += list(swift_files(directory))
    contract_paths += [p for p in CONTRACT_FILES if os.path.exists(p)]

    # 1 · read the frozen protocols
    protocols = {}
    for path in contract_paths:
        with open(path, "r", encoding="utf-8") as handle:
            code = strip_swift(handle.read())
        for match in PROTOCOL_DECL.finditer(code):
            name = match.group(1)
            brace = code.find("{", match.end())
            if brace == -1:
                continue
            end = matching_brace(code, brace)
            funcs, variables = members_in(code, brace, end)
            protocols[name] = {
                "funcs": funcs,
                "vars": variables,
                "file": os.path.relpath(path, ROOT),
            }

    if not protocols:
        print("check_contracts: no protocols found in Core/Contracts — nothing to check.")
        return 0

    # 2 · every type and what it conforms to, plus its members
    paths = list(swift_files(SOURCES))
    if os.path.isdir(TESTS):
        paths += list(swift_files(TESTS))

    conformances = {}   # type name -> set of protocol names
    members = {}        # type name -> (funcs, vars)
    where = {}          # type name -> "path:line"

    def record_members(name, funcs, variables):
        existing_funcs, existing_vars = members.get(name, (set(), set()))
        members[name] = (existing_funcs | funcs, existing_vars | variables)

    for path in paths:
        relative = os.path.relpath(path, ROOT)
        with open(path, "r", encoding="utf-8") as handle:
            code = strip_swift(handle.read())

        for match in TYPE_DECL.finditer(code):
            name = match.group(1)
            inherited = match.group(2)
            brace = code.index("{", match.start())
            end = matching_brace(code, brace)
            funcs, variables = members_in(code, brace, end)
            record_members(name, funcs, variables)
            listed = [
                item.split("<")[0].strip()
                for item in split_top_level(inherited.split(" where ")[0])
            ]
            conformances.setdefault(name, set()).update(listed)
            where.setdefault(name, f"{relative}:{code.count(chr(10), 0, match.start()) + 1}")

        for match in EXTENSION_DECL.finditer(code):
            name = match.group(1).split(".")[0]
            brace = code.index("{", match.start())
            end = matching_brace(code, brace)
            funcs, variables = members_in(code, brace, end)
            record_members(name, funcs, variables)
            if match.group(2):
                listed = [
                    item.split("<")[0].strip()
                    for item in split_top_level(match.group(2).split(" where ")[0])
                ]
                conformances.setdefault(name, set()).update(listed)
                where.setdefault(name, f"{relative}:{code.count(chr(10), 0, match.start()) + 1}")

    # 3 · compare
    checked = 0
    for type_name, adopted in sorted(conformances.items()):
        for protocol_name in sorted(adopted):
            contract = protocols.get(protocol_name)
            if contract is None:
                continue
            checked += 1
            present_funcs, present_vars = members.get(type_name, (set(), set()))
            present_names = {key.split("(")[0] for key in present_funcs}
            for required in sorted(contract["funcs"]):
                if required in present_funcs:
                    continue
                required_name = required.split("(")[0]
                if required_name in present_names:
                    near = sorted(
                        key for key in present_funcs if key.split("(")[0] == required_name
                    )
                    problems.append(
                        f"{where.get(type_name, '?')}: `{type_name}: {protocol_name}` "
                        f"has `{near[0]}` but the contract says `{required}` "
                        f"({contract['file']}). Argument labels, async and throws "
                        f"all have to match."
                    )
                else:
                    problems.append(
                        f"{where.get(type_name, '?')}: `{type_name}: {protocol_name}` "
                        f"is missing `{required}` (declared in {contract['file']})."
                    )
            for required in sorted(contract["vars"]):
                if required not in present_vars:
                    problems.append(
                        f"{where.get(type_name, '?')}: `{type_name}: {protocol_name}` "
                        f"is missing the property `{required}` "
                        f"(declared in {contract['file']})."
                    )

    for problem in problems:
        print(f"check_contracts: {problem}")
    if problems:
        print(f"check_contracts: {len(problems)} problem(s).")
        return 1
    print(
        f"check_contracts: OK ({len(protocols)} contract protocols, "
        f"{checked} conformance(s) checked)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
