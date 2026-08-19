//
//  MarkdownTypographyTests.swift
//  IngestTests
//
//  The page is designed for annotation, not density (docs/03-architecture.md
//  § 1). These pin the two numbers that promise it.
//

import XCTest
import UIKit
import Core
@testable import Ingest

final class MarkdownTypographyTests: XCTestCase {

    private let geometry = PageGeometry.annotationFriendly

    func testTheRightMarginIsWideEnoughToWriteIn() {
        // The whole point of the geometry: marginalia has somewhere to live.
        XCTAssertTrue(geometry.marginRight > geometry.marginLeft * 2)
        XCTAssertTrue(geometry.textColumnWidth > 300)
        XCTAssertTrue(geometry.textColumnWidth < geometry.pageWidth * 0.75)
    }

    func testCodeNeverExceedsTheTextColumn() {
        let typography = MarkdownTypography(geometry: geometry)
        let line = String(repeating: "M", count: geometry.maxCodeColumnCharacters)
        let width = NSAttributedString(
            string: line,
            attributes: [.font: typography.codeFont]
        ).size().width

        XCTAssertTrue(
            Double(width) <= geometry.textColumnWidth + 0.5,
            "\(geometry.maxCodeColumnCharacters) code characters measure \(width)pt "
                + "in a \(geometry.textColumnWidth)pt column"
        )
    }

    func testCodeIsNotShrunkWhenItAlreadyFits() {
        var roomy = geometry
        roomy.maxCodeColumnCharacters = 20
        let typography = MarkdownTypography(geometry: roomy)
        XCTAssertEqual(typography.codePointSize, roomy.bodyPointSize - 1, accuracy: 0.001)
    }

    func testLeadingIsGenerous() {
        let typography = MarkdownTypography(geometry: geometry)
        XCTAssertTrue(typography.bodyLineHeight > Double(typography.bodyFont.lineHeight))
        XCTAssertTrue(typography.bodyLineHeight > geometry.bodyPointSize * 1.4)
    }

    func testHeadingsDescendInSize() {
        let typography = MarkdownTypography(geometry: geometry)
        let sizes = (1 ... 6).map { Double(typography.headingFont(level: $0).pointSize) }
        for index in 1 ..< sizes.count {
            XCTAssertTrue(sizes[index] <= sizes[index - 1])
        }
        XCTAssertTrue(sizes[0] > geometry.bodyPointSize)
        XCTAssertEqual(
            Double(typography.headingFont(level: 99).pointSize),
            sizes[5],
            accuracy: 0.001
        )
    }

    func testInlineCodeUsesTheMonospacedFaceWhateverTheRole() {
        let typography = MarkdownTypography(geometry: geometry)
        let attributes = typography.attributes(for: .body, inline: [.code])
        XCTAssertEqual(attributes[.font] as? UIFont, typography.codeFont)
    }
}
