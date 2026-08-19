//
//  CommentScribbleField.swift
//  AppUI · Comment · Views
//
//  The silent alternative (docs/02-spec.md § S3, docs/04-flows.md § F4).
//

import SwiftUI
import UIKit

/// A plain `UITextView`, which on iPadOS *is* a Scribble field.
///
/// There is no Scribble API to adopt and nothing to switch on: any system text
/// input view accepts handwriting from an Apple Pencil, converts it on device,
/// and shows the scratch-to-delete and insert gestures for free. Writing our
/// own would mean losing all of that, so this wrapper's whole job is to be an
/// ordinary text view that reports what it holds.
///
/// It deliberately does **not** call `becomeFirstResponder()`. Focusing it
/// raises the software keyboard, and this field exists precisely for the case
/// where the user has a Pencil in their hand and does not want one. Writing on
/// it focuses it.
///
/// **On failure:** there is no failure. On a device with no Pencil paired this
/// is a text view and the user types into it, which is a supported way to write
/// a comment.
public struct CommentScribbleField: UIViewRepresentable {

    /// What has been written so far.
    @Binding public var text: String

    /// Shown in secondary colour while `text` is empty. `UITextView` has no
    /// placeholder of its own, so it is drawn as a subview and hidden on the
    /// first character.
    public var placeholder: String

    public init(text: Binding<String>, placeholder: String) {
        self._text = text
        self.placeholder = placeholder
    }

    public func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = true
        view.alwaysBounceVertical = false
        view.autocorrectionType = .yes
        view.accessibilityLabel = placeholder

        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.text = placeholder
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            label.topAnchor.constraint(equalTo: view.topAnchor)
        ])
        context.coordinator.placeholderLabel = label
        return view
    }

    public func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text {
            view.text = text
        }
        context.coordinator.placeholderLabel?.isHidden = !text.isEmpty
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    /// Reports edits back into the binding.
    public final class Coordinator: NSObject, UITextViewDelegate {

        /// Held so the placeholder can be hidden on the first character.
        public var placeholderLabel: UILabel?

        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        public func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text ?? ""
            placeholderLabel?.isHidden = !(textView.text ?? "").isEmpty
        }
    }
}

#Preview("Empty") {
    CommentScribbleField(text: .constant(""), placeholder: "Write your comment")
        .frame(width: 300, height: 90)
        .padding()
}

#Preview("Written in") {
    CommentScribbleField(
        text: .constant("Shadow read for a day before the cutover."),
        placeholder: "Write your comment"
    )
    .frame(width: 300, height: 90)
    .padding()
}
