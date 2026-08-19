#!/usr/bin/env python3
"""Check the Info.plists and entitlements against what the app actually needs.

These four files are contracts with the operating system, and every one of them
fails at runtime rather than at build time: a missing usage string is a crash the
first time the microphone is touched, a wrong activation rule is a share
extension that never appears in the share sheet, and mismatched App Groups are a
share extension that writes into a container the app cannot read.

None of that shows up in a compile. So it is checked here instead.

Python 3, standard library only (plistlib is stdlib). Exits 1 listing every
problem found.
"""

from __future__ import annotations

import plistlib
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

APP_PLIST = REPO_ROOT / "Apps/PencilLoop/Info.plist"
EXT_PLIST = REPO_ROOT / "Apps/ReviewShareExtension/Info.plist"
APP_ENTITLEMENTS = REPO_ROOT / "Apps/PencilLoop/PencilLoop.entitlements"
EXT_ENTITLEMENTS = REPO_ROOT / "Apps/ReviewShareExtension/ReviewShareExtension.entitlements"

APP_GROUP = "group.com.example.pencilloop"

ORIENTATIONS = {
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationPortraitUpsideDown",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
}


def load(path: Path, problems: list[str]):
    if not path.is_file():
        problems.append(f"{path.relative_to(REPO_ROOT)}: file does not exist")
        return None
    try:
        with path.open("rb") as handle:
            return plistlib.load(handle)
    except Exception as exc:  # noqa: BLE001 — any parse failure is the same failure
        problems.append(f"{path.relative_to(REPO_ROOT)}: does not parse — {exc}")
        return None


def require(plist, path: Path, key: str, problems: list[str], expected=None):
    if key not in plist:
        problems.append(f"{path.relative_to(REPO_ROOT)}: missing key {key}")
        return None
    value = plist[key]
    if expected is not None and value != expected:
        problems.append(
            f"{path.relative_to(REPO_ROOT)}: {key} is {value!r}, expected {expected!r}"
        )
    return value


def check_app_plist(problems: list[str]) -> None:
    plist = load(APP_PLIST, problems)
    if plist is None:
        return

    for key in (
        "CFBundleIdentifier",
        "CFBundleExecutable",
        "CFBundleName",
        "CFBundlePackageType",
        "CFBundleShortVersionString",
        "CFBundleVersion",
        "UIApplicationSceneManifest",
    ):
        require(plist, APP_PLIST, key, problems)

    # Usage strings appear verbatim in a system alert. An empty or placeholder
    # one is an App Store rejection and, before that, a bad first impression.
    for key in ("NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"):
        text = require(plist, APP_PLIST, key, problems)
        if isinstance(text, str):
            if len(text.strip()) < 20:
                problems.append(f"{APP_PLIST.name}: {key} is too short to be a real sentence")
            if "TODO" in text or "XXX" in text:
                problems.append(f"{APP_PLIST.name}: {key} still contains a placeholder")

    require(plist, APP_PLIST, "UIFileSharingEnabled", problems, expected=True)
    require(plist, APP_PLIST, "LSSupportsOpeningDocumentsInPlace", problems, expected=False)

    if "UILaunchScreen" not in plist:
        problems.append(f"{APP_PLIST.name}: missing UILaunchScreen (an empty dict is correct)")
    elif not isinstance(plist["UILaunchScreen"], dict):
        problems.append(f"{APP_PLIST.name}: UILaunchScreen must be a dictionary")

    manifest = plist.get("UIApplicationSceneManifest")
    if isinstance(manifest, dict):
        if "UISceneConfigurations" not in manifest:
            problems.append(f"{APP_PLIST.name}: UIApplicationSceneManifest has no UISceneConfigurations")

    orientations = plist.get("UISupportedInterfaceOrientations~ipad")
    if not isinstance(orientations, list):
        problems.append(f"{APP_PLIST.name}: missing UISupportedInterfaceOrientations~ipad")
    elif set(orientations) != ORIENTATIONS:
        problems.append(
            f"{APP_PLIST.name}: UISupportedInterfaceOrientations~ipad should list all four "
            f"orientations, found {sorted(orientations)}"
        )

    # Reading and annotating never happen in the background, and asking for a
    # background mode the app does not use is a review rejection.
    if "UIBackgroundModes" in plist:
        problems.append(f"{APP_PLIST.name}: UIBackgroundModes must not be declared")


def check_extension_plist(problems: list[str]) -> None:
    plist = load(EXT_PLIST, problems)
    if plist is None:
        return

    for key in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundlePackageType"):
        require(plist, EXT_PLIST, key, problems)

    extension = plist.get("NSExtension")
    if not isinstance(extension, dict):
        problems.append(f"{EXT_PLIST.name}: missing NSExtension dictionary")
        return

    if extension.get("NSExtensionPointIdentifier") != "com.apple.share-services":
        problems.append(
            f"{EXT_PLIST.name}: NSExtensionPointIdentifier must be com.apple.share-services"
        )

    principal = extension.get("NSExtensionPrincipalClass")
    if principal != "$(PRODUCT_MODULE_NAME).ShareViewController":
        problems.append(
            f"{EXT_PLIST.name}: NSExtensionPrincipalClass is {principal!r}, expected "
            "$(PRODUCT_MODULE_NAME).ShareViewController"
        )

    attributes = extension.get("NSExtensionAttributes")
    if not isinstance(attributes, dict):
        problems.append(f"{EXT_PLIST.name}: missing NSExtensionAttributes")
        return

    rule = attributes.get("NSExtensionActivationRule")
    if not isinstance(rule, dict):
        problems.append(
            f"{EXT_PLIST.name}: NSExtensionActivationRule must be a dictionary, not a predicate "
            "string — a predicate is not checked until the share sheet is opened"
        )
        return

    for key in (
        "NSExtensionActivationSupportsFileWithMaxCount",
        "NSExtensionActivationSupportsWebURLWithMaxCount",
        "NSExtensionActivationSupportsWebPageWithMaxCount",
    ):
        if key not in rule:
            problems.append(f"{EXT_PLIST.name}: NSExtensionActivationRule has no {key}")
        elif rule[key] != 1:
            problems.append(
                f"{EXT_PLIST.name}: {key} is {rule[key]}, expected 1 — a review is of one document"
            )


def check_entitlements(problems: list[str]) -> None:
    groups_seen = {}
    for path in (APP_ENTITLEMENTS, EXT_ENTITLEMENTS):
        plist = load(path, problems)
        if plist is None:
            continue
        groups = plist.get("com.apple.security.application-groups")
        if groups != [APP_GROUP]:
            problems.append(
                f"{path.name}: com.apple.security.application-groups is {groups!r}, "
                f"expected ['{APP_GROUP}']"
            )
        extra = set(plist) - {"com.apple.security.application-groups"}
        if extra:
            problems.append(
                f"{path.name}: unexpected entitlement(s) {sorted(extra)} — every entitlement "
                "is a provisioning-profile requirement, so add one only when it is used"
            )
        groups_seen[path.name] = groups

    if len(groups_seen) == 2 and len(set(map(repr, groups_seen.values()))) != 1:
        problems.append(
            "the app and the share extension declare different App Groups — they must share "
            "a container or the extension writes where the app cannot read"
        )


def main() -> int:
    problems: list[str] = []
    check_app_plist(problems)
    check_extension_plist(problems)
    check_entitlements(problems)

    if problems:
        print(f"FAIL plists — {len(problems)} problem(s):", file=sys.stderr)
        for problem in problems:
            print(f"  · {problem}", file=sys.stderr)
        return 1

    print("OK plists — app, extension, and both entitlements files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
