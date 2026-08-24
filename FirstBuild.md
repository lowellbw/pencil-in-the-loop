# First build

Everything in this repository was written on Linux, with no Swift compiler, no Xcode and
no Apple SDK anywhere near it. Not one line has been compiled. **The first build will not
be clean.** This document is about making the first hour productive rather than
mysterious.

The good news is that the failures should be shallow: type errors, availability errors and
version drift, not architecture. The project file, the plists and the entitlements have
been machine-checked (`make -C tooling check`), which rules out the class of failure that
gives you no line number at all.

---

## 0 · The fastest loop

Nothing in this repository has ever been compiled. The first build will produce errors —
the plan is to get the whole list at once rather than one at a time.

```sh
git clone https://github.com/lowellbw/lowellbw.git
cd lowellbw/pencil-in-the-loop
git checkout claude/new-project-repo-u1op58
./tooling/first-build.sh
```

It resolves packages, builds `PencilLoopKit` alone (which separates package problems from
app-target problems), then builds the app and extension, and writes `first-build-errors.txt`
— one line per diagnostic, repo-relative paths, duplicates collapsed, plus a count per
file so the worst offenders are obvious.

Paste that file back into Claude and the fixes come back as a diff. Repeat until it is
empty. Signing is off for these builds, so you need neither a Team ID nor a device yet —
do §2 when you first want to run it on the iPad.

## 1 · Step 0: push, then read CI

**Do this before opening Xcode.**

`.github/workflows/ios-build.yml` — **at the root of the repository, not in this
directory** — runs on every push that touches `pencil-in-the-loop/`. Its macOS job is the
first real compiler this code has ever met, and it is a far better first read than Xcode
is: it prints a complete, flat, greppable error list, in dependency order, with no editor
state, no derived data and no signing in the way.

The file sat at `pencil-in-the-loop/.github/workflows/` for the whole of Waves 0–3, which
is the tidier-looking place and meant it never ran once: GitHub reads workflows only from
the repository root, and one anywhere else is an inert text file. So this section
described something that was not happening, and every milestone was written and merged
without ever meeting a compiler. If the Actions tab is empty, that is the first thing to
check.

```sh
git push
gh run watch          # or just open the Actions tab
```

The job runs these, in this order, and stops at the first failure:

| Step | What a failure means |
|---|---|
| `swift package resolve` | The manifest is malformed, or swift-markdown will not resolve. Nothing else has been attempted. |
| `xcodebuild -scheme PencilLoopKit -destination generic/platform=iOS` | A real iOS compile error in the package. |
| `xcodebuild -project PencilLoop.xcodeproj -scheme PencilLoop` | The package is fine; the problem is in the app shell, the plists or the project file. |
| `xcodebuild test -scheme PencilLoopKit-Package -destination "platform=iOS Simulator,…"` | Everything compiles and a test fails — or the runner has no simulator by that name, which is the one line of that step worth checking first. |

There used to be a host `swift build` step in front of those, and it is gone: it compiled
the package for macOS, which was the fastest possible signal while the package was pure
Foundation and became meaningless the moment `AppUI` and `Annotate` imported UIKit and
PencilKit. Tests moved to the simulator for the same reason — `swift test` builds for the
host, and `AnnotateTests` and `AppUITests` link PencilKit and UIKit.

Only once CI is green — or once you have read its whole error list — is it worth opening
Xcode.

`PencilLoopKit/Package.resolved` is committed as of the first green run: swift-markdown
0.8.0 and swift-cmark 0.8.0. Before that it could not exist — it cannot be generated on a
machine with no network and no Swift — and the dependency graph was re-resolved, and could
silently move, on every machine.

---

## 2 · Two edits before you build

### a · Your team ID

`Config/Signing.xcconfig` has one blank line in it:

```
DEVELOPMENT_TEAM =
```

Put your ten-character Apple Developer Team ID there (Xcode ▸ Settings ▸ Accounts, or
developer.apple.com ▸ Membership). Blank is fine for the Simulator and for CI; it fails
the moment you build to a device, with `Signing for "PencilLoop" requires a development
team`.

