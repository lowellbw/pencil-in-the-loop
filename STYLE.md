# STYLE.md

The social contract that stands in for a compiler.

Six modules are being written in parallel by six agents, on a machine with no Swift
toolchain. Nothing here can be compiled or run until it reaches a Mac. Every convention
below exists because breaking it produces a compile error someone else has to find, in
code they did not write, hours later.

`tooling/lint/` enforces the mechanical half. Run `make -C tooling check` before you
consider anything finished. The rest is on you.

---

## 1 · The one rule that matters most

**Cross-module calls may use only names declared in `PencilLoopKit/Sources/Core/Contracts/`.**

If your module needs to call another module, the call goes through a protocol declared in
`Core/Contracts/Protocols.swift`, taking and returning types declared in
`Core/Contracts/`. There is no other seam.

**Needing a new contract name is a change request to the lead. It is never a local edit.**
Not a "small addition", not a "just one field", not a `// TODO: move to Core later`. Six
agents editing one contract file concurrently is how the contract stops being one. Say
what you need and why, and carry on with what exists until it lands.

Two corollaries:

- If you find a signature in `Core/Contracts/` that is wrong or insufficient, **report it,
  do not fix it**. A signature that is wrong in one place is survivable; a signature that
  is wrong in two different ways in two different files is not.
- `AnchorResolver.swift` is signatures with `fatalError("WAVE 1 (U6)")` bodies. Unit U6
  fills them in. Everyone else calls it as if it worked, because by the time the code runs
  it will.

---

## 2 · British spellings — the frozen glossary

Spelling drift is the cheapest possible source of cross-agent mismatch: two agents write
the same concept, one calls it `normalizedRect`, and neither file compiles against the
other. So the spelling is frozen, and `tooling/lint/check_style.py` enforces it.

**Our own symbols use these spellings. Always.**

