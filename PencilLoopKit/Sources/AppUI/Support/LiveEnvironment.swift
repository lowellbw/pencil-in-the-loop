//
//  LiveEnvironment.swift
//  AppUI · Support
//
//  The composition root. The one place in the app where a concrete type from
//  Storage, Sync, Ingest, Annotate or Export is named.
//
//  ─── CONSTRUCTION ORDER, AND WHY IT IS THIS ORDER ────────────────────────────
//  Two things are awkward and everything else falls out of them.
//
//  · **The store comes first.** Sync ingests into it, so it has to exist before
//    a coordinator can. `DocumentStore`'s `@ModelActor` initialiser is
//    module-internal, so it is built through `DocumentStore.live()`, which is
//    the only route from outside Storage.
//
//  · **The sync folder is not available yet, and may never be.** A coordinator
//    needs a resolved `SyncFolder`; the app has none on first run and may have
//    none on any later launch — an ejected volume, a signed-out provider, a
//    stale bookmark. So nothing here waits for one. `SyncGateway` goes into the
//    environment immediately and `RootModel` attaches a real coordinator behind
//    it if and when the folder resolves.
//
//  The rest are values with no dependencies and no I/O in their initialisers,
//  so they are simply made: the corrector, the bundle builder, the return-path
//  resolver, the folder access, the settings store, and the handwriting
//  recogniser the factory picks for this build. The speech engine is the one
//  exception and it has its own reason — see `DeferredSpeechTranscriber`.
//
//  ─── WHAT LOSING THE FOLDER COSTS ────────────────────────────────────────────
//  New documents, and nothing else (docs/02-spec.md § Cross-cutting). Every
//  document already in the library was pinned into the app container on arrival
//  and opens exactly as fast with the folder gone as with it there: the store
//  is local, the PDFs are local, the ink is local. Ingest stops. Sending stops,
//  with a sentence rather than a spinner. That is the whole of it, and it is why
//  nothing in this file is allowed to fail in a way that stops the library
//  opening.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import Annotate
import Core
import Export
import Ingest
import Storage
import Sync