### b · Your own bundle identifier

The repo ships with `com.example.pencilloop`, which nobody can sign. Replace it everywhere
in one go — this also fixes the App Group, which is `group.com.example.pencilloop` and has
to match between the app and the share extension or the extension writes into a container
the app cannot read.

From the repository root, on macOS (note the mandatory empty argument to `sed -i`):

```sh
grep -rl --exclude-dir=.git --exclude=FirstBuild.md 'com\.example\.pencilloop' . \
  | xargs sed -i '' 's/com\.example\.pencilloop/com\.yourname\.pencilloop/g'
```

Then check it landed:

```sh
grep -rn 'com\.example\.pencilloop' . --exclude-dir=.git --exclude=FirstBuild.md   # expect no output
make -C tooling check
```

One thing that command does *not* catch, because it is a prefix rather than the full id:
`tooling/xcodegen/project.yml` has `bundleIdPrefix: com.example`. Change it by hand if you
ever intend to use the XcodeGen fallback (§5).

### c · Four things between a green build and a running app

None of these are code, none produce a useful error the first time, and all four were hit
in order on the first real device run. They are listed in the order they bite.

**Developer Mode, on the iPad.** Settings ▸ Privacy & Security ▸ Developer Mode, then a
restart and a confirmation after it comes back. Until then the device appears in
`xcrun devicectl list devices` as `connected (no DDI)` and every build fails with
`Timed out waiting for all destinations` — which reads like a hang and is not one. The
menu item only appears after a Mac has *tried* to run a development build, so the first
failure is what creates the setting you need.

**The Program License Agreement.** If it has been updated since you last signed in,
everything that touches your account is refused and the real error is one line —
`Unable to process request - PLA Update available` — buried above nine consequences of it
about missing capabilities and unregistered devices. Accept it at
developer.apple.com/account and none of the other nine need any action.

**Registering the device.** `-allowProvisioningUpdates` creates app ids, adds the App
Groups capability and creates the group, but it will **not** register a new device, so the
error list shrinks and then stops shrinking on `Device "…" isn't registered in your
developer account`. The second flag is the whole fix, and it is easy to miss because the
first one is the famous one:

```sh
xcodebuild build \
  -project PencilLoop.xcodeproj -scheme PencilLoop \
  -destination "id=$UDID" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration
```

Registering a device spends one of the hundred slots your membership gets each year, and
the list can only be reset at renewal. Xcode's UI does the same thing when you press Run.

**A locked screen.** `devicectl … process launch` fails with `RequestDenied` / `Locked`
against a locked iPad. It is exactly what it says; it is only confusing because it arrives
after four failures that were not.

The whole sequence, once all four are done:

```sh
UDID=$(xcrun xctrace list devices | sed -nE 's/^(.*iPad.*) \(([0-9]{8}-[0-9A-F]{16})\)$/\2/p' | head -1)
xcodebuild build -project PencilLoop.xcodeproj -scheme PencilLoop \
  -destination "id=$UDID" -allowProvisioningUpdates -allowProvisioningDeviceRegistration
xcrun devicectl device install app --device "$UDID" \
  ~/Library/Developer/Xcode/DerivedData/PencilLoop-*/Build/Products/Debug-iphoneos/PencilLoop.app
xcrun devicectl device process launch --device "$UDID" com.yourname.pencilloop
```

---

## 3 · Expected errors, and the one-line remedy for each

Roughly in the order you are likely to hit them.

