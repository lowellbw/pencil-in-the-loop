//
//  SyncServerForm.swift
//  AppUI · Settings
//
//  Two fields and a button. Shared by first run and Settings so that the only
//  place in the app where a relay address is typed is this one — the folder
//  path learned that lesson through `SyncFolderChoice`, and the same reasoning
//  applies to a form.
//
//  There is deliberately no account here, no sign-up and no logo. A relay is
//  reached with an address and a token, which is two text fields, and
//  docs/01-design-principles.md § 6 forbids inventing anything more ceremonious
//  than the thing actually requires.
//

import SwiftUI
import Core

/// The address and token of a relay.
///
/// **On failure:** the reason appears under the button in secondary text and
/// the fields keep what was typed, because everything that can go wrong here is
/// something the user can correct — a typo in the address, a token pasted with
/// half of it missing — and clearing the field would make them start again.
public struct SyncServerForm: View {

    @Binding private var urlText: String
    @Binding private var token: String

    private let isBusy: Bool
    private let problem: String?
    private let onConnect: () -> Void

    public init(
        urlText: Binding<String>,
        token: Binding<String>,
        isBusy: Bool = false,
        problem: String? = nil,
        onConnect: @escaping () -> Void
    ) {
        _urlText = urlText
        _token = token
        self.isBusy = isBusy
        self.problem = problem
        self.onConnect = onConnect
    }

    public var body: some View {
        Section {
            TextField("https://your-relay.example.com", text: $urlText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Relay address")

            // Secure, because it is a credential and because a token on screen
            // is a token in a screenshot.
            SecureField("Access token", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Relay access token")

            Button(isBusy ? "Connecting…" : "Connect") {
                onConnect()
            }
            .disabled(isBusy || urlText.isEmpty || token.isEmpty)
        } header: {
            Text("Server")
        } footer: {
            if let problem {
                Text(problem)
                    .foregroundStyle(.secondary)
            } else {
                Text(SyncServerForm.explanation)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What the form is for, in one sentence, without overselling it.
    ///
    /// It says "instead of a folder" rather than "better than a folder" because
    /// the folder needs no network and nobody's uptime, and remains the path
    /// this app was designed around.
    static let explanation = """
        Documents can arrive from a relay instead of a shared folder, which means \
        no computer has to be awake. The address and token come from the relay \
        when you set it up.
        """
}

#Preview("Server form") {
    Form {
        SyncServerForm(
            urlText: .constant("https://relay.example.com"),
            token: .constant("a-token"),
            onConnect: {}
        )
    }
}

#Preview("Server form, refused") {
    Form {
        SyncServerForm(
            urlText: .constant("http://relay.example.com"),
            token: .constant(""),
            problem: PencilLoopError.folderUnavailable(
                reason: "The address has to start with https, so what you send is encrypted on the way."
            ).message,
            onConnect: {}
        )
    }
}
