//
//  MarkdownTypography.swift
//  Ingest · Rendering
//
//  Fonts, colours and paragraph styles for the rendered page, all derived from
//  `PageGeometry` so that the ink cropper and the source map cannot disagree
//  with the renderer about how big anything is (DTOs.swift § PageGeometry).
//
//  The page is designed for annotation, not density (docs/03-architecture.md
//  § 1): 11pt body, 1.35 leading, and a right margin wide enough to write in.
//  Point sizes are hardcoded here and only here — docs/01-design-principles.md
//  § 1 bans fixed sizes in *app chrome*, where Dynamic Type must win. A rendered
//  page is the opposite case: its metrics are frozen at ingest precisely so ink
//  laid over it can never drift.
//

import Foundation
import UIKit
import Core

/// Type metrics for one rendered document.
struct MarkdownTypography {

    /// What a stretch of text is, for the purpose of styling it.
    enum Role {
        case body
        case heading(level: Int)
        case code
        case quote
        case tableHeader
        case tableCell
        /// A list bullet or number. Synthetic text, styled like body.
        case marker
    }

    let geometry: PageGeometry

    /// Monospaced size chosen so `geometry.maxCodeColumnCharacters` fit the
    /// text column without wrapping.
    ///
    /// `PageGeometry.annotationFriendly` promises both a 140pt right margin and
    /// 76-character code lines, and those two numbers do not both fit at 10pt.
    /// Rather than break either promise silently, the code size is measured down
    /// until the wider one holds — see the report accompanying this unit.
    let codePointSize: Double

    init(geometry: PageGeometry) {
        self.geometry = geometry
        self.codePointSize = MarkdownTypography.codeSize(for: geometry)
    }

    // MARK: - Fonts

    var bodyFont: UIFont { UIFont.systemFont(ofSize: geometry.bodyPointSize) }

    var codeFont: UIFont { UIFont.monospacedSystemFont(ofSize: codePointSize, weight: .regular) }

    func headingFont(level: Int) -> UIFont {
        let clamped = min(max(level, 1), 6)
        let scale = [1.85, 1.45, 1.22, 1.10, 1.02, 1.0][clamped - 1]
        return UIFont.systemFont(
            ofSize: geometry.bodyPointSize * scale,
            weight: clamped <= 2 ? .bold : .semibold
        )
    }

    /// One body line, leading included. The unit the layout uses for "is there
    /// room for anything useful here".
    var bodyLineHeight: Double {
        Double(bodyFont.lineHeight) * geometry.lineSpacingMultiple
    }

    // MARK: - Attributes

    /// Attributes for one run of text. The caller adds the source span.
    func attributes(for role: Role, inline: InlineAttributes = []) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        attributes[.font] = font(for: role, inline: inline)
        attributes[.foregroundColor] = tint(for: role, inline: inline)
        if inline.contains(.strikethrough) {
            attributes[.strikethroughStyle] = 1
        }
        if inline.contains(.link) {
            attributes[.underlineStyle] = 1
        }
        return attributes
    }

    /// Paragraph style for a block.
    ///
    /// - Parameter hangingIndent: how far continuation lines are pushed in, so
    ///   a wrapped bullet lines up under its own text rather than under its
    ///   marker.
    func paragraphStyle(for role: Role, hangingIndent: Double = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.headIndent = hangingIndent
        style.firstLineHeadIndent = 0
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        style.hyphenationFactor = 0
        switch role {
        case .code:
            // Code is laid out verbatim (MarkdownIR.swift § codeBlock). A line
            // longer than the column is not re-flowed as prose; it breaks at the
            // column edge and continues, which keeps every character on the page
            // when the authoring guidance in docs/06-integrations.md was not
            // followed.
            style.lineHeightMultiple = 1.15
            style.lineBreakMode = .byCharWrapping
        case .heading:
            style.lineHeightMultiple = 1.12
            style.lineBreakMode = .byWordWrapping
        case .tableHeader, .tableCell:
            style.lineHeightMultiple = 1.15
            style.lineBreakMode = .byWordWrapping
        case .body, .quote, .marker:
            style.lineHeightMultiple = geometry.lineSpacingMultiple
            style.lineBreakMode = .byWordWrapping
        }
        return style
    }

    // MARK: - Private

    private func font(for role: Role, inline: InlineAttributes) -> UIFont {
        if inline.contains(.code) { return codeFont }
        switch role {
        case .code:
            return codeFont
        case let .heading(level):
            return traits(on: headingFont(level: level), inline: inline)
        case .tableHeader:
            return UIFont.systemFont(ofSize: geometry.bodyPointSize - 0.5, weight: .semibold)
        case .tableCell:
            return traits(on: UIFont.systemFont(ofSize: geometry.bodyPointSize - 0.5), inline: inline)
        case .body, .quote, .marker:
            return traits(on: bodyFont, inline: inline)
        }
    }

    private func traits(on base: UIFont, inline: InlineAttributes) -> UIFont {
        var symbolic = base.fontDescriptor.symbolicTraits
        if inline.contains(.emphasis) { symbolic.insert(.traitItalic) }
        if inline.contains(.strong) { symbolic.insert(.traitBold) }
        guard symbolic != base.fontDescriptor.symbolicTraits,
              let descriptor = base.fontDescriptor.withSymbolicTraits(symbolic) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    /// Fixed ink, not system colours: the page is tinted at reading time
    /// (docs/01-design-principles.md § 9), so it is rendered black on white and
    /// never inverted.
    private func tint(for role: Role, inline: InlineAttributes) -> UIColor {
        if inline.contains(.link) { return UIColor(red: 0.0, green: 0.28, blue: 0.62, alpha: 1) }
        switch role {
        case .quote:
            return UIColor(white: 0.28, alpha: 1)
        case .code:
            return UIColor(white: 0.14, alpha: 1)
        case .marker:
            return UIColor(white: 0.35, alpha: 1)
        case .body, .heading, .tableHeader, .tableCell:
            return UIColor(white: 0.06, alpha: 1)
        }
    }

    /// Measures the monospaced advance rather than assuming one, then shrinks
    /// until the promised character count fits the column.
    private static func codeSize(for geometry: PageGeometry) -> Double {
        let base = max(geometry.bodyPointSize - 1, 6)
        guard geometry.maxCodeColumnCharacters > 0, geometry.textColumnWidth > 0 else { return base }
        let probe = UIFont.monospacedSystemFont(ofSize: base, weight: .regular)
        let advance = Double(NSAttributedString(string: "0", attributes: [.font: probe]).size().width)
        guard advance > 0 else { return base }
        let needed = advance * Double(geometry.maxCodeColumnCharacters)
        guard needed > geometry.textColumnWidth else { return base }
        return max(base * geometry.textColumnWidth / needed, 6.5)
    }
}
