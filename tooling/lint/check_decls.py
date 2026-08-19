#!/usr/bin/env python3
"""check_decls.py — every type is declared exactly once, and every type used is
declared somewhere.

Three checks:

1. **No duplicate top-level type names, repo-wide.** Two `Renderer` types in two
   modules is legal Swift and unreadable in a stack trace; two in the *same*
   module is a compile error nobody here can see.
2. **Every name declared in Core/Contracts is declared exactly once**, which is
   the same check narrowed to the file set that everything else compiles
   against.
3. **Every project-looking type reference resolves to a declaration.** This is
   the one that catches the real failure mode: an agent calling
   `ReviewBundleBuilder.build(…)` when the frozen name is
   `ReviewBundleBuilding.build(…)`. SDK noise is kept out by
   sdk_allowlist.txt plus a prefix rule.

Two things that look like type references and are not, and are therefore
handled rather than allow-listed as if they were types:

- **Macro expansions.** `#Preview` and `#Predicate` are macros, not types. They
  are matched with their `#` and looked up as `#Preview` / `#Predicate`, so a
  macro nobody has heard of is still reported — but the bare word `Preview` no
  longer has to be accepted everywhere in the repo to let a view have a preview.
- **Generic parameters.** `struct LibraryView<Detail: View>` declares `Detail`;
  it is not a reference to anything. Reading it as one is what pushed a real
  generic parameter down to a single letter to appease this script, which is the
  linter editing the code rather than the other way round.

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
CONTRACTS = os.path.join(SOURCES, "Core", "Contracts")

# Apple ships thousands of types. Anything with one of these prefixes is assumed
# to be theirs rather than listed by name.
SDK_PREFIXES = (
    "NS", "UI", "PK", "PDF", "CG", "CA", "CF", "CI", "CL", "CT", "AV", "SF",
    "SK", "MK", "WK", "UT", "OS", "QL", "XC",
)

DECL_RE = re.compile(
    r"^(?P<indent>\s*)(?:@[\w:.()\s,]+\s*)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|package\s+|final\s+|"
    r"open\s+|indirect\s+|@objc\s+|nonisolated\s+)*"
    r"(?P<kind>struct|class|enum|protocol|actor|typealias)\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
)

TYPE_REF = re.compile(r"\b([A-Z][A-Za-z0-9_]{2,})\b")

# `struct LibraryView<Detail: View>`, `func map<Element>(…)`. The names inside
# the angle brackets are declared by that line, not referenced by it. Nested
# brackets (`<T: Collection<Int>>`) are deliberately not matched: the parameter
# is still picked up from the simpler declarations that surround it, and a regex
# that tries to balance angle brackets in Swift is a regex that is wrong.
GENERIC_PARAMETERS = re.compile(
    r"\b(?:struct|class|enum|actor|protocol|typealias|func)\s+"
    r"[A-Za-z_]\w*\s*<([^<>{}]*)>"
)

IMPORT_LINE = re.compile(r"^\s*(?:@\w+\s+)*import\b")

# Words that appear capitalised in code without being types. Compilation
# condition names live here rather than in sdk_allowlist.txt: they are not
# Apple's types, they are not types at all, and listing them as SDK names told
# check_style.py to exempt them from the spelling glossary as a side effect.
NON_TYPES = {
    "MARK", "SAFETY", "WAVE", "OK", "TODO", "JSON", "PNG", "PDF", "URL", "UUID",
    "SHA", "UTF", "ASCII", "API", "IR", "UI", "SAME", "THREAD", "NEW",
    "PENCILLOOP_STROKE_RECOGNIZER", "PENCILLOOP_LEGACY_SPEECH",
}


MACRO_ENTRY = re.compile(r"^#[A-Za-z_]\w*$")


def read_allowlist(name):
    """Entries from an allow-list file.

    `#` starts a comment, *except* when it opens a macro entry — `#Preview`,
    `#Predicate`. Those are how a macro is allow-listed without its bare name
    becoming acceptable everywhere in the repo, so the reader has to be able to
    tell `#Preview` from `# Preview is Apple's`.
    """
    path = os.path.join(HERE, name)
    entries = set()
    if not os.path.exists(path):
        return entries
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


def _raw_string_hashes(text, i):
    """Number of leading '#' if a raw string literal opens at i, else 0."""
    h = 0
    while i + h < len(text) and text[i + h] == "#":
        h += 1
    if h and i + h < len(text) and text[i + h] == '"':
        return h
    return 0


def strip_swift(text):
    """Blank out comments and string literals, preserving offsets."""
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


def declarations(code):
    """Yield (name, kind, line, depth) for every type declaration."""
    depth = 0
    for number, line in enumerate(code.splitlines(), 1):
        match = DECL_RE.match(line)
        if match:
            yield match.group("name"), match.group("kind"), number, depth
        depth += line.count("{") - line.count("}")


def generic_parameters(code):
    """Every generic parameter name declared in a file."""
    names = set()
    for match in GENERIC_PARAMETERS.finditer(code):
        for part in match.group(1).split(","):
            head = part.split(":")[0].strip()
            if re.fullmatch(r"[A-Za-z_]\w*", head):
                names.add(head)
    return names


def qualified_name(line, start, name):
    """`Qualifier.Name` when the reference is a member access, else `name`."""
    if start == 0 or line[start - 1] != ".":
        return name
    end = start - 1
    begin = end
    while begin > 0 and (line[begin - 1].isalnum() or line[begin - 1] == "_"):
        begin -= 1
    qualifier = line[begin:end]
    return "{}.{}".format(qualifier, name) if qualifier else name


def looks_like_sdk(name, sdk_names):
    if name in sdk_names or name in NON_TYPES:
        return True
    return name.startswith(SDK_PREFIXES)


def main():
    if not os.path.isdir(SOURCES):
        print("check_decls: no PencilLoopKit/Sources yet — nothing to check.")
        return 0

    sdk_names = read_allowlist("sdk_allowlist.txt")
    problems = []

    paths = list(swift_files(SOURCES))
    if os.path.isdir(TESTS):
        paths += list(swift_files(TESTS))

    top_level = {}      # name -> [(relative path, line)]
    every_name = set()  # top level and nested
    file_codes = {}

    for path in paths:
        relative = os.path.relpath(path, ROOT)
        with open(path, "r", encoding="utf-8") as handle:
            code = strip_swift(handle.read())
        file_codes[path] = code
        for name, _kind, number, depth in declarations(code):
            every_name.add(name)
            if depth == 0:
                top_level.setdefault(name, []).append((relative, number))
        # Declared by their declaration line, not referenced by it.
        every_name |= generic_parameters(code)

    # 1 · duplicates
    for name, sites in sorted(top_level.items()):
        if len(sites) > 1:
            where = "; ".join(f"{p}:{n}" for p, n in sites)
            problems.append(
                f"`{name}` is declared {len(sites)} times: {where}. Top-level "
                f"type names are unique repo-wide (STYLE.md § 3)."
            )

    # 2 · the contract file set
    if os.path.isdir(CONTRACTS):
        contract_names = set()
        for path in swift_files(CONTRACTS):
            code = file_codes.get(path, "")
            for name, _kind, _number, depth in declarations(code):
                if depth == 0:
                    contract_names.add(name)
        for name in sorted(contract_names):
            count = len(top_level.get(name, []))
            if count != 1:
                problems.append(
                    f"contract type `{name}` is declared {count} times repo-wide; "
                    f"it must be declared exactly once, in Core/Contracts."
                )
        if not contract_names:
            problems.append(
                "Core/Contracts declares no types. Either the directory is empty "
                "or the declaration regex needs work."
            )

    # 3 · unresolved references
    known = every_name | sdk_names
    for path in paths:
        relative = os.path.relpath(path, ROOT)
        code = file_codes[path]
        seen = set()
        for number, line in enumerate(code.splitlines(), 1):
            # An import names a module, not a type.
            if IMPORT_LINE.match(line):
                continue
            for match in TYPE_REF.finditer(line):
                name = match.group(1)
                start = match.start()

                # `#Preview`, `#Predicate`: a macro, not a type. Looked up with
                # its `#`, so allowing one macro does not allow its bare name
                # everywhere in the repo.
                if start > 0 and line[start - 1] == "#":
                    if "#" + name in sdk_names:
                        continue
                    if name in seen:
                        continue
                    seen.add(name)
                    problems.append(
                        f"{relative}:{number}: `#{name}` is a macro this check "
                        f"does not know. Add `#{name}` — with the hash — to "
                        f"tooling/lint/sdk_allowlist.txt if it is Apple's."
                    )
                    continue

                if name in known or looks_like_sdk(name, sdk_names):
                    continue
                # A member of a qualified name — `Schema.Version`,
                # `VersionedSchema.Type` — is allow-listed as `Qualifier.Member`
                # rather than as a bare name, so that allowing one spelling in
                # one place does not allow it everywhere in the repo.
                if qualified_name(line, match.start(), name) in sdk_names:
                    continue
                if name in seen:
                    continue
                seen.add(name)
                problems.append(
                    f"{relative}:{number}: `{name}` is used but declared "
                    f"nowhere in the repo. Either it is a typo for a frozen "
                    f"contract name, or it is an SDK type that belongs in "
                    f"tooling/lint/sdk_allowlist.txt."
                )

    for problem in problems:
        print(f"check_decls: {problem}")
    if problems:
        print(f"check_decls: {len(problems)} problem(s).")
        return 1
    print(f"check_decls: OK ({len(top_level)} top-level types across {len(paths)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
