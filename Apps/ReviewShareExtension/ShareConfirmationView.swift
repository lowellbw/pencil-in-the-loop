//
//  ShareConfirmationView.swift
//  ReviewShareExtension
//
//  The whole user interface of this extension: a material card, an SF Symbol,
//  two lines of system type, and then it goes away on its own.
//
//  docs/01-design-principles.md applies here as much as anywhere — system
//  everything, nothing branded, no animation that is not a system transition.
//  The glyph is drawn in `.label` rather than the accent colour on purpose:
//  rule 2 gives the accent to interactive text and the send button and nothing
//  else, and a confirmation that has already happened is not interactive.
//

import UIKit

/// "Added to Review", with the title of what was added underneath.
///
/// **Never fails.** A missing SF Symbol leaves the glyph blank and the words
/// still say what happened; there is nothing here that can go wrong in a way
/// worth reporting.
final class ShareConfirmationView: UIView {

    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let glyph = UIImageView(image: UIImage(systemName: "checkmark.circle"))
    private let headline = UILabel()
    private let subtitle = UILabel()

    /// What VoiceOver is told when this appears.
    private(set) var announcement = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        // This view is never in a nib; the extension has no storyboard.
        return nil
    }

    /// Fills in the document title and the accessibility label.
    func show(title: String) {
        subtitle.text = title
        subtitle.isHidden = title.isEmpty
        announcement = title.isEmpty ? headlineText : "\(headlineText). \(title)"
        accessibilityLabel = announcement
    }

    // MARK: - Internals

    private var headlineText: String { headline.text ?? "" }

    private func build() {
        isAccessibilityElement = true
        accessibilityTraits = .staticText

        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        addSubview(card)

        glyph.tintColor = .label
        glyph.contentMode = .scaleAspectFit
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .largeTitle)
        glyph.isAccessibilityElement = false

        headline.text = "Added to Review"
        headline.font = .preferredFont(forTextStyle: .headline)
        headline.adjustsFontForContentSizeCategory = true
        headline.textColor = .label
        headline.textAlignment = .center
        headline.numberOfLines = 0

        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.adjustsFontForContentSizeCategory = true
        subtitle.textColor = .secondaryLabel
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 2
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.isHidden = true

        let stack = UIStackView(arrangedSubviews: [glyph, headline, subtitle])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.setCustomSpacing(14, after: glyph)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -28),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -24)
        ])
    }
}
