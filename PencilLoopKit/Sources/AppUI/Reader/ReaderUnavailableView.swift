//
//  ReaderUnavailableView.swift
//  AppUI · Reader
//
//  What the reader shows instead of a page. One sentence in secondary label
//  colour and nothing else — no illustration, no retry button that would retry
//  something that has already failed for a reason the sentence gives
//  (docs/01-design-principles.md § 6).
//

import SwiftUI

/// The reader's empty state: a document with no file, or one that will not
/// parse.
///
/// **Never fails.** A string and a symbol.
struct ReaderUnavailableView: View {

    /// The store's own words, shown verbatim. An ingest failure's reason is
    /// written for the reader (Core/Contracts/Protocols.swift,
    /// `recordIngestFailure(folderName:reason:)`).
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(self.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: 420)
        .accessibilityElement(children: .combine)
    }
}

#Preview("No file") {
    ReaderUnavailableView(
        message: "This document arrived without a file. Its folder could not be read when it was imported."
    )
}
