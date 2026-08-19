//
//  AnchorCodingTests.swift
//  CoreTests
//
//  The anchor and review.json shapes, checked against the example in
//  docs/05-file-contracts.md. The JSON below is transcribed from that document;
//  contracts/fixtures/review.json holds the same bytes and
//  tooling/lint/check_json.py keeps it honest.
//

import XCTest
import Core

final class AnchorCodingTests: XCTestCase {

    private let anchorJSON = """
    {
      "quoted": "The migration runs in a single deploy, with no dual-write window.",
      "prefix": "…refresh token stored in the keychain. ",
      "suffix": " Rollout is gated behind auth_v2…",
      "pageIndex": 0,
      "normalisedRect": [0.12, 0.34, 0.76, 0.04],
      "sourceRange": [1204, 1268]
    }
    """

    func testDecodesTheSpecExample() throws {
        let anchor = try ContractCoding.decoder().decode(Anchor.self, from: Data(anchorJSON.utf8))
        XCTAssertEqual(anchor.quoted, "The migration runs in a single deploy, with no dual-write window.")
        XCTAssertEqual(anchor.pageIndex, 0)
        XCTAssertEqual(anchor.normalisedRect.width, 0.76, accuracy: 1e-12)
        XCTAssertEqual(anchor.sourceRange, SourceRange(start: 1204, end: 1268))
    }

    func testEncodesTheKeysTheSpecNames() throws {
        let anchor = try ContractCoding.decoder().decode(Anchor.self, from: Data(anchorJSON.utf8))
        let json = String(decoding: try ContractCoding.encoder().encode(anchor), as: UTF8.self)
        for key in ["quoted", "prefix", "suffix", "pageIndex", "normalisedRect", "sourceRange"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "missing key \(key)")
        }
        XCTAssertFalse(json.contains("normalizedRect"), "American spelling in the on-disk contract")
    }

    func testSourceRangeIsOmittedRatherThanNull() throws {
        let anchor = Anchor(
            quoted: "a passage",
            prefix: "before ",
            suffix: " after",
            pageIndex: 2,
            normalisedRect: NormalisedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
            sourceRange: nil
        )
        let json = String(decoding: try ContractCoding.encoder().encode(anchor), as: UTF8.self)
        XCTAssertFalse(json.contains("sourceRange"))
        XCTAssertFalse(json.contains("null"))
    }

    func testAnchorWithOnlyAQuoteStillDecodes() throws {
        let json = Data(#"{"quoted":"a passage"}"#.utf8)
        let anchor = try ContractCoding.decoder().decode(Anchor.self, from: json)
        XCTAssertEqual(anchor.quoted, "a passage")
        XCTAssertEqual(anchor.prefix, "")
        XCTAssertEqual(anchor.pageIndex, 0)
        XCTAssertEqual(anchor.normalisedRect, .zero)
        XCTAssertNil(anchor.sourceRange)
    }

    func testAnchorWithoutAQuoteThrows() {
        let json = Data(#"{"pageIndex":1}"#.utf8)
        XCTAssertThrowsError(try ContractCoding.decoder().decode(Anchor.self, from: json))
    }

    func testExcerptCollapsesWhitespaceAndTruncates() {
        let anchor = Anchor(
            quoted: "The migration runs\n  in a single deploy, with no dual-write window.",
            pageIndex: 0,
            normalisedRect: .zero
        )
        XCTAssertEqual(
            anchor.excerpt(maxLength: 200),
            "The migration runs in a single deploy, with no dual-write window."
        )
        XCTAssertTrue(anchor.excerpt(maxLength: 20).hasSuffix("…"))
        XCTAssertEqual(anchor.excerpt(maxLength: 20).count, 21)
    }

    func testContextualQuoteIsPrefixQuoteSuffix() {
        let anchor = Anchor(quoted: "b", prefix: "a", suffix: "c", pageIndex: 0, normalisedRect: .zero)
        XCTAssertEqual(anchor.contextualQuote, "abc")
    }

    // MARK: - review.json

    func testReviewBundleRoundTripsWithTheSpecKeys() throws {
        let bundle = ReviewBundle(
            documentId: "F7A1",
            reviewedAt: Date(timeIntervalSince1970: 1_787_005_240),
            closingInstruction: "Rework phase 2 with the shadow read.",
            comments: [
                ReviewComment(
                    id: ReviewComment.identifier(forIndex: 1),
                    index: 1,
                    text: "No dual-write window means we can't roll back.",
                    source: .voice,
                    anchor: try ContractCoding.decoder().decode(Anchor.self, from: Data(anchorJSON.utf8))
                )
            ],
            inkPages: [
                ReviewInkPage(
                    pageIndex: 0,
                    image: InkImage.fileName(forPageIndex: 0),
                    recognisedText: "do we? check the mobile SDK"
                )
            ],
            included: .standard
        )

        let data = try ContractCoding.encoder().encode(bundle)
        let json = String(decoding: data, as: UTF8.self)
        for key in [
            "documentId", "reviewedAt", "closingInstruction", "comments",
            "inkPages", "included", "recognisedText", "inkImages", "fullDocument"
        ] {
            XCTAssertTrue(json.contains("\"\(key)\""), "missing key \(key)")
        }
        XCTAssertTrue(json.contains("ink/page-01.png"))

        let decoded = try ContractCoding.decoder().decode(ReviewBundle.self, from: data)
        XCTAssertEqual(decoded, bundle)
    }

    func testInkFileNamesAreOneBasedAndPadded() {
        XCTAssertEqual(InkImage.fileName(forPageIndex: 0), "ink/page-01.png")
        XCTAssertEqual(InkImage.fileName(forPageIndex: 2), "ink/page-03.png")
        XCTAssertEqual(InkImage.fileName(forPageIndex: 11), "ink/page-12.png")
        XCTAssertEqual(InkImage.fileName(forPageIndex: 99), "ink/page-100.png")
    }

    func testIncludeDefaultsMatchTheSpec() {
        let options = ReviewIncludeOptions.standard
        XCTAssertTrue(options.comments)
        XCTAssertTrue(options.inkImages)
        XCTAssertTrue(options.recognisedText)
        XCTAssertFalse(options.fullDocument)
    }

    func testReviewDirectoryNaming() {
        XCTAssertEqual(
            OutboxPayload.directoryName(forDocumentFolder: "2026-08-18-auth-refactor-plan"),
            "2026-08-18-auth-refactor-plan.review"
        )
    }
}
