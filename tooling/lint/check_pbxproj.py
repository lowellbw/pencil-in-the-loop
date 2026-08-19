#!/usr/bin/env python3
"""Structural check for PencilLoop.xcodeproj/project.pbxproj.

A hand-authored pbxproj is the single worst thing in this repo to get wrong: Xcode
answers a malformed one with "The project file cannot be parsed" and no line
number, and the failure looks identical whether you dropped a brace or misspelled
an isa. So this parses the file properly rather than grepping it, and says exactly
what is wrong.

Checks, in order:
  1. The OpenStep plist parses at all (this subsumes brace/paren balance).
  2. Every object ID is 24 uppercase hex characters and is defined exactly once.
  3. Every ID referenced anywhere resolves to a defined object.
  4. Every `isa` is one of the types Xcode actually understands.
  5. The root PBXProject names both targets, and they are the expected two.
  6. The app target embeds the extension: a PBXCopyFilesBuildPhase with
     dstSubfolderSpec = 13 (PlugIns / Foundation Extensions).
  7. Every build configuration has a baseConfigurationReference, it resolves,
     and the xcconfig it points at exists on disk.
  8. The XCLocalSwiftPackageReference points at a directory that exists.

Python 3, standard library only. Exits 1 listing every problem found.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PBXPROJ = REPO_ROOT / "PencilLoop.xcodeproj" / "project.pbxproj"

UUID_RE = re.compile(r"^[0-9A-F]{24}$")

EXPECTED_TARGETS = {"PencilLoop", "ReviewShareExtension"}

# Only the isa values this project is allowed to use. Deliberately short: if a
# future change needs a new one, adding it here is a moment's thought about
# whether the project really needs to grow that kind of object.
KNOWN_ISA = {
    "PBXBuildFile",
    "PBXContainerItemProxy",
    "PBXCopyFilesBuildPhase",
    "PBXFileReference",
    "PBXFileSystemSynchronizedBuildFileExceptionSet",
    "PBXFileSystemSynchronizedRootGroup",
    "PBXFrameworksBuildPhase",
    "PBXGroup",
    "PBXNativeTarget",
    "PBXProject",
    "PBXResourcesBuildPhase",
    "PBXSourcesBuildPhase",
    "PBXTargetDependency",
    "XCBuildConfiguration",
    "XCConfigurationList",
    "XCLocalSwiftPackageReference",
    "XCSwiftPackageProductDependency",
}


class ParseError(Exception):
    pass


class Parser:
    """Just enough of the OpenStep property list format for a pbxproj."""

    def __init__(self, text: str) -> None:
        self.text = text
        self.pos = 0
        self.duplicate_keys: list[str] = []

    # -- lexing helpers -------------------------------------------------

    def line_of(self, pos: int) -> int:
        return self.text.count("\n", 0, pos) + 1

    def error(self, message: str) -> ParseError:
        return ParseError(f"line {self.line_of(self.pos)}: {message}")

    def skip_trivia(self) -> None:
        while self.pos < len(self.text):
            ch = self.text[self.pos]
            if ch in " \t\r\n":
                self.pos += 1
            elif self.text.startswith("/*", self.pos):
                end = self.text.find("*/", self.pos + 2)
                if end == -1:
                    raise self.error("unterminated /* comment")
                self.pos = end + 2
            elif self.text.startswith("//", self.pos):
                end = self.text.find("\n", self.pos)
                self.pos = len(self.text) if end == -1 else end
            else:
                return

    def expect(self, ch: str) -> None:
        self.skip_trivia()
        if self.pos >= len(self.text) or self.text[self.pos] != ch:
            found = self.text[self.pos : self.pos + 20] if self.pos < len(self.text) else "<eof>"
            raise self.error(f"expected {ch!r}, found {found!r}")
        self.pos += 1

    def peek(self) -> str:
        self.skip_trivia()
        return self.text[self.pos] if self.pos < len(self.text) else ""

    # -- values ---------------------------------------------------------

    def parse_string(self) -> str:
        ch = self.peek()
        if ch == '"':
            self.pos += 1
            out: list[str] = []
            while True:
                if self.pos >= len(self.text):
                    raise self.error("unterminated quoted string")
                c = self.text[self.pos]
                if c == "\\":
                    out.append(self.text[self.pos + 1 : self.pos + 2])
                    self.pos += 2
                elif c == '"':
                    self.pos += 1
                    return "".join(out)
                else:
                    out.append(c)
                    self.pos += 1
        start = self.pos
        while self.pos < len(self.text) and (
            self.text[self.pos].isalnum() or self.text[self.pos] in "_$./-+@:<>~*"
        ):
            self.pos += 1
        if self.pos == start:
            raise self.error(f"expected a value, found {self.text[start:start + 20]!r}")
        return self.text[start : self.pos]

    def parse_value(self):
        ch = self.peek()
        if ch == "{":
            return self.parse_dict()
        if ch == "(":
            return self.parse_array()
        if ch == "":
            raise self.error("unexpected end of file")
        return self.parse_string()

    def parse_array(self) -> list:
        self.expect("(")
        items: list = []
        while True:
            if self.peek() == ")":
                self.pos += 1
                return items
            items.append(self.parse_value())
            if self.peek() == ",":
                self.pos += 1
            elif self.peek() == ")":
                self.pos += 1
                return items
            else:
                raise self.error("expected ',' or ')' in array")

    def parse_dict(self) -> dict:
        self.expect("{")
        out: dict = {}
        while True:
            if self.peek() == "}":
                self.pos += 1
                return out
            key = self.parse_string()
            self.expect("=")
            value = self.parse_value()
            self.expect(";")
            if key in out:
                self.duplicate_keys.append(key)
            out[key] = value

    def parse_root(self) -> dict:
        value = self.parse_dict()
        self.skip_trivia()
        if self.pos != len(self.text):
            raise self.error("trailing content after the closing brace")
        return value


def collect_references(node, out: set[str]) -> None:
    """Every 24-hex-char string appearing as a *value* is an object reference."""
    if isinstance(node, dict):
        for value in node.values():
            collect_references(value, out)
    elif isinstance(node, list):
        for value in node:
            collect_references(value, out)
    elif isinstance(node, str) and UUID_RE.match(node):
        out.add(node)


def main() -> int:
    problems: list[str] = []

    if not PBXPROJ.exists():
        print(f"FAIL {PBXPROJ} does not exist", file=sys.stderr)
        return 1

    text = PBXPROJ.read_text(encoding="utf-8")
    parser = Parser(text)
    try:
        root = parser.parse_root()
    except ParseError as exc:
        print(f"FAIL project.pbxproj does not parse — {exc}", file=sys.stderr)
        return 1

    for key in parser.duplicate_keys:
        problems.append(f"key defined more than once: {key}")

    objects = root.get("objects")
    if not isinstance(objects, dict):
        print("FAIL project.pbxproj has no `objects` dictionary", file=sys.stderr)
        return 1

    # 2 — object IDs
    for oid in objects:
        if not UUID_RE.match(oid):
            problems.append(f"object ID is not 24 uppercase hex characters: {oid}")

    # 3 — references resolve
    referenced: set[str] = set()
    collect_references(objects, referenced)
    root_object = root.get("rootObject")
    if isinstance(root_object, str):
        referenced.add(root_object)
    else:
        problems.append("rootObject is missing")
    for ref in sorted(referenced - set(objects)):
        problems.append(f"reference to an undefined object: {ref}")

    unreferenced = set(objects) - referenced - {root_object}
    for oid in sorted(unreferenced):
        isa = objects[oid].get("isa", "?") if isinstance(objects[oid], dict) else "?"
        problems.append(f"object is defined but never referenced: {oid} ({isa})")

    # 4 — isa allow-list
    by_isa: dict[str, list[str]] = {}
    for oid, obj in objects.items():
        if not isinstance(obj, dict):
            problems.append(f"object {oid} is not a dictionary")
            continue
        isa = obj.get("isa")
        if isa is None:
            problems.append(f"object {oid} has no isa")
            continue
        if isa not in KNOWN_ISA:
            problems.append(f"object {oid} has an unknown isa: {isa}")
        by_isa.setdefault(isa, []).append(oid)

    # 5 — the root project and its targets
    projects = by_isa.get("PBXProject", [])
    if len(projects) != 1:
        problems.append(f"expected exactly one PBXProject, found {len(projects)}")
    else:
        project = objects[projects[0]]
        if projects[0] != root_object:
            problems.append("rootObject does not point at the PBXProject")
        target_ids = project.get("targets", [])
        if not isinstance(target_ids, list):
            problems.append("PBXProject.targets is not a list")
            target_ids = []
        names = set()
        for tid in target_ids:
            target = objects.get(tid)
            if isinstance(target, dict):
                names.add(target.get("name", "?"))
        missing = EXPECTED_TARGETS - names
        for name in sorted(missing):
            problems.append(f"target missing from PBXProject.targets: {name}")
        extra = names - EXPECTED_TARGETS
        for name in sorted(extra):
            problems.append(f"unexpected target in PBXProject.targets: {name}")

        for key in ("mainGroup", "buildConfigurationList"):
            if key not in project:
                problems.append(f"PBXProject has no {key}")

    # every native target must be listed by the project
    listed = set(objects[projects[0]].get("targets", [])) if len(projects) == 1 else set()
    for tid in by_isa.get("PBXNativeTarget", []):
        if tid not in listed:
            name = objects[tid].get("name", tid)
            problems.append(f"native target {name} is not listed in PBXProject.targets")

    # 6 — the embed phase
    embed_phases = [
        oid
        for oid in by_isa.get("PBXCopyFilesBuildPhase", [])
        if str(objects[oid].get("dstSubfolderSpec")) == "13"
    ]
    if not embed_phases:
        problems.append(
            "no PBXCopyFilesBuildPhase with dstSubfolderSpec = 13 — "
            "the share extension will not be embedded in the app"
        )
    else:
        for oid in embed_phases:
            phase = objects[oid]
            if not phase.get("files"):
                problems.append("the embed phase (dstSubfolderSpec = 13) copies no files")
            owners = [
                tid
                for tid in by_isa.get("PBXNativeTarget", [])
                if oid in objects[tid].get("buildPhases", [])
            ]
            if not owners:
                problems.append("the embed phase is not in any target's buildPhases")

    # 7 — build configurations and their xcconfigs
    for oid in by_isa.get("XCBuildConfiguration", []):
        config = objects[oid]
        name = config.get("name", oid)
        base = config.get("baseConfigurationReference")
        if base is None:
            problems.append(
                f"build configuration {name} ({oid}) has no baseConfigurationReference — "
                "settings belong in Config/*.xcconfig, not in the project file"
            )
            continue
        ref = objects.get(base)
        if not isinstance(ref, dict) or ref.get("isa") != "PBXFileReference":
            problems.append(
                f"build configuration {name}: baseConfigurationReference {base} "
                "is not a PBXFileReference"
            )
            continue
        xcconfig = REPO_ROOT / "Config" / ref.get("path", "")
        if not xcconfig.is_file():
            problems.append(
                f"build configuration {name}: xcconfig does not exist on disk: {xcconfig}"
            )

    # every configuration list must be referenced and non-empty
    for oid in by_isa.get("XCConfigurationList", []):
        if not objects[oid].get("buildConfigurations"):
            problems.append(f"XCConfigurationList {oid} has no build configurations")

    # 8 — the local package
    package_refs = by_isa.get("XCLocalSwiftPackageReference", [])
    if not package_refs:
        problems.append("no XCLocalSwiftPackageReference — the app links no package")
    for oid in package_refs:
        rel = objects[oid].get("relativePath", "")
        path = REPO_ROOT / rel
        if not (path / "Package.swift").is_file():
            problems.append(
                f"XCLocalSwiftPackageReference relativePath {rel!r} has no Package.swift"
            )

    # synchronized groups must point at directories that exist
    for oid in by_isa.get("PBXFileSystemSynchronizedRootGroup", []):
        group = objects[oid]
        rel = group.get("path", "")
        # the group is nested under a PBXGroup that carries the parent path
        candidates = [REPO_ROOT / rel] + [
            REPO_ROOT / objects[gid].get("path", "") / rel
            for gid in by_isa.get("PBXGroup", [])
            if oid in objects[gid].get("children", [])
        ]
        if not any(c.is_dir() for c in candidates):
            problems.append(f"synchronized group path does not exist on disk: {rel}")

    if problems:
        print(f"FAIL project.pbxproj — {len(problems)} problem(s):", file=sys.stderr)
        for problem in problems:
            print(f"  · {problem}", file=sys.stderr)
        return 1

    print(f"OK project.pbxproj — {len(objects)} objects, both targets, embed phase, all refs resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
