//
//  StrokeRecogniserEngine.swift
//  Annotate · Ink
//
//  The whole file is compiled out unless PENCILLOOP_STROKE_RECOGNIZER is
//  defined, which it is not by default: PKStrokeRecognizer ships in the iPadOS
//  27 SDK and this project's deployment floor is 26.0, so a build against a 26
//  SDK must not see this type at all (Package.swift § Annotate,
//  FirstBuild.md § Expected errors).
//
//  The American spelling in the flag and in Apple's type is Apple's and the
//  build system's; ours is `Recogniser` throughout (STYLE.md § 2).
//

#if PENCILLOOP_STROKE_RECOGNIZER

import Foundation
import PencilKit
import Core

/// Handwriting to text, on device, from stroke vectors rather than pixels.
///
/// An `actor` because `PKStrokeRecognizer` is one, and because recognition must
/// never run on the main actor: it has a 500ms per-page budget and the drawing
/// path has none at all (docs/03-architecture.md § Performance targets).
/// Everything here is `await`ed from a `Task.detached` inside
/// `InkPersistenceCoordinator`, so no part of it can end up behind the touch
/// path however it is called.
///
/// **When it fails or is unavailable — the contract term that matters:** every
/// path returns nil. An unarchivable `PKDrawing`, an unsupported locale, a page
/// with more strokes than the budget allows, a cancelled task, an engine that
/// simply declines — all of them are nil, none of them throw, and none of them
/// are worth telling the user about. Ink is captured and exported as an image
/// regardless; recognition only makes it searchable (docs/04-flows.md § F3).
@available(iOS 27, *)
public actor StrokeRecogniserEngine: HandwritingRecognising {

    /// Pages busier than this are skipped rather than allowed to blow the
    /// per-page budget. A page carrying several thousand strokes is a drawing,
    /// not a margin note, and nobody is going to search it for words.
    public static let strokeBudget = 3000

    /// The budget from docs/03-architecture.md, used only to log overruns —
    /// exceeding it is a performance bug to fix, never a reason to drop a result
    /// that has already been computed.
    public static let perPageBudget: TimeInterval = 0.5

    private var availability: [String: Bool] = [:]

    public init() {}

    /// Reads one page of ink.
    ///
    /// - Parameters:
    ///   - drawingData: archived `PKDrawing` bytes, exactly as
    ///     `DocumentStoring.saveDrawing(_:pageIndex:documentId:)` stored them.
    ///   - locale: the language to read in.
    /// - Returns: the recognised text, or nil for every failure and every
    ///   uninteresting result. See the type's documentation.
    public func recogniseText(drawingData: Data, locale: Locale) async -> RecognisedInk? {
        guard !drawingData.isEmpty else { return nil }
        guard let drawing = try? PKDrawing(data: drawingData) else {
            InkLog.recognition.error("Ink for recognition could not be unarchived; skipping the page.")
            return nil
        }
        guard !drawing.strokes.isEmpty else { return nil }
        guard drawing.strokes.count <= StrokeRecogniserEngine.strokeBudget else {
            InkLog.recognition.debug("Page carries more strokes than the budget allows; skipping recognition.")
            return nil
        }
        guard await self.isAvailable(for: locale) else { return nil }
        guard !Task.isCancelled else { return nil }

        let started = Date()
        guard let text = await StrokeRecogniserEngine.strokeText(in: drawing, locale: locale) else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > StrokeRecogniserEngine.perPageBudget {
            InkLog.recognition.debug("Recognition ran long for one page; see docs/03-architecture.md § Performance targets.")
        }

        guard !Task.isCancelled else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return RecognisedInk(text: trimmed, confidence: nil)
    }

    /// Whether the engine can read this locale at all.
    ///
    /// Answered from `PKStrokeRecognizer`'s own list of supported languages and
    /// then cached, since the answer cannot change while the app is running and
    /// the coordinator asks once per page.
    ///
    /// Callers treat false as "skip recognition", never as an error worth
    /// reporting (Core/Contracts/Protocols.swift, `HandwritingRecognising`).
    public func isAvailable(for locale: Locale) async -> Bool {
        let key = locale.identifier
        if let cached = self.availability[key] { return cached }
        let answer = StrokeRecogniserEngine.supports(locale)
        self.availability[key] = answer
        return answer
    }

    // MARK: - The SDK boundary

    // WAVE 2 (U4): the two calls below are the only lines in the ink module
    // written against an SDK that was not on the machine that wrote them.
    // Check them against the shipping iPadOS 27 headers on the first device
    // build; if the entry point differs, nothing outside these two functions
    // changes. Everything around them — the empty-page short circuit, the
    // stroke budget, the cancellation checks, the trimming and the nil
    // contract — is already correct and should be left alone.

    /// The single recognition call.
    private static func strokeText(in drawing: PKDrawing, locale: Locale) async -> String? {
        let engine = PKStrokeRecognizer(locale: locale)
        return try? await engine.text(from: drawing)
    }

    /// The single availability call. `PKStrokeRecognizer` covers 29 languages;
    /// matching on language code rather than full identifier means `en-GB` is
    /// served by an engine that lists `en-US`, which is what a reader dictating
    /// margin notes wants.
    private static func supports(_ locale: Locale) -> Bool {
        let wanted = locale.language.languageCode
        guard let wanted else { return false }
        return PKStrokeRecognizer.supportedLanguages.contains { supported in
            supported.language.languageCode == wanted
        }
    }
}

#endif
