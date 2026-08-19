//
//  SharedItemIntake.swift
//  ReviewShareExtension
//
//  Turning what the share sheet handed us into one call on
//  `ShareStagingWriter`.
//
//  Ordering matters and is not arbitrary. A file URL conforms to `public.url`,
//  and a markdown file conforms to `public.plain-text`, so the checks run from
//  the most specific type to the least: PDF, then text, then any URL — and the
//  URL branch decides for itself whether it is looking at a file on disk or a
//  page on the web.
//
//  Isolation: this type is on the main actor because `NSExtensionItem` and
//  `NSItemProvider` arrive there and are not `Sendable`, so they must not
//  cross. The work that runs inside a provider's completion handler — which
//  Foundation calls on its own queue — is `nonisolated` and touches nothing but
//  its arguments, which is what keeps the copy off the main thread without
//  lying about where it runs.
//

import Foundation
import UniformTypeIdentifiers
import Core
import Sync
import os

/// Reads the extension's input items and stages the first one it understands.
///
/// **On failure:** never throws. Every outcome is a `ShareOutcome`, including
/// "there was nothing here we read", because the share sheet is not a place to
/// surface an error type.
@MainActor
enum SharedItemIntake {

    /// The title used when nothing better can be worked out.
    nonisolated static let fallbackDocumentTitle = "Shared document"

    /// The title used for a link with no page title and no useful path.
    nonisolated static let fallbackLinkTitle = "Shared link"

    /// Longest title taken from a host app's supplied text, in characters.
    /// Safari hands over a page title; a text selection share hands over the
    /// selection, which can be a paragraph.
    nonisolated static let maximumSuppliedTitleLength = 120

    /// Stages the first attachment that is a PDF, a markdown or text file, or a
    /// link.
    ///
    /// - Returns: `.staged` when a directory landed in `staging/`,
    ///   `.unsupported` when no attachment was of a kind this extension reads,
    ///   or the failure the writer reported.
    static func stage(_ items: [NSExtensionItem], using writer: ShareStagingWriter) async -> ShareOutcome {
        for item in items {
            let supplied = SharedItemIntake.suppliedTitle(from: item)
            for provider in item.attachments ?? [] {
                if let outcome = await SharedItemIntake.stage(provider, suppliedTitle: supplied, using: writer) {
                    return outcome
                }
            }
        }
        return .unsupported
    }

    // MARK: - One attachment

    /// - Returns: nil when this attachment is not something we read, so the
    ///   caller can try the next one. A share from Mail carries several.
    private static func stage(
        _ provider: NSItemProvider,
        suppliedTitle: String?,
        using writer: ShareStagingWriter
    ) async -> ShareOutcome? {
        let suggestedName = provider.suggestedName

        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            return await SharedItemIntake.stageFileRepresentation(
                from: provider,
                typeIdentifier: UTType.pdf.identifier,
                suggestedName: suggestedName,
                payload: .pdf,
                using: writer
            )
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            return await SharedItemIntake.stageFileRepresentation(
                from: provider,
                typeIdentifier: UTType.plainText.identifier,
                suggestedName: suggestedName,
                payload: nil,
                using: writer
            )
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            guard let address = await SharedItemIntake.loadURL(from: provider) else {
                return ShareOutcome.unsupported
            }
            if address.isFileURL {
                return await SharedItemIntake.stageLocalFile(
                    at: address,
                    suggestedName: suggestedName,
                    using: writer
                )
            }
            return SharedItemIntake.stageWebPage(address, suppliedTitle: suppliedTitle, using: writer)
        }

