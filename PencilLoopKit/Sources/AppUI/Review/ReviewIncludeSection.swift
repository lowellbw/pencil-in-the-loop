//
//  ReviewIncludeSection.swift
//  AppUI · Review
//
//  The Include toggles (docs/02-spec.md § S4): Comments, Inked pages,
//  Recognised text, Full document.
//
//  The defaults are the argument the brief makes: anchored comments say what
//  you meant, the inked pages show where you meant it, and text plus image is
//  strictly better than either (docs/00-brief.md § Three layers). So the first
//  three open on, the whole document opens off — the other side already has it,
//  and re-sending it spends the context window that makes the reply good.
//

import SwiftUI
import Core

/// The Include section of the review sheet.
struct ReviewIncludeSection: View {

    /// The current choice.
    let include: ReviewIncludeOptions

    let commentCount: Int
    let inkedPageCount: Int
    let recognisedPageCount: Int

    /// Called with the whole updated value, so the model never has to merge
    /// four separate writes.
    let onChange: (ReviewIncludeOptions) -> Void

    var body: some View {
        Section {
            Toggle(isOn: commentsBinding) {
                Text("Comments (\(commentCount))")
            }
            .disabled(commentCount == 0)

            Toggle(isOn: inkBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Inked pages (\(inkedPageCount))")
                    Text("Cropped to the ink, with the page underneath.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(inkedPageCount == 0)

            Toggle(isOn: recognisedBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recognised text")
                    Text(recognisedSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(recognisedPageCount == 0)

            Toggle(isOn: fullDocumentBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full document")
                    Text("Usually unnecessary — they already have it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Include")
        } footer: {
            Text("Comments say what you meant; the inked pages show where. Sending both is better than either on its own.")
        }
    }

    private var recognisedSubtitle: String {
        recognisedPageCount == 0
            ? "No handwriting has been recognised on this document."
            : "Handwriting read on device, on \(recognisedPageCount) page(s)."
    }

    private var commentsBinding: Binding<Bool> {
        Binding(
            get: { self.include.comments },
            set: { value in
                var next = self.include
                next.comments = value
                self.onChange(next)
            }
        )
    }

    private var inkBinding: Binding<Bool> {
        Binding(
            get: { self.include.inkImages },
            set: { value in
                var next = self.include
                next.inkImages = value
                self.onChange(next)
            }
        )
    }

    private var recognisedBinding: Binding<Bool> {
        Binding(
            get: { self.include.recognisedText },
            set: { value in
                var next = self.include
                next.recognisedText = value
                self.onChange(next)
            }
        )
    }

    private var fullDocumentBinding: Binding<Bool> {
        Binding(
            get: { self.include.fullDocument },
            set: { value in
                var next = self.include
                next.fullDocument = value
                self.onChange(next)
            }
        )
    }
}

#Preview("Include toggles") {
    List {
        ReviewIncludeSection(
            include: ReviewIncludeOptions.standard,
            commentCount: 3,
            inkedPageCount: 2,
            recognisedPageCount: 2,
            onChange: { _ in }
        )
    }
    .listStyle(.insetGrouped)
}

#Preview("Include toggles · nothing to include") {
    List {
        ReviewIncludeSection(
            include: ReviewIncludeOptions.standard,
            commentCount: 0,
            inkedPageCount: 0,
            recognisedPageCount: 0,
            onChange: { _ in }
        )
    }
    .listStyle(.insetGrouped)
}
