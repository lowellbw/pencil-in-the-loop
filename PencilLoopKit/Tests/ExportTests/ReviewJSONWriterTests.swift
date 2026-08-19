//
//  ReviewJSONWriterTests.swift
//  ExportTests
//
//  `review.json` against contracts/schema/review.schema.json.
//
//  There is no JSON Schema validator on device, so the schema's constraints are
//  asserted one by one against the encoded object graph — required keys, the
//  four-element rect, the two-element range, the `ink/page-NN.png` pattern, the
//  ISO 8601 date. tooling/lint/check_json.py validates the fixture against the
//  schema; this validates our output against the same rules.
//
//  Equality against the fixture is by value, not by bytes: the fixture is
//  hand-formatted with inline arrays and `ContractCoding.encoder()` pretty-prints
//  one element per line. The bytes are allowed to differ; the meaning is not.
//

import XCTest
import Foundation
import Core
@testable import Export

final class ReviewJSONWriterTests: XCTestCase {

    // MARK: - Schema conformance

    func testEveryRequiredTopLevelKeyIsPresent() throws {
        let object = try Self.encodedObject()
        for key in ["documentId", "reviewedAt", "closingInstruction", "comments", "inkPages", "included"] {
            XCTAssertNotNil(object[key], "review.json is missing the required key \(key)")
        }
    }

    func testTheDocumentIdIsTheOneFromMetaJson() throws {
        let object = try Self.encodedObject()
        XCTAssertEqual(object["documentId"] as? String, ExportTestFixtures.externalDocumentId)
    }

    func testTheDateMatchesTheFrozenFormat() throws {
        let object = try Self.encodedObject()
        XCTAssertEqual(object["reviewedAt"] as? String, "2026-08-18T21:14:00Z")
    }

    func testEveryRequiredCommentKeyIsPresent() throws {
        let comments = try Self.commentObjects()
        XCTAssertEqual(comments.count, 2)
        for comment in comments {
            for key in ["id", "index", "text", "source", "anchor"] {
                XCTAssertNotNil(comment[key], "a comment is missing \(key)")
            }
            XCTAssertGreaterThanOrEqual(comment["index"] as? Int ?? 0, 1)
        }
    }

    func testCommentIdsAreShortAndStableWithinTheBundle() throws {
        let comments = try Self.commentObjects()
        XCTAssertEqual(comments.map { $0["id"] as? String }, ["C1", "C2"])
        XCTAssertEqual(comments.map { $0["index"] as? Int }, [1, 2])
    }

    func testTheSourceIsOneOfTheThreeAllowedValues() throws {
        let allowed: Set<String> = ["voice", "handwriting", "typed"]
        for comment in try Self.commentObjects() {
            XCTAssertTrue(allowed.contains(comment["source"] as? String ?? ""))
        }
    }

    func testEveryRequiredAnchorKeyIsPresent() throws {
        for comment in try Self.commentObjects() {
            let anchor = comment["anchor"] as? [String: Any]
            XCTAssertNotNil(anchor)
            for key in ["quoted", "prefix", "suffix", "pageIndex", "normalisedRect"] {
                XCTAssertNotNil(anchor?[key], "an anchor is missing \(key)")
            }
        }
    }

    /// `[x, y, width, height]`, four numbers. Not a keyed CGRect — that is the
    /// whole reason `NormalisedRect` exists.
    func testTheNormalisedRectIsFourNumbers() throws {
        let anchor = try Self.commentObjects()[0]["anchor"] as? [String: Any]
        let rect = anchor?["normalisedRect"] as? [Double]
        XCTAssertEqual(rect?.count, 4)
        XCTAssertEqual(rect?[0] ?? 0, 0.12, accuracy: 0.000_001)
        XCTAssertEqual(rect?[3] ?? 0, 0.04, accuracy: 0.000_001)
    }

    /// `[start, end]`, two integers, half-open UTF-8 byte offsets.
    func testTheSourceRangeIsTwoIntegers() throws {
        let anchor = try Self.commentObjects()[0]["anchor"] as? [String: Any]
        XCTAssertEqual(anchor?["sourceRange"] as? [Int], [1204, 1268])
    }

    /// Omitted, not null: external tools treat a missing key and a null the
    /// same, but the fixtures do not.
    func testAnAbsentSourceRangeIsOmittedRatherThanNulled() throws {
        let anchor = try Self.commentObjects()[1]["anchor"] as? [String: Any]
        XCTAssertNil(anchor?["sourceRange"])
        XCTAssertFalse(anchor?.keys.contains("sourceRange") ?? true)
    }

    func testInkPagePathsMatchTheSchemaPattern() throws {
        let object = try Self.encodedObject(
            inkPages: [
                ReviewInkPage(pageIndex: 0, image: InkImage.fileName(forPageIndex: 0)),
                ReviewInkPage(pageIndex: 11, image: InkImage.fileName(forPageIndex: 11))
            ]
        )
        let pages = object["inkPages"] as? [[String: Any]]
        XCTAssertEqual(pages?.map { $0["image"] as? String }, ["ink/page-01.png", "ink/page-12.png"])
        XCTAssertEqual(pages?.map { $0["pageIndex"] as? Int }, [0, 11])
    }