| Symptom | Why | Remedy |
|---|---|---|
| Manifest fails to parse: `extra argument 'defaultIsolation'` or `type 'SwiftSetting' has no member 'defaultIsolation'` | **Hit, and fixed.** `.defaultIsolation(MainActor.self)` is a PackageDescription 6.2 feature and the manifest declared tools version 6.0. | The manifest now says `6.2`, which is the version it always needed. Deleting the line and writing `@MainActor` on 64 view types is the remedy only on a pre-6.2 toolchain. |
| Manifest fails to parse: `type 'SupportedPlatform.IOSVersion' has no member 'v26'` | **Hit, and fixed by the same change.** `.v26` is also PackageDescription 6.2. | Covered by the tools version bump above. On an older toolchain, `.iOS("26.0")` is the string form every SwiftPM accepts. |
| `failed to resolve dependencies` / `no versions of swift-markdown match the requirement` | The floor is `from: "0.6.0"`. Upstream tags 0.1.0–0.8.0 were verified to exist, so this should resolve to 0.8.0. | Bump the one number in `PencilLoopKit/Package.swift`. `swift package resolve` prints the versions it did find. |
| swift-markdown resolves but then fails to compile | 0.8.0's own manifest is tools version 6.2, and it pulls swift-cmark and swift-docc-plugin. | Nothing to fix on an Xcode 26 toolchain. On an older one, pin down: `.package(url: …, .upToNextMinor(from: "0.6.0"))`. |
| A wall of `use of protocol 'Foo' as a type must be written 'any Foo'` | `SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY = YES` in `Config/Shared.xcconfig`. | The fixes are mechanical and worth doing. If it is burying you on day one, set it to `NO`, get to green, turn it back on, fix them properly. |
| `cannot find 'PKStrokeRecognizer' in scope`, or `is only available in iPadOS 27.0 or newer` | The recogniser ships in iPadOS 27; the deployment floor here is 26.0 so the project builds on a 26 SDK. | Leave the `PENCILLOOP_STROKE_RECOGNIZER` define commented out in `Annotate`'s `swiftSettings`. Ink still works — strokes are captured, persisted and exported as cropped images; only the handwriting-to-text search path is off. Turn it on when you move the floor to 27.0 in `Config/Shared.xcconfig`, in the same commit. |
| `SpeechAnalyzer` / `SpeechTranscriber` do not exist, or their initialisers do not match | The new Speech API moved between betas. | **Did not happen** — `AnalyserSpeechEngine.swift` compiled unchanged against the iOS 26.5 SDK. The seam is still there if a later SDK moves it: define `PENCILLOOP_LEGACY_SPEECH`, delete that one file. |
| `Source files for target Core should be located under Sources/Core` | `PencilLoopKit/Sources/Core/` is written by a different unit and may not have landed yet. | Confirm it is on the branch you are building. Every other module has a placeholder file for exactly this reason; `Core` deliberately does not, so its absence is loud. |
| `Multiple commands produce .../Info.plist` | An `Info.plist` inside a file-system-synchronized folder got compiled in as a resource. | The project already excludes both plists and both entitlements files via `PBXFileSystemSynchronizedBuildFileExceptionSet`. If it reappears, uncheck target membership for the file in Xcode's file inspector, which writes the same exception back. |
| `Signing for "PencilLoop" requires a development team` | §2a. | Fill in `Config/Signing.xcconfig`. |
| `Sandbox: rsync deny file-write-create` or similar during a build phase | `ENABLE_USER_SCRIPT_SANDBOXING = YES` in `Config/Shared.xcconfig`. | Nothing in this project runs a build script, so this should not fire. If a future one needs to write outside its declared outputs, declare the outputs — do not turn the sandbox off. |
| The app builds but the share extension never appears in the share sheet | Usually a bundle-id mismatch: the extension's id must be the app's id plus a suffix. | Check `PRODUCT_BUNDLE_IDENTIFIER` in `Config/App.xcconfig` and `Config/ShareExtension.xcconfig` are `x` and `x.share`. `make -C tooling check` verifies the App Groups match but cannot verify this against your provisioning profile. |

---

## 4 · Triage order

**Separate the package from the app first.** Almost all of the code is in the package, and
the package builds without a project file and without signing:

```sh
cd PencilLoopKit && xcodebuild build -scheme PencilLoopKit -destination 'generic/platform=iOS'
```

