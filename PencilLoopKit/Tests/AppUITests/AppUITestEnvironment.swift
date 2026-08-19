//
//  AppUITestEnvironment.swift
//  AppUITests
//
//  `PreviewEnvironment` with two of its nine dependencies replaceable.
//
//  The review sheet reaches everything through `AppEnvironment`, and the two
//  parts of it these tests are about are the store (what was written) and sync
//  (whether the bundle was queued). The other seven are the preview stubs,
//  unchanged: they do nothing, which is exactly what a test of the sheet's
//  bookkeeping wants them to do.
//

import Foundation
import Core
@testable import AppUI

/// An environment whose store and sync coordinator the test chooses.
///
/// `@MainActor` like `PreviewEnvironment`, and for the same reason: AppUI is
/// compiled with `.defaultIsolation(MainActor.self)`, so the preview stubs this
/// assembles are main-actor types and building one is a main-actor act
/// (Package.swift § AppUI).
@MainActor
struct AppUITestEnvironment: AppEnvironment {

    let store: any DocumentStoring
    let sync: any SyncCoordinating
    let transcriber: any SpeechTranscribing
    let recogniser: any HandwritingRecognising
    let corrector: any TranscriptCorrecting
    let bundleBuilder: any ReviewBundleBuilding
    let returnPathResolver: any ReturnPathResolving
    let settings: any SettingsStoring
    let folderAccess: any FolderAccessing

    init(
        store: any DocumentStoring,
        sync: any SyncCoordinating = AppUITestSyncCoordinator(),
        settings: AppSettings = .initial
    ) {
        self.store = store
        self.sync = sync
        self.transcriber = PreviewSpeechTranscriber()
        self.recogniser = PreviewHandwritingRecogniser()
        self.corrector = PreviewTranscriptCorrector()
        self.bundleBuilder = PreviewReviewBundleBuilder()
        self.returnPathResolver = PreviewReturnPathResolver()
        self.settings = PreviewSettingsStore(settings: settings)
        self.folderAccess = PreviewFolderAccess()
    }

    /// Nothing to attach: these tests never resolve a folder.
    func adoptFolder(_ folder: SyncFolder) async {}

    /// Inert, like `adoptFolder`. Nothing in AppUITests exercises adoption —
    /// the address and token are checked by `SyncServerChoiceTests` before this
    /// is ever reached, and the Keychain cannot honestly be tested here at all.
    func adoptServer(baseURL: URL, token: String) async throws {}
}
