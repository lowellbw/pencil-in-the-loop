//
//  ShareViewController.swift
//  ReviewShareExtension
//
//  The "Review" share extension. Its name is pinned by Info.plist, which sets
//  NSExtensionPrincipalClass to $(PRODUCT_MODULE_NAME).ShareViewController.
//
//  ─── THREE TAPS ──────────────────────────────────────────────────────────────
//  docs/07-build-plan.md's definition of done is "a PDF shared from Safari is in
//  the library in under three taps". Share is one, Review is two, and there is
//  no third: this controller starts work the moment it appears, shows what
//  happened, and dismisses itself. There is no title field, no folder picker, no
//  Post button and no confirmation step, and adding one would break the only
//  requirement this unit has.
//
//  The one place a tap is required is failure, where the alert's OK is the
//  user's acknowledgement that nothing was added. That is worth a tap.
//  ─────────────────────────────────────────────────────────────────────────────
//
//  This target links PencilLoopKitCore — Core and Sync — and nothing else. No
//  SwiftUI, no SwiftData, no PDFKit: an extension is killed hard when it exceeds
//  its memory cap, and the whole job here is one file copy.
//

import UIKit

/// Receives a PDF, a text file or a link from the share sheet, writes it into
/// the App Group's `staging/`, and gets out of the way.
///
/// **On failure:** says so in a standard alert and cancels the request, which
/// is what tells the host app the share did not happen. Nothing is ever
/// reported as added that was not written, and nothing partial is left in
/// `staging/` — see `ShareStagingWriter`. The user's document is untouched
/// wherever they shared it from, so a failure costs them a retry and nothing
/// else.
final class ShareViewController: UIViewController {

    /// How long the confirmation stays up before the sheet closes itself.
    private static let confirmationDuration = Duration.milliseconds(900)

    /// The same, when VoiceOver is running and the announcement has to be heard.
    private static let spokenConfirmationDuration = Duration.seconds(2.5)

    private let confirmation = ShareConfirmationView()
    private var hasStarted = false
    private var hasFinished = false

    override func viewDidLoad() {
        super.viewDidLoad()

        // Clear: the host app stays visible behind the card, exactly as it does
        // behind any other system confirmation.
        view.backgroundColor = .clear

        confirmation.translatesAutoresizingMaskIntoConstraints = false
        confirmation.alpha = 0
        view.addSubview(confirmation)

        let width = confirmation.widthAnchor.constraint(equalToConstant: 320)
        width.priority = .defaultHigh

        NSLayoutConstraint.activate([
            confirmation.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            confirmation.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            width,
            confirmation.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32),
            confirmation.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // viewDidAppear can run more than once; the work must not.
        guard hasStarted == false else { return }
        hasStarted = true

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task { [weak self] in
            let outcome = await SharedItemIntake.stage(items, using: ShareStagingWriter())
            self?.show(outcome)
        }
    }

    // MARK: - Outcome

    private func show(_ outcome: ShareOutcome) {
        switch outcome {
        case let .staged(title):
            confirmation.show(title: title)
            UIView.animate(withDuration: 0.2) {
                self.confirmation.alpha = 1
            }
            UIAccessibility.post(notification: .announcement, argument: confirmation.announcement)

            let duration = UIAccessibility.isVoiceOverRunning
                ? ShareViewController.spokenConfirmationDuration
                : ShareViewController.confirmationDuration
            Task { [weak self] in
                try? await Task.sleep(for: duration)
                self?.finish()
            }

        case let .failed(message):
            let alert = UIAlertController(
                title: "Could not add to Review",
                message: message,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.cancel(because: message)
            })
            present(alert, animated: true)
        }
    }

    /// Closes the sheet, reporting success to the host.
    private func finish() {
        guard hasFinished == false else { return }
        hasFinished = true
        extensionContext?.completeRequest(returningItems: [])
    }

    /// Closes the sheet, reporting failure to the host so it does not show its
    /// own success animation over ours.
    private func cancel(because message: String) {
        guard hasFinished == false else { return }
        hasFinished = true
        let domain = Bundle.main.bundleIdentifier ?? "com.example.pencilloop.share"
        extensionContext?.cancelRequest(
            withError: NSError(
                domain: domain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        )
    }
}
