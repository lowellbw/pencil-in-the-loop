import XCTest
import Core
@testable import Annotate

/// The contract term that matters most in `HandwritingRecognising`: it returns
/// nil, it never throws, and nothing waits on it (docs/04-flows.md § F3).
final class NullHandwritingRecogniserTests: XCTestCase {

    func testItAlwaysDeclines() async {
        let recogniser = NullHandwritingRecogniser()
        let result = await recogniser.recogniseText(drawingData: Data([1, 2, 3]), locale: Locale(identifier: "en-GB"))
        XCTAssertNil(result)
    }

    func testItDeclinesEmptyInputToo() async {
        let recogniser = NullHandwritingRecogniser()
        let result = await recogniser.recogniseText(drawingData: Data(), locale: Locale(identifier: "en-GB"))
        XCTAssertNil(result)
    }

    func testItIsNeverAvailableForAnyLocale() async {
        let recogniser = NullHandwritingRecogniser()
        for identifier in ["en-GB", "en-US", "fr-FR", "zh-Hans", ""] {
            let available = await recogniser.isAvailable(for: Locale(identifier: identifier))
            XCTAssertFalse(available)
        }
    }

    func testTheFactoryProducesSomethingUsableOnEveryBuild() async {
        // With the stroke recogniser compiled out — the default — this is the
        // null one. With it compiled in, on a device below iPadOS 27, it is
        // still the null one. Either way there is always a recogniser, and the
        // app never has to branch on whether it has one.
        let recogniser = InkRecogniserFactory.make()
        let available = await recogniser.isAvailable(for: Locale(identifier: "en-GB"))
        if !InkRecogniserFactory.isCompiledIn {
            XCTAssertFalse(available)
            let result = await recogniser.recogniseText(drawingData: Data(), locale: Locale(identifier: "en-GB"))
            XCTAssertNil(result)
        }
    }
}
