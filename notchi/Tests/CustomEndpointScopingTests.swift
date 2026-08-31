import Foundation
import XCTest
@testable import notchi

/// The settings panel hides model refresh and custom model-id entry unless a base URL is set, and
/// renames the provider row to match what requests are actually going to.
final class CustomEndpointScopingTests: XCTestCase {

    // MARK: - Detecting a custom endpoint

    func testAnEmptyBaseURLIsNotACustomEndpoint() {
        XCTAssertFalse(EmotionAnalysisProvider.hasCustomEndpoint(baseURL: nil))
        XCTAssertFalse(EmotionAnalysisProvider.hasCustomEndpoint(baseURL: ""))
    }

    /// The field holds raw keystrokes, so whitespace alone must not switch the panel over.
    func testWhitespaceOnlyIsNotACustomEndpoint() {
        XCTAssertFalse(EmotionAnalysisProvider.hasCustomEndpoint(baseURL: "   "))
        XCTAssertFalse(EmotionAnalysisProvider.hasCustomEndpoint(baseURL: "\n\t "))
    }

    func testAnyRealBaseURLIsACustomEndpoint() {
        XCTAssertTrue(EmotionAnalysisProvider.hasCustomEndpoint(baseURL: "localhost:1234/v1"))
        XCTAssertTrue(EmotionAnalysisProvider.hasCustomEndpoint(baseURL: "  https://relay.example.com  "))
    }

    /// The same predicate drives whether a catalog request would even be built.
    func testTheDefaultEndpointIsStillReachableWithoutACustomBaseURL() {
        XCTAssertFalse(EmotionAnalysisProvider.hasCustomEndpoint(baseURL: nil))
        XCTAssertNotNil(EmotionAnalysisProvider.openAI.modelsEndpointURL(fromBaseURL: nil))
    }

    // MARK: - Provider label

    func testStockProvidersKeepTheirVendorName() {
        XCTAssertEqual(EmotionAnalysisProvider.openAI.displayName(forBaseURL: nil), "OpenAI")
        XCTAssertEqual(EmotionAnalysisProvider.openAI.displayName(forBaseURL: "  "), "OpenAI")
        XCTAssertEqual(EmotionAnalysisProvider.claude.displayName(forBaseURL: nil), "Claude")
    }

    func testACustomOpenAIEndpointIsLabelledByItsRequestShape() {
        XCTAssertEqual(
            EmotionAnalysisProvider.openAI.displayName(forBaseURL: "http://localhost:1234/v1"),
            "OpenAI-compatible"
        )
    }

    /// A proxied Anthropic endpoint still speaks the Anthropic shape, so it keeps its name.
    func testACustomClaudeEndpointKeepsItsName() {
        XCTAssertEqual(
            EmotionAnalysisProvider.claude.displayName(forBaseURL: "https://relay.example.com"),
            "Claude"
        )
    }

    func testTheLabelNeverCollapsesToAnEmptyString() {
        for provider in EmotionAnalysisProvider.allCases {
            for baseURL in [nil, "", "   ", "localhost:1234/v1"] as [String?] {
                XCTAssertFalse(
                    provider.displayName(forBaseURL: baseURL).isEmpty,
                    "\(provider) with base URL \(baseURL ?? "nil") produced an empty label"
                )
            }
        }
    }
}