    func testIncludedCarriesAllFourToggles() throws {
        let object = try Self.encodedObject()
        let included = object["included"] as? [String: Any]
        for key in ["comments", "inkImages", "recognisedText", "fullDocument"] {
            XCTAssertNotNil(included?[key], "included is missing \(key)")
        }
        XCTAssertEqual(included?["fullDocument"] as? Bool, false)
    }

    // MARK: - The fixture, by value

    func testRoundTripsTheFixture() throws {
        let url = ExportTestFixtures.repositoryRoot
            .appendingPathComponent("contracts")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("review.json")
        let original = try ContractCoding.decoder().decode(ReviewBundle.self, from: Data(contentsOf: url))

        let encoded = try ReviewJSONWriter().data(for: original)
        let decoded = try ContractCoding.decoder().decode(ReviewBundle.self, from: encoded)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.comments.first?.anchor.sourceRange, SourceRange(start: 1204, end: 1268))
        XCTAssertEqual(decoded.inkPages.first?.recognisedText, "do we? check the mobile SDK")
    }

    // MARK: - The toggles

    func testCommentsToggledOffProducesAnEmptyArrayNotAMissingKey() throws {
        let draft = ExportTestFixtures.draft(include: ReviewIncludeOptions(comments: false))
        let comments = ReviewJSONWriter().comments(for: draft)
        XCTAssertTrue(comments.isEmpty)

        let object = try Self.encodedObject(draft: draft, comments: comments)
        XCTAssertEqual((object["comments"] as? [Any])?.count, 0)
        XCTAssertNotNil(object["comments"])
    }

    func testInkImagesToggledOffProducesNoInkPages() {
        let draft = ExportTestFixtures.draft(include: ReviewIncludeOptions(inkImages: false))
        let images = [InkImage(pageIndex: 0, relativePath: "ink/page-01.png", pngData: Data([1]))]
        XCTAssertTrue(ReviewJSONWriter().inkPages(for: draft, images: images).isEmpty)
    }

    func testRecognisedTextToggledOffDropsTheKey() {
        let draft = ExportTestFixtures.draft(include: ReviewIncludeOptions(recognisedText: false))
        let images = [
            InkImage(
                pageIndex: 0,
                relativePath: "ink/page-01.png",
                pngData: Data([1]),
                recognisedText: "do we? check the mobile SDK"
            )
        ]
        XCTAssertNil(ReviewJSONWriter().inkPages(for: draft, images: images).first?.recognisedText)
    }

    func testEmptyRecognisedTextIsDroppedRatherThanEmitted() {
        let draft = ExportTestFixtures.draft()
        let images = [
            InkImage(pageIndex: 0, relativePath: "ink/page-01.png", pngData: Data([1]), recognisedText: "")
        ]
        XCTAssertNil(ReviewJSONWriter().inkPages(for: draft, images: images).first?.recognisedText)
    }

    // MARK: - Agreement with review.md

    /// The two halves of the bundle carry the same comments, in the same order,
    /// with the same numbering. That is a stated contract, not a coincidence.
    func testTheNumberingMatchesTheMarkdownHeadings() {
        let draft = ExportTestFixtures.draft()
        let comments = ReviewJSONWriter().comments(for: draft)
        let markdown = ExportTestFixtures.markdownWriter().markdown(for: draft, comments: comments)

        for comment in comments {
            XCTAssertTrue(
                markdown.contains("### \(comment.index) \u{2014} page \(comment.anchor.pageIndex + 1)"),
                "review.json numbers a comment review.md does not"
            )
        }
    }

    func testResolvedAnchorsOverrideTheCapturedOnes() {
        let draft = ExportTestFixtures.draft()
        let moved = SourceRange(start: 42, end: 99)
        var anchor = ExportTestFixtures.firstComment().anchor
        anchor.sourceRange = moved

        let comments = ReviewJSONWriter().comments(
            for: draft,
            anchors: [ExportTestFixtures.firstComment().id: anchor]
        )
        XCTAssertEqual(comments[0].anchor.sourceRange, moved)
        XCTAssertEqual(comments[1].anchor.sourceRange, ExportTestFixtures.secondComment().anchor.sourceRange)
    }

    // MARK: - Support

    static func encodedObject(
        draft: ReviewDraft = ExportTestFixtures.draft(),
        comments: [ReviewComment]? = nil,
        inkPages: [ReviewInkPage] = ExportTestFixtures.inkPages()
    ) throws -> [String: Any] {
        let writer = ReviewJSONWriter()
        let bundle = writer.bundle(
            for: draft,
            comments: comments ?? writer.comments(for: draft),
            inkPages: inkPages
        )
        let data = try writer.data(for: bundle)
        let parsed = try JSONSerialization.jsonObject(with: data)
        return parsed as? [String: Any] ?? [:]
    }

    static func commentObjects() throws -> [[String: Any]] {
        (try encodedObject()["comments"] as? [[String: Any]]) ?? []
    }
}