        return nil
    }

    /// Asks the provider for a file on disk and copies it before the handler
    /// returns.
    ///
    /// `loadFileRepresentation` hands back a URL that is valid only for the
    /// duration of the completion handler, so the copy happens inside it. That
    /// is also what keeps this off the main thread and off the heap: the bytes
    /// go filesystem to filesystem and never through this process's memory.
    ///
    /// - Parameter payload: what to treat the file as, or nil to work it out
    ///   from the extension of whatever the provider produced.
    private static func stageFileRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String,
        suggestedName: String?,
        payload: ShareStagingWriter.Payload?,
        using writer: ShareStagingWriter
    ) async -> ShareOutcome {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url else {
                    SyncLog.folder.error(
                        "The share sheet could not produce a file: \(error?.localizedDescription ?? "no reason given")"
                    )
                    continuation.resume(returning: ShareOutcome.stagingFailed)
                    return
                }
                let resolved = payload ?? ShareStagingWriter.Payload.matching(fileExtension: url.pathExtension)
                guard let resolved else {
                    continuation.resume(returning: ShareOutcome.unsupported)
                    return
                }
                let title = SharedItemIntake.title(suggestedName: suggestedName, fileURL: url)
                do {
                    try writer.stageDocument(copying: url, title: title, as: resolved)
                    continuation.resume(returning: ShareOutcome.staged(title: title))
                } catch {
                    SyncLog.folder.error("Staging a shared file failed: \(error.localizedDescription)")
                    continuation.resume(returning: ShareOutcome.failure(for: error))
                }
            }
        }
    }

    /// Copies a file the provider described by URL rather than by content —
    /// what the Files app sends for a document it already has on disk.
    ///
    /// Detached rather than inline: this one is a `copyItem` on the calling
    /// thread, and the calling thread here is the main one.
    private static func stageLocalFile(
        at source: URL,
        suggestedName: String?,
        using writer: ShareStagingWriter
    ) async -> ShareOutcome {
        await Task.detached {
            guard let payload = ShareStagingWriter.Payload.matching(fileExtension: source.pathExtension) else {
                return ShareOutcome.unsupported
            }
            let scoped = source.startAccessingSecurityScopedResource()
            defer {
                if scoped { source.stopAccessingSecurityScopedResource() }
            }
            let title = SharedItemIntake.title(suggestedName: suggestedName, fileURL: source)
            do {
                try writer.stageDocument(copying: source, title: title, as: payload)
                return ShareOutcome.staged(title: title)
            } catch {
                SyncLog.folder.error("Staging a shared local file failed: \(error.localizedDescription)")
                return ShareOutcome.failure(for: error)
            }
        }.value
    }

    /// Records a link. No fetch — see this unit's report.
    private static func stageWebPage(
        _ address: URL,
        suppliedTitle: String?,
        using writer: ShareStagingWriter
    ) -> ShareOutcome {
        let title = SharedItemIntake.title(forWebAddress: address, suppliedTitle: suppliedTitle)
        do {
            try writer.stageWebPage(address, title: title)
            return .staged(title: title)
        } catch {
            SyncLog.folder.error("Staging a shared link failed: \(error.localizedDescription)")
            return ShareOutcome.failure(for: error)
        }
    }

    /// - Returns: nil when the provider had no URL to give, which is a
    ///   malformed item rather than an error worth naming.
    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { address, error in
                if let error {
                    SyncLog.folder.notice("A shared item offered a URL that would not load: \(error.localizedDescription)")
                }
                continuation.resume(returning: address)
            }
        }
    }

    // MARK: - Titles

    /// The page title or subject the host app supplied, if any.
    nonisolated static func suppliedTitle(from item: NSExtensionItem) -> String? {
        for candidate in [item.attributedTitle?.string, item.attributedContentText?.string] {
            guard let candidate else { continue }
            let cleaned = SharedItemIntake.condensed(candidate)
            if cleaned.isEmpty == false { return cleaned }
        }
        return nil
    }

    /// A human title for a file, preferring the name the host app suggested
    /// over the name of the temporary copy it produced.
    nonisolated static func title(suggestedName: String?, fileURL: URL) -> String {
        for candidate in [suggestedName, fileURL.lastPathComponent] {
            guard let candidate else { continue }
            let cleaned = SharedItemIntake.readableTitle(fromFileName: candidate)
            if cleaned.isEmpty == false { return cleaned }
        }
        return SharedItemIntake.fallbackDocumentTitle
    }

    /// A human title for a link: the page title when the host app gave one,
    /// then the last path component, then the host.
    ///
    /// `https://arxiv.org/abs/1706.03762` with no page title becomes
    /// `1706.03762`, which is thin but recognisable — and the app is free to
    /// replace it with the real title once it has fetched the page.
    nonisolated static func title(forWebAddress address: URL, suppliedTitle: String?) -> String {
        if let suppliedTitle, suppliedTitle.isEmpty == false { return suppliedTitle }
        let component = SharedItemIntake.readableTitle(fromFileName: address.lastPathComponent)
        if component.isEmpty == false { return component }
        if let host = address.host, host.isEmpty == false { return host }
        return SharedItemIntake.fallbackLinkTitle
    }

    /// `attention_is_all_you_need.pdf` becomes `attention is all you need`.
    ///
    /// - Returns: an empty string when there was nothing usable in the name.
    ///   Callers substitute their own fallback rather than being handed a
    ///   sentinel.
    nonisolated static func readableTitle(fromFileName name: String) -> String {
        let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let decoded = base.removingPercentEncoding ?? base
        return SharedItemIntake.condensed(decoded.replacingOccurrences(of: "_", with: " "))
    }

    /// First line, single-spaced, trimmed, and no longer than a title should be.
    nonisolated static func condensed(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let words = firstLine.split(whereSeparator: \.isWhitespace).map(String.init)
        let joined = words.joined(separator: " ")
        if joined.count <= SharedItemIntake.maximumSuppliedTitleLength { return joined }
        return String(joined.prefix(SharedItemIntake.maximumSuppliedTitleLength))
            .trimmingCharacters(in: .whitespaces)
    }
}
