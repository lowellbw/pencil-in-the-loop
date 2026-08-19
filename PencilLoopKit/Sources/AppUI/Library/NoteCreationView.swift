//
//  NoteCreationView.swift
//  AppUI · Library
//
//  Starting something of your own (docs/11-backlog.md § B1).
//
//  Two routes through one sheet, because they differ in exactly one row: a
//  notebook asks what paper to rule, and a written document asks for the words.
//  Everything else — the title, the button, what happens afterwards — is the
//  same, and two sheets would be two places to fix the next thing.
//
//  The shape is `SettingsView`'s: a `NavigationStack` around an inset-grouped
//  `List`, dismissed from a `.confirmationAction`. Settings has no Save button
//  because every row writes through as it changes; this one does, because
//  nothing exists until it is pressed.
//

import SwiftUI
import Core

/// The sheet that makes a notebook or a written document.
public struct NoteCreationView: View {

    /// Which of the two documents this sheet is making.
    public enum Kind: Hashable, Sendable, Identifiable {

        /// Blank paper to write on with the Pencil.
        case notebook

        /// Markdown typed here and rendered like anything else.
        case written

        public var id: Self { self }

        var title: String {
            switch self {
            case .notebook: return "New Notebook"
            case .written: return "New Document"
            }
        }
    }

    /// How many pages a new notebook starts with.
    ///
    /// Enough to think in without deciding anything: more can be added, and a
    /// blank page costs a few kilobytes. Asking the user to predict how much
    /// they are about to write would be asking the wrong question.
    private static let defaultPageCount = 8

    private let kind: Kind
    private let model: LibraryModel
    private let onCreated: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var paper: PaperStyle = .lined
    @State private var pageCount = NoteCreationView.defaultPageCount
    @State private var markdown = ""
    @State private var isCreating = false

    /// - Parameters:
    ///   - onCreated: the new document's id. The library selects it, which
    ///     collapses the sidebar and opens the reader on page one.
    public init(kind: Kind, model: LibraryModel, onCreated: @escaping (UUID) -> Void) {
        self.kind = kind
        self.model = model
        self.onCreated = onCreated
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Title", text: $title)
                        .textInputAutocapitalization(.sentences)
                } footer: {
                    Text(NoteCreationView.titleExplanation)
                }

                switch kind {
                case .notebook: notebookSection
                case .written: writtenSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Creating…" : "Create") { create() }
                        .disabled(isCreating || canCreate == false)
                }
            }
            .interactiveDismissDisabled(isCreating)
        }
    }

    private var notebookSection: some View {
        Section {
            Picker("Paper", selection: $paper) {
                ForEach(PaperStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            Stepper("\(pageCount) pages", value: $pageCount, in: 1...100)
        } footer: {
            Text(NoteCreationView.paperExplanation)
        }
    }

    private var writtenSection: some View {
        Section {
            TextEditor(text: $markdown)
                .frame(minHeight: 220)
                .font(.body)
        } header: {
            Text("Text")
        } footer: {
            Text(NoteCreationView.writtenExplanation)
        }
    }

    private var canCreate: Bool {
        NoteCreationView.canCreate(kind: kind, markdown: markdown)
    }

    /// Whether there is enough here to make something.
    ///
    /// A notebook needs nothing but a page count, which has a default — blank
    /// paper with no title is a perfectly ordinary thing to want. A written
    /// document with no words in it would be a blank page pretending to be
    /// prose, and since the text cannot be edited afterwards it would be a
    /// document that could never become anything.
    ///
    /// Static and pure so it can be tested; the button's enabled state is the
    /// one thing here that is a rule rather than a layout.
    static func canCreate(kind: Kind, markdown: String) -> Bool {
        switch kind {
        case .notebook:
            return true
        case .written:
            return markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    private func create() {
        isCreating = true
        Task {
            let created: UUID?
            switch self.kind {
            case .notebook:
                created = await self.model.createNotebook(
                    title: self.title, paper: self.paper, pages: self.pageCount
                )
            case .written:
                created = await self.model.createWrittenDocument(
                    title: self.title, markdown: self.markdown
                )
            }
            self.isCreating = false
            // On failure the reason is already in the library's status line and
            // the sheet stays open with everything typed still in it.
            guard let created else { return }
            self.dismiss()
            self.onCreated(created)
        }
    }

    private static let titleExplanation =
        "This is what you will look for in the library later. Leave it empty and it will be called Note."

    private static let paperExplanation =
        "The ruling is printed onto the page, so your handwriting stays on the lines however far you zoom in. You can add more pages later, and they will match."

    private static let writtenExplanation =
        "Markdown, laid out the same way as a document sent to you. Write it here, then annotate it with the Pencil like anything else — the text cannot be edited afterwards."
}

#Preview("Notebook") {
    NoteCreationView(kind: .notebook, model: LibraryModel(environment: PreviewEnvironment())) { _ in }
}

#Preview("Written") {
    NoteCreationView(kind: .written, model: LibraryModel(environment: PreviewEnvironment())) { _ in }
}
