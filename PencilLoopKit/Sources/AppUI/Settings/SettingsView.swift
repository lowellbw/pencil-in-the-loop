//
//  SettingsView.swift
//  AppUI · Settings
//
//  S6. Deliberately short (docs/02-spec.md § S6): sync folder, ink defaults,
//  transcription language, the inked-pages default, and storage. Plus the one
//  speech row docs/03-architecture.md § 4 asks for. Nothing else — the spec
//  means "nothing else" literally, and one row has since left: the page tint
//  is chosen on the page it tints.
//

import SwiftUI
import UIKit
import Core
import Annotate

/// The settings sheet.
///
/// Presented from the library toolbar. An inset-grouped `List`, a `Done`
/// button, and no Save button anywhere: every row writes through as it changes
/// (docs/02-spec.md § Cross-cutting).
///
/// **On failure:** a write that throws leaves the row where the user put it and
/// explains itself in the footer. Nothing here can fail in a way that stops the
/// app reading documents.
public struct SettingsView: View {

    @State private var model: SettingsModel
    @State private var serverURLText = ""
    @State private var serverToken = ""
    @State private var isConfirmingPurge = false

    @Environment(\.dismiss) private var dismiss

    /// - Parameter environment: every dependency the rows read or write, the
    ///   `folderAccess` that prepares a newly chosen folder included.
    public init(environment: any AppEnvironment) {
        _model = State(initialValue: SettingsModel(environment: environment))
    }

    public var body: some View {
        NavigationStack {
            List {
                folderSection
                inkSection
                dictationSection
                reviewSection
                storageSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await model.load()
            }
        }
    }

    // MARK: - Sections

    /// Where documents come from. One section for both transports, because
    /// they are alternatives rather than features, and a person should be able
    /// to see which one is in force without hunting.
    @ViewBuilder
    private var folderSection: some View {
        Section("Sync") {
            ValueRow(
                title: "Relay",
                value: model.settings.serverDisplayName ?? "Not connected"
            )
        }

        SyncServerForm(
            urlText: $serverURLText,
            token: $serverToken,
            isBusy: model.isConnectingToServer,
            problem: model.statusMessage,
            onConnect: {
                Task {
                    await model.adoptServer(urlText: serverURLText, token: serverToken)
                    // Never keep a credential in view state a moment longer
                    // than the request needs it.
                    serverToken = ""
                }
            }
        )
    }
    // The page tint is not here any more. It is on the page it tints
    // (`ReaderView.pageMenu`), which is the only screen where the difference
    // between Cream and Sepia can be seen while it is being chosen. It is still
    // one setting for the whole app; it is only chosen somewhere better.

    private var inkSection: some View {
        Section("Ink") {
            Picker("Tool", selection: binding(\.ink.tool)) {
                ForEach(InkToolKind.allCases, id: \.self) { tool in
                    Text(tool.displayName).tag(tool)
                }
            }
            Picker("Ink", selection: inkTint) {
                ForEach(InkPalette.allCases, id: \.self) { palette in
                    Label {
                        Text(palette.displayName)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(Color(uiColor: palette.uiTint))
                    }
                    .tag(palette)
                }
            }
            Stepper(value: binding(\.ink.widthPoints), in: 1...12, step: 0.5) {
                ValueRow(title: "Width", value: model.settings.ink.widthPoints.formatted() + " pt")
            }
        }
    }

    private var dictationSection: some View {
        Section("Dictation") {
            Picker("Language", selection: binding(\.transcriptionLocaleIdentifier)) {
                ForEach(model.languageIdentifiers, id: \.self) { identifier in
                    Text(SettingsView.languageName(identifier)).tag(identifier)
                }
            }
            if let line = model.speechAssetLine {
                HStack {
                    Text(line)
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    if model.isDownloadingSpeechAssets {
                        ProgressView()
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(line)
            }
        }
    }

    private var reviewSection: some View {
        Section("Reviews") {
            Toggle("Send inked pages as images", isOn: binding(\.sendInkedPagesAsImages))
        }
    }

    private var storageSection: some View {
        Section {
            ValueRow(title: "Documents", value: model.storageBytes.formatted(.byteCount(style: .file)))
            Button("Purge Archived…") {
                isConfirmingPurge = true
            }
            .confirmationDialog(
                "Delete archived documents and their files?",
                isPresented: $isConfirmingPurge,
                titleVisibility: .visible
            ) {
                Button("Delete Archived", role: .destructive) {
                    Task { await self.model.purge() }
                }
                Button("Cancel", role: .cancel) {}
            }
        } header: {
            Text("Storage")
        } footer: {
            if let status = model.statusMessage {
                Text(status)
            }
        }
    }

    // MARK: - Bindings

    /// One row's worth of `AppSettings`, written through on change.
    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.model.settings[keyPath: keyPath] },
            set: { updated in
                self.model.change { settings in
                    settings[keyPath: keyPath] = updated
                }
            }
        )
    }

    /// The ink colour, stored as the hex `InkDefaults` persists and offered as
    /// the five named inks (docs/01-design-principles.md § Specific choices).
    /// A hex the palette does not know — the user picked something else in the
    /// tool picker, which they are allowed to do — reads back as graphite.
    private var inkTint: Binding<InkPalette> {
        Binding(
            get: { InkPalette.palette(forHex: self.model.settings.ink.tintHex) ?? .standard },
            set: { palette in
                self.model.change { settings in
                    settings.ink.tintHex = palette.tintHex
                }
            }
        )
    }

    // MARK: - Language list

    /// The engine's own list of languages, asked for when the screen appears
    /// (`SettingsModel.languageIdentifiers`). It used to be fourteen BCP-47
    /// identifiers hardcoded here, which offered languages the engine could not
    /// transcribe and hid ones it could.
    private static func languageName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    // MARK: - Rows

    /// A label and its value. One line normally; two at accessibility text
    /// sizes, where a trailing value would otherwise be squeezed to nothing
    /// (docs/01-design-principles.md § 8).
    private struct ValueRow: View {

        let title: String
        let value: String

        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        var body: some View {
            layout
                .accessibilityElement(children: .combine)
                .accessibilityLabel(title + ", " + value)
        }

        @ViewBuilder private var layout: some View {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                    Text(value)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text(title)
                        .font(.body)
                    Spacer(minLength: 12)
                    Text(value)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview("Settings") {
    SettingsView(
        environment: PreviewEnvironment(
            settings: AppSettings(
                syncFolderDisplayName: "PencilLoop",
                hasCompletedFirstRun: true
            )
        )
    )
}

#Preview("Speech assets downloading") {
    SettingsView(
        environment: PreviewEnvironment(
            speechAssetState: .downloading(progress: 0.4),
            settings: AppSettings(
                syncFolderDisplayName: "PencilLoop",
                hasCompletedFirstRun: true
            )
        )
    )
}