If that fails, the app target is irrelevant — ignore Xcode entirely until it passes.

**Not `swift build`.** It builds for the host, and the manifest declares `.iOS` as its
only platform — so every target compiles with no macOS floor at all and the first thing
you see is a page of `'AsyncStream' is only available in macOS 10.15 or newer`, which is
about nothing. That is the same reason CI dropped its host build step (§1); the advice to
use `swift build` outlived the code that it worked on. `-destination 'generic/platform=iOS'`
is the closest thing to a plain package compile that this package actually has.

Fix module by module, in dependency order. Each one only depends on the ones above it, so
an error in `Core` is causing errors in all six below it, and fixing `Core` first will
delete most of your error list:

```
Core → Storage → Sync → Ingest → Annotate → Export → AppUI
```

There is no per-target flag to reach for here, and none is needed: the build goes in that
order and stops at the first module that fails, so the errors you are shown are already
the topmost ones. Fix those, build again, and the next module's errors appear.

Two structural invariants worth not breaking while you are in there:

- **`Sync` depends on `Core` only.** It reaches the library through the `DocumentStoring`
  protocol. This is what keeps SwiftData out of the `PencilLoopKitCore` product, which is
  all the share extension links. Adding `"Storage"` to `Sync`'s dependencies compiles fine
  and quietly makes the extension much more likely to be killed for memory.
- **`Core` and `Storage` import neither SwiftUI nor UIKit.** Enforced by convention, not by
  the compiler — the host `swift build` step in CI is the closest thing to a check.

Only when the package is green does the app target matter, and by then it is a shell:
`PencilLoopApp.swift` and `ShareViewController.swift` are about forty lines between them.

---

## 5 · If the project will not open

If Xcode says *"The project 'PencilLoop' is damaged and cannot be opened"* — the usual
cause is a bad merge in `project.pbxproj` — first run the checker, which gives a real
message and a line number where Xcode gives neither:

```sh
python3 tooling/lint/check_pbxproj.py
```

If it is genuinely unrecoverable, regenerate an equivalent project from the XcodeGen spec:

```sh
brew install xcodegen
mv PencilLoop.xcodeproj PencilLoop.xcodeproj.bak
xcodegen generate --spec tooling/xcodegen/project.yml --project .
```

The result is semantically the same — same two targets, same xcconfigs, same package
products, same embed phase — but not byte-identical: XcodeGen lists source files
individually where the committed project uses file-system-synchronized groups, so adding
a file later means regenerating rather than just saving it into the folder.

Prefer `git checkout -- PencilLoop.xcodeproj/project.pbxproj` over regenerating. The
fallback is for when there is nothing good to check out.

---

## 6 · Device test scripts

Most of what matters here cannot be tested in the Simulator or by a unit test — Pencil
input, hover, squeeze, `PKStrokeRecognizer`, live transcription, 60fps while inking a page
carrying three hundred strokes. So it gets written down instead. One script per milestone
demo, in the order of `docs/07-build-plan.md`; each is a sitting-down-with-the-iPad list,
not a regression suite.

You need: a real iPad, an Apple Pencil (Pro for the squeeze steps), and a Mac sharing a
folder with it — iCloud Drive is the easy one. Do the whole of M0 before touching M1.

### M0 · Offline reading

The milestone that has to be worth using on its own.

1. **First run is one screen.** Fresh install → the folder picker and nothing else: no
   carousel, no account, no logo. Pick a folder. On the Mac, `inbox/` and `outbox/` now
   exist inside it.
2. **A document arrives with the app open and untouched.** Drop
   `2026-08-19-test/document.pdf` on the Mac. It appears in Unread within about fifteen
   seconds. Do not tap anything to make it happen.
3. **Pull-to-refresh says what it found.** Drop another and pull down at once: the status
   line reads "1 new document". Pull again with nothing waiting: "No new documents". A
   gesture that reports nothing teaches nothing.
