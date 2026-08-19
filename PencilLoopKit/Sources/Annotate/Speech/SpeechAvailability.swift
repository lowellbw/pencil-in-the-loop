//
//  SpeechAvailability.swift
//  Annotate · Speech
//
//  Permissions and the one honest network moment in the app: the language
//  asset download (docs/03-architecture.md § 4). Engine-independent, so the
//  Settings row reads the same sentence whichever engine is in play.
//

import Foundation
import AVFoundation
import Speech
import Core

/// Whether dictation can run, and why not when it cannot.
///
/// A namespace rather than an object: the permission answers live in the system,
/// not in us, and an instance would only invite someone to cache them.
///
/// **Never a dead end.** Every path through `state(...)` that is not `.ready`
/// produces a sentence a person can act on, and the comment popover opens
/// regardless — the user taps "✎ scribble instead" and the flow completes with
/// `source = .handwriting` (Protocols.swift § SpeechTranscribing,
/// docs/02-spec.md § S3).
public enum SpeechAvailability {

    /// What the system says about one permission.
    public enum Permission: Sendable, Hashable {

        /// Never asked. Treated as available: we ask at the first press, which
        /// is the moment the request makes sense to the user.
        case notDetermined

        case granted

        /// Refused, or restricted by policy. Same outcome either way — offer
        /// scribble and say so once, in Settings.
        case denied
    }

    // MARK: The pure part

    /// Maps the facts about permissions, locale and assets onto the state the
    /// Settings row renders.
    ///
    /// Pure, total, and the only place these precedence rules are written down:
    /// a refused microphone beats an unsupported locale beats a missing asset.
    /// `.notDetermined` counts as available, because a permission we have not
    /// asked for yet is not a failure — it is a prompt we have not shown.
    ///
    /// - Parameters:
    ///   - permission: the narrower of microphone and, where the engine needs
    ///     it, speech recognition.
    ///   - localeSupported: whether this engine can transcribe this language at
    ///     all, downloaded or not.
    ///   - localeDisplayName: the language's name, for the sentence.
    ///   - assetsInstalled: whether the model is on the device right now.
    ///   - downloadFraction: 0…1 while a download is running, else nil.
    ///   - downloadRequested: whether `prepareAssets()` has queued a download
    ///     that has not started reporting progress yet.
    public static func state(
        permission: Permission,
        localeSupported: Bool,
        localeDisplayName: String,
        assetsInstalled: Bool,
        downloadFraction: Double?,
        downloadRequested: Bool
    ) -> SpeechAssetState {
        if permission == .denied {
            return .unavailable(
                reason: "Microphone access is off. Turn it on in Settings to dictate comments — you can still write them by hand."
            )
        }
        if localeSupported == false {
            return .unavailable(
                reason: "\(localeDisplayName) isn't available for on-device dictation. Choose another language in Settings, or write comments by hand."
            )
        }
        if assetsInstalled {
            return .ready
        }
        if let fraction = downloadFraction {
            return .downloading(progress: min(max(fraction, 0), 1))
        }
        if downloadRequested {
            return .downloading(progress: nil)
        }
        return .unavailable(
            reason: "The \(localeDisplayName) dictation model hasn't downloaded yet. It downloads once, in the background, next time you're online."
        )
    }

    /// The narrower of two permissions, for engines that need both.
    public static func narrower(_ left: Permission, _ right: Permission) -> Permission {
        if left == .denied || right == .denied { return .denied }
        if left == .notDetermined || right == .notDetermined { return .notDetermined }
        return .granted
    }

    /// A language's own name for itself, for the Settings row.
    public static func displayName(for locale: Locale) -> String {
        locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    // MARK: The system part

    /// The microphone permission as it stands, without prompting.
    public static func microphone() -> Permission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// Prompts for the microphone if it has not been asked for yet.
    ///
    /// Call this at the first press, not at launch: a permission sheet on a
    /// cold start, before the user has done anything, is the dead end this app
    /// does not have.
    public static func requestMicrophone() async -> Permission {
        let current = microphone()
        guard current == .notDetermined else { return current }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
        return granted ? .granted : .denied
    }

    /// The speech-recognition permission as it stands, without prompting.
    ///
    /// Only the fallback engine needs this; `SpeechAnalyzer` transcribes on
    /// device without it.
    public static func speechRecognition() -> Permission {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// Prompts for speech recognition if it has not been asked for yet.
    public static func requestSpeechRecognition() async -> Permission {
        let current = speechRecognition()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                switch status {
                case .authorized: continuation.resume(returning: Permission.granted)
                case .denied, .restricted: continuation.resume(returning: Permission.denied)
                case .notDetermined: continuation.resume(returning: Permission.denied)
                @unknown default: continuation.resume(returning: Permission.denied)
                }
            }
        }
    }
}
