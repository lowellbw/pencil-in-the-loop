#!/usr/bin/env python3
"""check_imports.py — module import policy.

There is no compiler here, so the module graph is enforced by reading source.
The rules come from CLAUDE.md ("Core/ and Storage/ must not import SwiftUI or
UIKit"), from Package.swift's dependency graph, and from STYLE.md § 7.

The one that matters most structurally: Sync may not import Storage. The share
extension links Core+Sync only, and an extension that drags SwiftData in gets
killed under its memory cap. That is invisible until it happens on a device.

Exits non-zero listing every violation, never just the first.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCES = os.path.join(ROOT, "PencilLoopKit", "Sources")
TESTS = os.path.join(ROOT, "PencilLoopKit", "Tests")

# Frameworks any module may use for logging and basic types.
UNIVERSAL = {"Foundation", "os", "os.log", "Observation", "Combine"}

POLICY = {
    "Core": UNIVERSAL | set(),
    # `Security` is the Keychain, and it is here rather than in Sync on purpose:
    # the relay's bearer token is written and read by Storage/Settings, and Sync
    # is handed the token rather than the means of fetching it. Adding "Storage"
    # to Sync below to reach it would pull SwiftData into PencilLoopKitCore and
    # get the share extension killed under its memory cap.
    "Storage": UNIVERSAL | {"SwiftData", "Core", "Security"},
    # Deliberately no Storage: see the module comment in Package.swift.
    "Sync": UNIVERSAL | {"Core", "UniformTypeIdentifiers", "CryptoKit"},
    "Ingest": UNIVERSAL | {
        "Core", "Storage", "PDFKit", "UIKit", "CoreGraphics", "CoreText",
        "ImageIO", "UniformTypeIdentifiers", "Markdown",
    },
    "Annotate": UNIVERSAL | {
        "Core", "Storage", "PencilKit", "Speech", "UIKit", "AVFoundation",
        "CoreGraphics", "NaturalLanguage",
    },
    "Export": UNIVERSAL | {
        "Core", "Storage", "Ingest", "PDFKit", "PencilKit", "UIKit",
        "CoreGraphics", "ImageIO", "CryptoKit", "UniformTypeIdentifiers",
    },
    # AppUI is the only module allowed anything; it is where the frameworks meet.
    "AppUI": None,
}

# Modules that must never see a view framework, per CLAUDE.md.
NO_UI_MODULES = {"Core", "Storage"}
UI_FRAMEWORKS = {"UIKit", "SwiftUI", "AppKit"}

# `import Markdown` is confined to one adapter so no swift-markdown type can
# escape into another module's signatures (STYLE.md § 7).
MARKDOWN_ONLY_FILE = os.path.join(
    "Ingest", "Adapters", "SwiftMarkdownAdapter.swift"
)

# `Security` is here for one reason: `SyncTokenKeychain`'s seam answers in
# `OSStatus`, and a test that asserts on a failed write has to be able to name
# `errSecSuccess` and `errSecDuplicateItem` rather than write -25299 down.
TEST_ALLOWED = UNIVERSAL | {
    "XCTest", "Testing", "Core", "Storage", "Sync", "Ingest", "Annotate",
    "Export", "AppUI", "SwiftData", "PDFKit", "PencilKit", "UIKit", "SwiftUI",
    "CoreGraphics", "Security",
}

IMPORT_RE = re.compile(
    r"^\s*(?:@testable\s+|@preconcurrency\s+|@_implementationOnly\s+)*import\s+"
    r"(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?"
    r"([A-Za-z_][A-Za-z0-9_.]*)"
)


def swift_files(directory):
    for base, _dirs, names in os.walk(directory):
        for name in sorted(names):
            if name.endswith(".swift"):
                yield os.path.join(base, name)


def module_of(path):
    relative = os.path.relpath(path, SOURCES)
    return relative.split(os.sep)[0]


def imports_in(path):
    found = []
    with open(path, "r", encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            if line.lstrip().startswith("//"):
                continue
            match = IMPORT_RE.match(line)
            if match:
                # `import os.log` counts as `os`.
                found.append((number, match.group(1).split(".")[0], match.group(1)))
    return found


def main():
    problems = []

    if not os.path.isdir(SOURCES):
        print("check_imports: no PencilLoopKit/Sources yet — nothing to check.")
        return 0

    for path in swift_files(SOURCES):
        module = module_of(path)
        relative = os.path.relpath(path, ROOT)
        allowed = POLICY.get(module, None)
        for number, root_name, full_name in imports_in(path):
            if module in NO_UI_MODULES and root_name in UI_FRAMEWORKS:
                problems.append(
                    f"{relative}:{number}: `import {full_name}` in {module}/ — "
                    f"Core and Storage must never import a view framework "
                    f"(CLAUDE.md, Stack)."
                )
                continue
            if root_name == "Markdown":
                expected = MARKDOWN_ONLY_FILE
                if not os.path.relpath(path, SOURCES).endswith(expected):
                    problems.append(
                        f"{relative}:{number}: `import Markdown` is confined to "
                        f"Sources/{expected}. Convert to MarkdownDocument at that "
                        f"boundary instead (STYLE.md § 7)."
                    )
                continue
            if module == "Sync" and root_name == "Storage":
                problems.append(
                    f"{relative}:{number}: Sync must not import Storage. Sync "
                    f"reaches the library through DocumentStoring in Core so the "
                    f"share extension can link it without SwiftData "
                    f"(Package.swift § Sync)."
                )
                continue
            if allowed is None:
                continue
            if root_name not in allowed:
                problems.append(
                    f"{relative}:{number}: `import {full_name}` is not permitted in "
                    f"{module}. Allowed: {', '.join(sorted(allowed))}. Adding one is "
                    f"a change request to the lead (STYLE.md § 7)."
                )

    if os.path.isdir(TESTS):
        for path in swift_files(TESTS):
            relative = os.path.relpath(path, ROOT)
            for number, root_name, full_name in imports_in(path):
                if root_name not in TEST_ALLOWED:
                    problems.append(
                        f"{relative}:{number}: `import {full_name}` is not permitted "
                        f"in a test target."
                    )

    for problem in problems:
        print(f"check_imports: {problem}")
    if problems:
        print(f"check_imports: {len(problems)} problem(s).")
        return 1
    print("check_imports: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