4. **It opens with the network off.** Aeroplane mode, then sign the file provider out for
   good measure. Every document already in the library opens, scrolls and zooms exactly as
   before. Nothing shows a spinner. New documents stop arriving and the status line says
   why — that is the whole cost of losing the folder.
5. **Cold launch to a page.** Force-quit, relaunch, tap a document: readable in about a
   second, at the page you left it on. Scroll a few pages, wait two seconds (the position
   write is debounced 1.5s), force-quit, relaunch: same page.
6. **Chrome behaves like Books.** Scroll → toolbar goes. Tap → it comes back. No
   persistent sidebar over the page, no floating palette.
7. **Tints do not invert.** Settings → Page Tint through White, Cream, Sepia, Grey with a
   document containing a figure and a code block on screen. Text stays black, the page
   changes colour, the figure keeps its own colours. Anything that looks like a negative
   is the bug this rule exists to prevent (`docs/01` § 9).
8. **A bad folder shows a row, not a silence.** Put a directory in `inbox/` containing a
   truncated PDF. A row appears with the reason under it, dimmed and not tappable. It must
   never simply not be there.
9. **Accessibility.** VoiceOver on a library row reads title, origin, when, pages, comment
   count and — when it is not simply local — what the trailing dot means. Set Dynamic Type
   to the largest accessibility size: library rows, Settings and the review sheet reflow;
   the PDF does not, which is the accepted trade.
10. **Reinstall.** Delete the app, reinstall, choose the same folder. Documents re-ingest
    from `inbox/` and open. (What this is really checking is that nothing recorded an
    absolute container path, which changes on every install.)

### M2 · Ink torture

`docs/07` says test hard here, and this is the list.

1. **Three hundred strokes on one page.** Write until the page is full, then keep writing.
   Watch for a dropped frame while drawing; there must not be one.
2. **Draw while scrolling.** Scroll hard with a finger while the Pencil is down. Finger
   scrolls, Pencil draws, neither cancels the other, and no stroke lands on the wrong page.
3. **Recycle inside the autosave window.** Draw a stroke, immediately flick two pages away
   and back — under half a second, inside the 500ms debounce. The stroke is still there.
   This is the recycling bug the whole canvas pool is arranged around.
4. **Background mid-stroke.** Draw, then swipe up to the home screen within a second.
   Relaunch: the stroke is there. (`InkLifecycleObserver` flushes on the way to
   suspension.)
5. **Force-quit mid-stroke.** Same, but force-quit within 500ms. Losing that one last
   stroke is the known window; losing the page's earlier ink, or corrupting it, is not.
6. **Zoom.** Pinch to 3× and back. Ink stays registered with the text it was drawn beside,
   at every zoom level and after. It should sharpen a beat after the pinch ends; if it
   stays soft, `pageScaleDidSettle` is not being called.
7. **Rotate, and split view.** Rotate mid-stroke. Then put the app in split view at each
   width. Ink stays where the words are.
8. **Two-finger tap undoes.** One stroke at a time, in order. It must undo the strokes on
   the page you are looking at.
9. **Finger never draws.** Rest a palm, drag a finger across the page. Nothing is drawn —
   `drawingPolicy = .pencilOnly`, and there is no tool switch anywhere in the app.
10. **Tool picker.** Toolbar button summons it in its floating form; tapping away dismisses
    it; it is never pinned and never there before you ask. Choose a different ink and width,
    quit, relaunch: still selected (the write is debounced half a second — do not quit
    instantly).
11. **Dark mode.** Turn the system appearance to dark. Graphite ink stays graphite over the
    page rather than being lightened to white-on-white.
12. **Recognition, if this build has it.** With `PENCILLOOP_STROKE_RECOGNIZER` on and a
    27 device: write a distinctive word in the margin, then search the library for it. On
    every other build, recognition is simply off and everything above is unchanged.

### M3 · Gesture and voice

None of this can be tested anywhere but on the device.

1. **Press and hold to comment.** Rest the Pencil on a sentence. At about 0.4s the popover
   opens, anchored at the tip, with that sentence quoted at the top.