/// Every dependency the UI has, wired to the real implementations.
///
/// Built once, at launch, by `RootModel`. Held for the life of the process:
/// rebuilding it would rebuild every screen, and the one thing that genuinely
/// changes at runtime — whether there is a sync folder — is handled behind
/// `SyncGateway` instead.
///
/// **On failure:** the initialiser throws only when the library store will not
/// open, which is the one dependency the app cannot do without and cannot
/// recover from by itself (`LibraryContainer`). Everything else here is
/// infallible by construction. `RootModel` turns a throw into one sentence on
/// screen rather than a crash.
///
/// **Nonisolated on purpose.** AppUI's default isolation is `MainActor`, which
/// would put this initialiser — and with it `ModelContainer`, a synchronous
/// store open plus any pending migration — on the main thread of a cold launch
/// with no hop out of it. Every dependency built here belongs to a nonisolated
/// module, so nothing about this type wants the main actor; `RootModel.start()`
/// builds it off the main thread instead (docs/03-architecture.md § Performance
/// targets, the sub-one-second cold launch).
public nonisolated struct LiveEnvironment: AppEnvironment {

    public let store: any DocumentStoring
    public let sync: any SyncCoordinating
    public let transcriber: any SpeechTranscribing
    public let recogniser: any HandwritingRecognising
    public let corrector: any TranscriptCorrecting
    public let bundleBuilder: any ReviewBundleBuilding
    public let returnPathResolver: any ReturnPathResolving
    public let settings: any SettingsStoring
    public let folderAccess: any FolderAccessing

    /// The gateway, concretely, so `RootModel` can attach a coordinator to it.
    /// The same object as `sync`; this is only a spelling that does not need a
    /// downcast.
    public let gateway: SyncGateway

    /// The settings store, concretely, for the bookmark accessors that are not
    /// on `SettingsStoring`.
    public let settingsStore: AppSettingsStore

    /// The folder access, concretely. `SyncCoordinator` takes this type rather
    /// than `any FolderAccessing`: it opens a security scope in one method and
    /// closes it in another, which the protocol's scoped `withAccess` cannot
    /// express (Sync/Folder/SyncFolderAccess.swift).
    public let syncFolderAccess: SyncFolderAccess

    /// - Parameter store: injectable so a test or a demo can run the real UI
    ///   against an in-memory library. The app passes nothing and gets
    ///   `DocumentStore.live()`.
    /// - Throws: `PencilLoopError.storeWriteFailed` when the SwiftData
    ///   container will not open.
    public init(store: (any DocumentStoring)? = nil) throws {
        let library = try store ?? DocumentStore.live()
        let settingsStore = AppSettingsStore()
        let gateway = SyncGateway()

        self.store = library
        self.settingsStore = settingsStore
        self.settings = settingsStore
        self.gateway = gateway
        self.sync = gateway

        // Built for the language in Settings, when it is first needed
        // (DeferredSpeechTranscriber).
        self.transcriber = DeferredSpeechTranscriber(settings: settingsStore)

        // Null unless this build has `PENCILLOOP_STROKE_RECOGNIZER` defined and
        // the device is on iPadOS 27. Ink is captured, persisted and exported
        // either way; recognition only adds searchable text
        // (docs/04-flows.md § F3).
        self.recogniser = InkRecogniserFactory.make()

        self.corrector = TermListCorrector()
        self.bundleBuilder = ReviewBundleBuilder()
        self.returnPathResolver = ReturnPathResolver()

        let access = SyncFolderAccess()
        self.syncFolderAccess = access
        self.folderAccess = access
    }

    // MARK: - The sync loop

    /// Builds the coordinator for a resolved folder, puts it behind the gateway
    /// and starts it.
    ///
    /// Called by `RootModel` at launch when a bookmark resolves, and again when
    /// the user picks a folder in first run or changes it in Settings. Attaching
    /// a second time replaces the first coordinator and stops it.
    ///
    /// The ingester writes into `DocumentContainer.documentsRoot()` — the app
    /// container's one document layout, which is also where Sync pins and what
    /// Storage records paths relative to. Three Wave 1 units each invented their
    /// own and the cost was documents recorded by absolute path, which stop
    /// opening after a reinstall (STYLE.md § 9).
    public func adoptFolder(_ folder: SyncFolder) async {
        let coordinator = SyncCoordinator(
            folder: folder,
            store: store,
            ingester: DocumentIngestor(),
            access: syncFolderAccess
        )
        await gateway.attach(coordinator)
        await gateway.start()
    }

    /// Adopt a relay: remember it, keep its token in the Keychain, attach.
    ///
    /// - Throws: `.storeWriteFailed` from the settings or Keychain write. The
    ///   gateway is untouched when that happens, so a failed attempt leaves the
    ///   app on the transport it was already using rather than on neither.
    public func adoptServer(baseURL: URL, token: String) async throws {
        try await settingsStore.setSyncServer(
            baseURLString: baseURL.absoluteString,
            displayName: baseURL.host() ?? baseURL.absoluteString,
            token: token
        )
        var updated = await settingsStore.settings
        updated.syncTransport = .server
        updated.serverBaseURLString = baseURL.absoluteString
        updated.hasCompletedFirstRun = true
        try await settingsStore.update(updated)

        await attachServerCoordinator(baseURL: baseURL, token: token)
    }

    /// Rebuild the relay coordinator at launch from what was persisted.
    ///
    /// - Returns: false when there is no relay configured, or no token in the
    ///   Keychain for it — which `RootModel` reports as one sentence in the
    ///   status line rather than as a dead end. The library is already on
    ///   screen by then and every pinned document opens regardless.
    @discardableResult
    public func adoptPersistedServer() async -> Bool {
        let settings = await settingsStore.settings
        guard let baseURL = settings.serverBaseURL,
              let host = baseURL.host(),
              let token = await settingsStore.syncServerToken(forHost: host) else {
            return false
        }
        await attachServerCoordinator(baseURL: baseURL, token: token)
        return true
    }

    /// The nine lines that make a relay the app's sync loop.
    ///
    /// Kept beside `adoptFolder` on purpose: this file is the one place in the
    /// app where a concrete type from another module is named, and having both
    /// coordinators constructed here is what keeps that true.
    private func attachServerCoordinator(baseURL: URL, token: String) async {
        let coordinator = HTTPSyncCoordinator(
            client: SyncServerClient(baseURL: baseURL, token: token),
            store: store,
            ingester: DocumentIngestor()
        )
        await gateway.attach(coordinator)
        await gateway.start()
    }
}
