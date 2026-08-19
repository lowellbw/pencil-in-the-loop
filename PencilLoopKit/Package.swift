// swift-tools-version: 6.2
//
// PencilLoopKit — every line of app logic lives here, not in the Xcode targets.
// The .xcodeproj carries two thin shells (the app and the share extension) and
// links products from this package. Keeping it this way means `swift build` is a
// complete compile check that needs no project file, no signing and no simulator.
//
// Swift 6 tools version implies `.v6` language mode for every target. Do not add
// `.swiftLanguageMode(.v6)` by hand; it is already on.

import PackageDescription

let package = Package(
    name: "PencilLoopKit",

    // The app is iPad-only. Declaring a single platform keeps SwiftPM from
    // trying to resolve availability for platforms this code will never run on.
    platforms: [
        .iOS(.v26)
    ],

    products: [
        // The app target links this: everything.
        .library(
            name: "PencilLoopKit",
            targets: ["Core", "Storage", "Sync", "Ingest", "Annotate", "Export", "AppUI"]
        ),

        // The share extension links this and only this. Extensions run under a
        // hard memory cap and are killed without ceremony, so the extension must
        // not drag in SwiftUI or SwiftData. That is enforced structurally: this
        // product exposes Core and Sync, and neither depends on Storage.
        .library(
            name: "PencilLoopKitCore",
            targets: ["Core", "Sync"]
        )
    ],

    dependencies: [
        // Apple's own Markdown parser. Tags 0.1.0 through 0.8.0 exist upstream at
        // the time of writing; 0.8.0 is current, its product is named `Markdown`,
        // and its manifest declares tools version 6.2 — so it needs Xcode 26,
        // which this project needs anyway.
        //
        // `from:` sets the floor, not the pin. For a pre-1.0 package SwiftPM reads
        // it as 0.6.0 ..< 1.0.0, so the actual version is whatever
        // Package.resolved says — commit that file after the first successful
        // resolve and the build becomes reproducible. If resolution fails, see
        // FirstBuild.md; bumping this one number is the whole fix.
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.6.0")
    ],

    targets: [

        // MARK: - Core

        // Models, IDs, anchors, and the protocols every other module talks
        // through. No Foundation-adjacent UI, no SwiftData, no SwiftUI. Owned by
        // the Core unit — this manifest only declares it.
        .target(
            name: "Core",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),

        // MARK: - Storage

        // SwiftData schema, the on-disk layout, security-scoped bookmarks.
        .target(
            name: "Storage",
            dependencies: ["Core"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),

        // MARK: - Sync

        // Folder watcher, inbox scanner, outbox writer.
        //
        // Deliberately depends on Core alone, never Storage. Sync reaches the
        // library through the `DocumentStoring` protocol declared in Core, which
        // is what lets the share extension link Sync without pulling SwiftData
        // into an extension process. If you ever add `"Storage"` here, the
        // PencilLoopKitCore product silently gains SwiftData — don't.
        .target(
            name: "Sync",
            dependencies: ["Core"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),

        // MARK: - Ingest

        // MarkdownRenderer, PDFImporter, MetadataExtractor, and the source map.
        .target(
            name: "Ingest",
            dependencies: [
                "Core",
                "Storage",
                .product(name: "Markdown", package: "swift-markdown")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),

        // MARK: - Annotate

        // InkLayer, AnchorResolver, VoiceRecorder, HandwritingRecogniser.
        .target(
            name: "Annotate",
            dependencies: ["Core", "Storage"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")

                // Uncomment to compile the PKStrokeRecognizer path, which turns
                // handwritten margin notes into searchable text. It is off by
                // default because PKStrokeRecognizer ships in iPadOS 27 and is
                // Latin-only in the Simulator, so a build that assumes it will
                // fail on an older SDK for a feature you cannot test anyway.
                // Turn it on once you are building against the 27 SDK on device.
                // See FirstBuild.md § Expected errors.
                // , .define("PENCILLOOP_STROKE_RECOGNIZER")
            ]
        ),

        // MARK: - Export

        // ReviewBundleBuilder, InkCropper, ReturnPathResolver. Depends on Ingest
        // for the source map, which is what turns a page-anchored comment back
        // into a character range in the markdown the model actually wrote.
        .target(
            name: "Export",
            dependencies: ["Core", "Storage", "Ingest"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),

        // MARK: - AppUI

        // Library, Reader, CommentPopover, ReviewSheet, Settings.
        .target(
            name: "AppUI",
            dependencies: ["Core", "Storage", "Sync", "Ingest", "Annotate", "Export"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),

                // Every type in a SwiftUI module is main-actor bound in practice,
                // so make that the default rather than writing @MainActor on all
                // several hundred of them. Requires a Swift 6.2 or newer
                // toolchain; if the manifest fails to parse, delete this one line
                // (FirstBuild.md § Expected errors has the details).
                .defaultIsolation(MainActor.self)
            ]
        ),

        // MARK: - Tests

        // Every one of these `import Core` as well as its own target. That
        // worked by transitive visibility and would have stopped working the
        // day a target's dependency on Core became implementation-only, so
        // Core is declared rather than assumed. AnnotateTests already did.
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
        .testTarget(name: "StorageTests", dependencies: ["Storage", "Core"]),
        .testTarget(name: "SyncTests", dependencies: ["Sync", "Core"]),
        .testTarget(name: "IngestTests", dependencies: ["Ingest", "Core"]),
        .testTarget(name: "AnnotateTests", dependencies: ["Annotate", "Core"]),
        .testTarget(name: "ExportTests", dependencies: ["Export", "Core"]),

        // AppUI's pure logic: marker placement, popover state, the library's
        // strings, the review sheet's ordering. Those four types were written
        // as values with no dependencies precisely so they could be tested, and
        // then there was no target to test them in.
        //
        // Views are not tested here and should not be: Pencil input, hover,
        // squeeze and transcription cannot be exercised without a device, and
        // faking them into a test proves nothing (STYLE.md § 10). What to check
        // by hand is written down in FirstBuild.md § 6 instead.
        //
        // Note for whoever writes the next test here: `AppUI` is compiled with
        // `.defaultIsolation(MainActor.self)`, so its types are main-actor
        // bound and the test cases below are `@MainActor` to match.
        .testTarget(name: "AppUITests", dependencies: ["AppUI", "Core"])
    ]
)
