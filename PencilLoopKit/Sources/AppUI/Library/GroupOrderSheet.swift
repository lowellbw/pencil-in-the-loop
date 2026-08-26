//
//  GroupOrderSheet.swift
//  AppUI · Library
//
//  Putting the group sections in the order you want them (docs/02-spec.md § S1).
//
//  A sheet rather than dragging the headings in the sidebar, and not for want of
//  trying: a SwiftUI `List` reorders rows within a `ForEach`, and a `Section` is
//  not a row. There is no in-place gesture to attach this to.
//
//  It is also the calmer answer. Reordering groups is something you do once,
//  when a project starts mattering more than an old one, and a screen you can
//  see all of beats hunting section headings down a scrolling sidebar.
//

import SwiftUI
import Core

/// The sheet that reorders the Library's group sections.
public struct GroupOrderSheet: View {

    private static let explanation = """
        Groups you have not placed follow the ones you have, in alphabetical order. \
        Ungrouped always comes last.
        """

    private let model: LibraryModel

    @Environment(\.dismiss) private var dismiss

    /// The working order. Held locally so a drag reads back instantly and the
    /// write happens once, on Done, rather than on every frame of the gesture.
    @State private var names: [String]

    public init(model: LibraryModel) {
        self.model = model
        _names = State(initialValue: model.groupNames)
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(names, id: \.self) { name in
                        Text(name)
                    }
                    .onMove { source, destination in
                        names.move(fromOffsets: source, toOffset: destination)
                    }
                } footer: {
                    Text(GroupOrderSheet.explanation)
                }
            }
            .listStyle(.insetGrouped)
            // Always editing. The sheet exists to do one thing, so an Edit
            // button to enter the mode that does it would be a tap that only
            // ever has one answer.
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Groups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                }
            }
            .overlay {
                if names.isEmpty {
                    Text("No groups")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func save() {
        let wanted = names
        dismiss()
        Task { await self.model.moveGroups(to: wanted) }
    }
}

#Preview("Reorder Groups") {
    GroupOrderSheet(
        model: LibraryModel(
            environment: PreviewEnvironment(
                summaries: DocumentSummary.previewSamples,
                settings: .previewGrouped
            )
        )
    )
}
