//
//  GroupNameSheet.swift
//  AppUI · Library
//
//  Naming a group, and renaming one (docs/02-spec.md § S1).
//
//  One sheet for both because they differ in nothing but the title and what the
//  Save button calls. The shape is `NoteCreationView`'s — a `NavigationStack`
//  around an inset-grouped `List`, Cancel and Save in the toolbar — because this
//  is the same kind of act: nothing happens until Save is pressed.
//
//  A sheet rather than an alert with a text field. An alert cannot carry the
//  footer that explains what a group is, and the explanation is worth having
//  exactly once, the first time somebody makes one.
//

import SwiftUI
import Core

/// The sheet that names a new group or renames an existing one.
public struct GroupNameSheet: View {

    /// Which of the two acts this sheet is performing.
    ///
    /// One piece of state rather than a bool and a payload, so the two cannot
    /// disagree — the pattern `NoteCreationView.Kind` already sets.
    public enum Mode: Hashable, Sendable, Identifiable {

        /// File this document under a group it is about to name.
        case create(folderName: String)

        /// Rename this group, moving everything filed under it.
        case rename(current: String)

        public var id: Self { self }

        var title: String {
            switch self {
            case .create: return "New Group"
            case .rename: return "Rename Group"
            }
        }

        /// What the field starts with. A rename opens on the name it is about
        /// to change, because most renames are edits rather than replacements.
        var initialName: String {
            switch self {
            case .create: return ""
            case let .rename(current): return current
            }
        }
    }

    private static let explanation = """
        Documents sharing a name are shown together when the Library is grouped. \
        A group exists for as long as something is in it.
        """

    private let mode: Mode
    private let model: LibraryModel

    @Environment(\.dismiss) private var dismiss

    @State private var name: String

    public init(mode: Mode, model: LibraryModel) {
        self.mode = mode
        self.model = model
        _name = State(initialValue: mode.initialName)
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                } footer: {
                    Text(GroupNameSheet.explanation)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(GroupNameSheet.canSave(name) == false)
                }
            }
        }
    }

    /// Whether Save does anything.
    ///
    /// Static and pure so it can be tested: the rule is
    /// `AppSettings.DocumentGroups.normalised`, which is the same rule the store
    /// applies, so a name the field accepts is a name that files.
    public static func canSave(_ name: String) -> Bool {
        AppSettings.DocumentGroups.normalised(name) != nil
    }

    private func save() {
        let wanted = name
        dismiss()
        Task {
            switch self.mode {
            case let .create(folderName):
                await self.model.setGroupName(
                    wanted,
                    forFolderName: folderName
                )
            case let .rename(current):
                await self.model.renameGroup(current, to: wanted)
            }
        }
    }
}

#Preview("New Group") {
    GroupNameSheet(
        mode: .create(folderName: "2026-08-18-auth-refactor-plan"),
        model: LibraryModel(environment: PreviewEnvironment(summaries: DocumentSummary.previewSamples))
    )
}

#Preview("Rename Group") {
    GroupNameSheet(
        mode: .rename(current: "Attention Papers"),
        model: LibraryModel(environment: PreviewEnvironment(summaries: DocumentSummary.previewSamples))
    )
}