| Use | Never |
|---|---|
| `normalise`, `normalised`, `normalisation`, `NormalisedRect`, `normalisedRect` | `normalize`, `normalized`, `NormalizedRect` |
| `recognise`, `recognised`, `RecognisedInk`, `recognisedInk`, `recognisedText` | `recognize`, `recognized`, `RecognizedInk` |
| `recogniser`, `HandwritingRecognising` | `recognizer` (except Apple's own types) |
| `finalise`, `finalised`, `finalisedText` | `finalize`, `finalized` |
| `organise`, `organised` | `organize`, `organized` |
| `synchronise`, `synchronised` | `synchronize`, `synchronized` |
| `serialise`, `serialised` | `serialize`, `serialized` |
| `analyse`, `analysed` | `analyze`, `analyzed` |
| `behaviour` | `behavior` |
| `materialise`, `materialisation` | `materialize` |
| `cancelled`, `modelling`, `labelled` | `canceled`, `modeling`, `labeled` |

**Apple's symbols keep Apple's spelling**, obviously and without exception:
`PKStrokeRecognizer`, `UIGestureRecognizer`, `UIHoverGestureRecognizer`,
`SFSpeechRecognizer`, `JSONSerialization`, `Color`, `foregroundColor`, `.colorScheme`,
`NSAttributedString.Key.foregroundColor`. The linter's allow-list
(`tooling/lint/sdk_allowlist.txt`) knows about these; add to it rather than fighting it.

**Colour is the awkward one.** Prose in `.md` files says "colour". Code says whatever
Apple says — `Color`, `tintColor` — and where we name our own thing we avoid the word:
`InkDefaults.tintHex`, `PageTint`. Do not introduce a symbol containing `colour` or
`color`.

The on-disk contract in `docs/05-file-contracts.md` uses `normalisedRect` and
`recognisedText`. Those key names are a public format. They cannot be "fixed".

---

## 3 · Files and types

- **One public type per file. Filename == type name.** `NormalisedRect` lives in
  `NormalisedRect.swift`.
- The exceptions are listed in `tooling/lint/style_allowlist.txt` and there are eight of
  them, all in `Core/Contracts/`: `Identifiers.swift`, `DTOs.swift`, `Protocols.swift`,
  `MarkdownIR.swift`, `Origin.swift`, `ReviewBundle.swift`, `BundleManifest.swift`,
  `AppSettings.swift`, plus `AppUI/Support/AppEnvironment.swift`. **Do not add to this
  list.** If you think you need to, you want a second file.
- Nested types are free — `SourceMap.Entry` costs nothing and does not need its own file.
- Every top-level type name must be unique repo-wide. `check_decls.py` fails a duplicate,
  including one in a different module: two `Renderer` types in two modules is legal Swift
  and a nightmare to read in a stack trace.

## 4 · Marker comments

**No bare `TODO`, `FIXME`, `XXX`, `HACK` or `unimplemented()`.** They are unattributable
and they never get done. The convention is:

```swift
// WAVE 2 (U4): replace the placeholder marker with the real margin glyph.
```

`WAVE n (Un):` — which wave, which unit, then what. `check_style.py` rejects anything
else. A marker with no unit is a note to nobody.

`fatalError` is permitted **only** in `Core/Contracts/AnchorResolver.swift`, with the body
`fatalError("WAVE 1 (U6)")`, and the file is allow-listed by name for it. Anywhere else,
throw a `PencilLoopError` or return an empty value.

## 5 · Safety

- **No force unwrap.** No `!` on an optional, no `try!`, no `as!`. Use `guard let`,
  `??`, or throw. The one place `!` is tolerated is inside `Tests/`, where a crash is a
  test failure with a stack trace, which is exactly what you want.
- **No `@unchecked Sendable` without a `// SAFETY:` comment** on the line above,
  explaining what makes it safe. If you cannot write that sentence, the type is not safe.
- **Explicit `self` in escaping closures.** Swift will make you do it in most cases; do it
  everywhere so a reader never has to work out which case they are in.
- **No `print`.** Use `os.Logger` in the modules that have one, or return the error.

## 6 · Concurrency

Swift 6, strict concurrency, and the module boundaries carry isolation:

- **AppUI is `MainActor` by default** — `Package.swift` sets
  `.defaultIsolation(MainActor.self)` on that target alone. Do not write `@MainActor` on
  every view; it is already on. Do write `nonisolated` on a member that has to satisfy a
  nonisolated protocol requirement from Core (see `PreviewEnvironment`'s stubs for the
  pattern).
- **Every other module is nonisolated by default.** Core, Storage, Sync, Ingest and
  Export contain no `@MainActor` anything. If you need serialisation, use an `actor`.
- **Annotate has four ratified exceptions, and no others.** `PKCanvasView`,
  `PKToolPicker` and `UIApplication` are main-actor-bound in the SDK, so a type that
  owns one cannot be anything else, and pretending otherwise in this file would only
  have produced a rule nobody could keep. The list, which is closed:
  `PageCanvasController` (owns a `PKCanvasView`), `PageCanvasPool` (owns the
  controllers), `InkToolPickerController` (owns a `PKToolPicker`), and two members of
  `InkLifecycleObserver` — its initialiser and its static `flush(using:)` — which read
  `UIApplication`; the observer type itself is not isolated, so its `deinit` can
  unregister from wherever it runs. **Ink persistence is not on this list and must not
  join it**: `InkPersistenceCoordinator` is an `actor`, its `record(_:)` is
  `nonisolated`, and that is what keeps archiving off the touch path. Anything else in
  Annotate that reaches for `@MainActor` is a change request, not a local edit.
- **`@Model` types never cross an actor boundary.** SwiftData model classes are bound to
  the `ModelContext` that made them. They live inside Storage and never leave it.
- **DTOs do cross.** Everything in `Core/Contracts/DTOs.swift` is a `Sendable` value type
  precisely so it can. The store reads models and hands back snapshots; callers send
  drafts back. Nothing else passes between them.
- **Nothing blocks the touch path.** Ink persistence is debounced 500ms and off the main
  actor; handwriting recognition is off the main actor and may fail silently; nothing in
  the reading or annotating path awaits the network.

## 7 · Imports

`check_imports.py` enforces this exactly:

| Module | May import |
|---|---|
| `Core` | Foundation, and nothing else |
| `Storage` | Foundation, SwiftData, Core |
| `Sync` | Foundation, Core (**never** Storage — the share extension links Sync) |
| `Ingest` | Foundation, PDFKit, UIKit, CoreGraphics, Core, Storage, and `Markdown` in one file |
| `Annotate` | Foundation, PencilKit, Speech, UIKit, Core, Storage |
| `Export` | Foundation, PDFKit, PencilKit, UIKit, CryptoKit, Core, Storage, Ingest |
| `AppUI` | anything |

- **No `import UIKit` or `import SwiftUI` anywhere under `Core/` or `Storage/`.** This is
  in CLAUDE.md as a non-negotiable and it is checked mechanically.
- **`import Markdown` appears in exactly one file:**
  `Sources/Ingest/Adapters/SwiftMarkdownAdapter.swift`. No `swift-markdown` type may
  appear in a signature outside it; convert to `MarkdownDocument` at the boundary.

## 8 · Documentation

- Every public type and every protocol member gets a doc comment.
- A protocol's doc comment **must say what happens when it fails or is unavailable**.
  That is a contract term, not an implementation detail: "returns nil when recognition is
  unavailable" is what tells the caller not to build a spinner.
- Reference the spec by section — `docs/04-flows.md § F4` — rather than restating it.
- When the code and the spec disagree, **update the doc in the same commit** (CLAUDE.md).
  Wave 3 folds W0-B's deviations back into `docs/`; do not edit `docs/` before then.

## 9 · Numbers and strings that appear twice

If a constant appears in two modules, it belongs in `Core/Contracts/` as a static. Already
frozen there, and not to be re-typed anywhere:

- `AnchorResolver.contextLength` (32), `.fuzzyTolerance` (0.15)
- `InkImage.paddingFraction` (0.15), `.maxLongEdgePixels` (2048),
  `InkImage.fileName(forPageIndex:)`
- `SyncFolder.inboxDirectoryName` / `.outboxDirectoryName`,
  `OutboxPayload.reviewDirectorySuffix`
- `DocumentFileNames` — `document.pdf`, `source.md`, `sourcemap.json`, `meta.json`,
  `reply.md`, `review.md`. Sync, Ingest, Storage and Export each spelled these; they
  are a public format and there is one copy now.
- `DocumentContainer` — the app container's document layout, and `storedPath(for:)` /
  `url(forStoredPath:)`. **Nothing else may decide where a pinned document lives.**
  Three Wave 1 units invented three layouts and the cost was documents recorded by
  absolute path, which stop opening after a reinstall.
- `GestureTiming.minimumHoldDuration` (0.3), `.longPressDuration` (0.4)
- `PageGeometry.annotationFriendly`
- `ReviewBundle.fileName`, `BundleManifest.fileName`
- `Slug.make(from:)`, `Slug.folderName(date:title:)` — folder names are identities, and
  two implementations that disagree about an ampersand produce two documents where there
  should be one.

## 10 · Tests

- `Tests/<Module>Tests/`, XCTest, one test type per file, filename == type name.
- Force unwrapping and `try!` are fine in tests.
- Test the pure logic. Pencil input, hover, squeeze and transcription cannot be unit
  tested and must not be faked into a test that proves nothing — write down what to check
  by hand on device instead.