2. **The dot is taken back.** Watch the contact point as the popover opens: the dot the
   press had started is gone. Close the popover, quit, relaunch — no stray dot was saved.
   Do it twenty times; a stray dot every twentieth press is still a bug.
3. **A short press does nothing.** Tap and lift under 0.3s. No popover, no comment, and —
   if it left a mark — an ordinary stroke you can undo.
4. **First words land fast.** Start talking as the popover opens. The first words should be
   on screen inside about 400ms of the press, not a second later.
5. **Jargon.** Say a type name that appears in the document ("the ink persistence
   coordinator"). It should be spelled the way the document spells it. This is the term
   list doing its job at save time.
6. **Scribble instead.** Tap "✎ scribble instead", handwrite a comment into the field, save.
   It is stored as handwriting and appears in the review sheet like any other.
7. **Squeeze** (Pencil Pro). Hover over a passage and squeeze: the popover opens there.
   Squeeze with the Pencil in your hand, not over the screen: it opens at the centre of the
   page rather than refusing.
8. **Dictation unavailable is not a dead end.** Settings → deny the microphone. Long-press:
   the popover still opens, in scribble mode, and Settings carries one row saying why. On a
   fresh device, watch the language assets download in that same row.
9. **Markers.** Comment on three passages. Dots appear in the outer margin at the right
   heights. Two comments a line apart become one dot with a 2 on it. Tap it: both are
   listed. Delete one: the dot updates and "Undo" is right there. Undo: the marker returns
   in exactly the same place — a restored comment keeps its id, so a marker that jumps means
   the undo went through the wrong path.
10. **Markers keep up.** Flick through ten pages. Markers track the pages while they move
    and settle with them; nothing should be ticking while the document is still.
11. **VoiceOver.** With VoiceOver on, the popover's record control works by tap rather than
    hold, and the same under-0.3s rule discards.

### M4 · Bundle round trip

Do this one with the Mac folder open beside you.

1. **The sheet says what it will send.** Comments in document order, ink page count,
   "12 min of review" after twelve minutes of actually reading it.
2. **The destination row is honest.** A document sent from Cowork with a session id shows
   SAME THREAD; one shared from Safari shows NEW THREAD and leads with copy / share / save.
   That row must be visible before the button is pressed.
3. **The write is atomic.** Press Send while watching `outbox/` on the Mac. The
   `<slug>.review` directory appears complete — never half-written, never with files
   arriving one at a time.
4. **The bundle is the contract.** Open it: `review.md`, `review.json`, `manifest.json`,
   `ink/page-01.png`… Check `review.json`'s `documentId` is the id from the sending tool's
   `meta.json`, not a UUID the app invented. Check an ink PNG has the page content
   underneath the strokes — an arrow with nothing to point at is useless.
5. **Offline send queues.** Sign the file provider out. Send. The screen says "Will send
   when online" rather than reporting a failure. Sign back in, foreground the app: the
   bundle appears in `outbox/` and the Sent screen's timeline flips to written.
6. **A reply, while you watch.** Write `reply.md` into the review directory on the Mac. The
   Sent screen shows its text.
7. **A reply, after you have gone.** Send a review, close the sheet, lock the iPad. Write
   the reply on the Mac. Come back, open the document, tap Review: the reply is at the top
   of the sheet with "Open reply as document". This is the case that used to be impossible
   and it is the one worth checking twice.
8. **Open as document.** Tap it: a new "Reply — …" document appears in the library and is
   selected. Comment on it and send: the review goes back to the same conversation, because
   the origin was inherited.
9. **Editing in the sheet.** Tap a comment to edit it, swipe another to delete, then Undo.
   Send, and check `review.md` carries exactly what the sheet showed.
10. **Budget.** A 50-page document with 20 comments and a few inked pages builds in under
    two seconds from pressing Send to the Sent screen.

### M5 · Share

1. **A PDF from Safari.** Share → PencilLoop → the confirmation. Switch to the app: it is
   in the library. Three taps, and the extension itself never touched the network.
2. **A link.** Share a web page. The document opens with a placeholder that says plainly
   that the page has not been fetched, and its `meta.json` carries `sourceURL`.
3. **Before there is a folder.** Share something on a device where the app has never been
   opened. Nothing is lost: open the app, choose a folder, and the staged item is imported
   on that foreground.
4. **A big file.** Share a 100MB PDF. The extension must not be killed for memory; the copy
   is streamed by the filesystem.
5. **A killed extension leaves nothing.** Share a large file and swipe the sheet away
   mid-copy. On the Mac, the App Group's `staging/` has a dot-prefixed `.tmp` directory that
   the app ignores; it is swept an hour later. Nothing half-written ever reaches `inbox/`.
6. **Mismatched App Group.** If the extension reports it cannot reach the shared container,
   the two `.entitlements` files disagree — `make -C tooling check` verifies they match, so
   this should only ever happen after a hand edit.

---

## 7 · TestFlight

Getting it onto the iPad properly, rather than by cable. Internal testing needs no review
and no waiting: up to 100 testers on your own team, and a build is usually installable
within twenty minutes of upload — most of which is Apple processing it.

Nothing here is missing. The icon exists, export compliance is answered, and the version
keys are wired — the outstanding items are the ones only you can supply: a Team ID, a
bundle id, and a build that compiles.

### What has to be true before an archive

| Thing | Where | State |
|---|---|---|
| Team ID | `Config/Signing.xcconfig` | **Blank. Fill it in** (§2a). |
| Bundle id | `Config/App.xcconfig`, `Config/ShareExtension.xcconfig` | `com.example.pencilloop` and `.share`. **Replace both** (§2b), and register the app id in App Store Connect. |
| App Group | both `.entitlements` files | `group.com.example.pencilloop`. Renamed by the same command; it must exist in your developer account and be enabled for **both** app ids. |
| Version | `Config/Shared.xcconfig` | `MARKETING_VERSION = 0.1.0`, `CURRENT_PROJECT_VERSION = 1`. Both plists read them, so bumping the build number is one line, once. |
| Export compliance | `Apps/PencilLoop/Info.plist` | `ITSAppUsesNonExemptEncryption` is already `false`. Correct, and see below. |
| App icon | `Apps/PencilLoop/Assets.xcassets/AppIcon.appiconset` | `AppIcon-1024.png`, present and wired. Regenerate with `python3 tooling/icon/make_icon.py`. |

### The icon

`AppIcon.appiconset` holds a single universal 1024×1024 PNG — opaque, no alpha, square
corners, because iOS masks the corners itself and an icon with them drawn in gets them
twice. Xcode 26 derives every other size from that one asset.

It is a paragraph of faint text with a graphite pencil loop circling one passage: what the
app does, and the loop it is named after. No lettering and no logo, which follows
`docs/01-design-principles.md` § 6 rather than ignoring it because an icon is involved.

`tooling/icon/make_icon.py` draws it — at 4× and downsampled, which is where the pencil
edge gets its softness. To change it, edit the script and re-run:

```sh
python3 tooling/icon/make_icon.py   # writes AppIcon-1024.png beside the script
```

then copy the result over `Apps/PencilLoop/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`.
Keeping the generator in the repository means the icon is reproducible rather than a binary
nobody can edit.

The share extension needs no icon of its own — it inherits the app's in the share sheet.

### Archive and upload

```sh
# From the repository root, with a device or "Any iOS Device" selected in Xcode:
#   Product ▸ Archive, then Distribute App ▸ App Store Connect ▸ Upload.
#
# Or from the command line:
xcodebuild archive \
  -project PencilLoop.xcodeproj \
  -scheme PencilLoop \
  -destination 'generic/platform=iOS' \
  -archivePath build/PencilLoop.xcarchive

xcodebuild -exportArchive \
  -archivePath build/PencilLoop.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export
```

`ExportOptions.plist` is not in the repo — it carries your team id and is a two-key file:
`method` = `app-store-connect`, `teamID` = yours. Xcode writes one for you the first time
you export through the UI, and that copy is the easiest one to keep.

**The share extension ships inside the same archive.** It is not a separate upload and not
a separate TestFlight build: `PencilLoop.xcodeproj` embeds `ReviewShareExtension.appex` in
the app bundle through the Embed App Extensions phase (`make -C tooling check` verifies
that phase exists). One archive, one upload, one build number, both bundle ids signed
together. If the extension does not appear in the share sheet on a TestFlight install, it
is a provisioning mismatch between the two ids — not a missing upload.

### Export compliance

`ITSAppUsesNonExemptEncryption = false` in `Apps/PencilLoop/Info.plist`, which is the
honest answer and means App Store Connect never asks the question again per build.

This app does no cryptography of its own. It does now make HTTPS calls of its own, to the
relay, when a user opts into that transport — but it makes them through `URLSession`, so
the TLS is the operating system's, exactly as it is when the Speech framework downloads a
language model on first run. Both are the "limited to standard encryption within the OS"
exemption the question is about, and neither changes the answer. Reading, annotating, ink,
transcription and every review bundle are still local file work. `CryptoKit` appears in
one place, `ManifestWriter`, hashing bundle files with SHA-256 for `manifest.json`; a hash
is not encryption, and checking a downloaded file against one is not either.

That reasoning is worth reading carefully rather than trusting, because it used to say the
only encryption anywhere near the app was the Speech framework's download, and the relay
made that sentence false while leaving the conclusion standing. The conclusion survives
only because the relay borrows the system's TLS instead of bringing its own. If anything
ever encrypts data itself — a bundle encrypted before upload, say — flip that key to
`true` and expect to answer the compliance questions per build, or file a year-long
exemption.

### Internal testing

1. App Store Connect → your app → **TestFlight** → wait for the build to finish
   processing (5–20 minutes; you get an email).
2. **Internal Testing** → add a group → add testers by Apple ID. Up to 100, each on up to
   30 devices. No review, no wait — the build is available as soon as it has processed.
3. Testers install the TestFlight app and see it there. Builds expire after 90 days.
4. External testing (up to 10,000 people via a public link) *does* need Beta App Review,
   which is a day or two, and a filled-in "what to test" and privacy answer. You do not
   need it to run releases to yourself.

Two things worth knowing for this app specifically:

- **The sync folder is per-device.** A TestFlight install is a fresh container: first run
  asks for the folder again, and the library starts empty until `inbox/` is re-scanned.
  That is the reinstall test in §6 M0, done for real.
- **Microphone and speech permissions reset** with every fresh install, so the M3
  permission steps are worth re-running on the first TestFlight build rather than assuming
  they still pass.

### Still to do before a real release

Plainly, so nothing here is a surprise:

- `PencilLoopKit/Package.resolved` is not committed, so the dependency version is
  whatever resolves on the machine that archives. Commit it (§1) before you cut a build
  you might have to reproduce.
- `MARKETING_VERSION` is `0.1.0` and `CURRENT_PROJECT_VERSION` is `1`. App Store Connect
  rejects a second upload with a build number it has already seen; bump
  `CURRENT_PROJECT_VERSION` every time.
- There is no privacy policy URL and no App Privacy answers filled in. Internal TestFlight
  does not ask; anything beyond it does, and the answer is no longer a single sentence.
  The app still collects nothing about the user — no analytics, no telemetry, no
  identifiers, and nothing at all leaves the device on the folder transport. But a user
  who turns the relay on is uploading their documents and reviews to a server run for this
  app, and under Apple's definitions that is user content being collected. Expect to
  declare it, to say that it is stored only to carry files between that person's own
  devices, that it is not linked to an identity beyond a shared token, and that it is
  never used for tracking or advertising. A privacy policy URL becomes genuinely required
  rather than a formality.
