//
//  NormalisedRectTests.swift
//  CoreTests
//
//  These cannot run here — there is no Swift toolchain in this container. They
//  run on the Mac, and writing them is what forces the API to be usable before
//  five other units depend on it.
//

import XCTest
import Core

final class NormalisedRectTests: XCTestCase {

    // MARK: - The on-disk shape

    /// review.json says `"normalisedRect": [0.12, 0.34, 0.76, 0.04]`. Four
    /// numbers, in that order, not an object. This is the test that fails if
    /// someone reaches for CGRect.
    func testEncodesAsFourElementArray() throws {
        let rect = NormalisedRect(x: 0.12, y: 0.34, width: 0.76, height: 0.04)
        let data = try JSONEncoder().encode(rect)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(json, "[0.12,0.34,0.76,0.04]")
    }

    func testDecodesFromFourElementArray() throws {
        let json = Data("[0.12, 0.34, 0.76, 0.04]".utf8)
        let rect = try JSONDecoder().decode(NormalisedRect.self, from: json)
        XCTAssertEqual(rect.x, 0.12, accuracy: 1e-12)
        XCTAssertEqual(rect.y, 0.34, accuracy: 1e-12)
        XCTAssertEqual(rect.width, 0.76, accuracy: 1e-12)
        XCTAssertEqual(rect.height, 0.04, accuracy: 1e-12)
    }

    func testRoundTrips() throws {
        let original = NormalisedRect(x: 0.5, y: 0.25, width: 0.125, height: 0.0625)
        let data = try ContractCoding.encoder().encode(original)
        let decoded = try ContractCoding.decoder().decode(NormalisedRect.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testDecodingATooShortArrayThrows() {
        let json = Data("[0.1, 0.2, 0.3]".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(NormalisedRect.self, from: json))
    }

    func testDecodingAKeyedObjectThrows() {
        // The CGRect coding shape, which is exactly what we are refusing.
        let json = Data(#"{"origin":{"x":0,"y":0},"size":{"width":1,"height":1}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(NormalisedRect.self, from: json))
    }

    // MARK: - Geometry

    func testUnionCoversBothRects() {
        let left = NormalisedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let right = NormalisedRect(x: 0.5, y: 0.4, width: 0.1, height: 0.1)
        let union = left.union(right)
        XCTAssertEqual(union.x, 0.1, accuracy: 1e-12)
        XCTAssertEqual(union.y, 0.1, accuracy: 1e-12)
        XCTAssertEqual(union.maxX, 0.6, accuracy: 1e-12)
        XCTAssertEqual(union.maxY, 0.5, accuracy: 1e-12)
    }

    /// The ink cropper reduces over stroke bounds starting from `.zero`, so a
    /// zero rect must behave as "nothing" rather than as a point at the origin.
    func testUnionTreatsZeroAsEmpty() {
        let rect = NormalisedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        XCTAssertEqual(NormalisedRect.zero.union(rect), rect)
        XCTAssertEqual(rect.union(.zero), rect)
        let reduced = [rect].reduce(NormalisedRect.zero) { $0.union($1) }
        XCTAssertEqual(reduced, rect)
    }

    /// The cropper's actual call: 15% padding on every side.
    func testInsetByNegativeFractionPads() {
        let rect = NormalisedRect(x: 0.2, y: 0.2, width: 0.4, height: 0.2)
        let padded = rect.insetBy(fraction: -0.15)
        XCTAssertEqual(padded.x, 0.2 - 0.4 * 0.15, accuracy: 1e-12)
        XCTAssertEqual(padded.width, 0.4 * 1.3, accuracy: 1e-12)
        XCTAssertEqual(padded.height, 0.2 * 1.3, accuracy: 1e-12)
    }

    func testClampedTrimsToTheUnitSquare() {
        let overhanging = NormalisedRect(x: -0.2, y: 0.9, width: 0.5, height: 0.4)
        let clamped = overhanging.clamped()
        XCTAssertEqual(clamped.x, 0, accuracy: 1e-12)
        XCTAssertEqual(clamped.maxX, 0.3, accuracy: 1e-12)
        XCTAssertEqual(clamped.maxY, 1, accuracy: 1e-12)
    }

    func testNormalisingFromPointsDividesByPageSize() {
        let rect = NormalisedRect(
            cgRectLikeX: 56,
            y: 84,
            width: 400,
            height: 42,
            inPageWidth: 560,
            pageHeight: 840
        )
        XCTAssertEqual(rect.x, 0.1, accuracy: 1e-12)
        XCTAssertEqual(rect.y, 0.1, accuracy: 1e-12)
        XCTAssertEqual(rect.width, 400.0 / 560.0, accuracy: 1e-12)
        XCTAssertEqual(rect.height, 0.05, accuracy: 1e-12)
    }

    func testNormalisingWithAZeroPageSizeDoesNotProduceInfinity() {
        let rect = NormalisedRect(
            cgRectLikeX: 10, y: 10, width: 10, height: 10,
            inPageWidth: 0, pageHeight: 0
        )
        XCTAssertEqual(rect, .zero)
    }

    func testDenormalisedIsTheInverse() {
        let rect = NormalisedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let points = rect.denormalised(inPageWidth: 600, pageHeight: 800)
        XCTAssertEqual(points.x, 60, accuracy: 1e-9)
        XCTAssertEqual(points.y, 160, accuracy: 1e-9)
        XCTAssertEqual(points.width, 180, accuracy: 1e-9)
        XCTAssertEqual(points.height, 320, accuracy: 1e-9)
    }

    func testCentreDistanceIsSymmetric() {
        let left = NormalisedRect(x: 0, y: 0, width: 0.2, height: 0.2)
        let right = NormalisedRect(x: 0.3, y: 0.4, width: 0.2, height: 0.2)
        XCTAssertEqual(left.centreDistance(to: right), right.centreDistance(to: left), accuracy: 1e-12)
        XCTAssertEqual(left.centreDistance(to: right), 0.5, accuracy: 1e-12)
    }
}
