import Foundation
import XCTest
@testable import notchi

/// A model or base-URL mismatch used to surface as a bare "HTTP 400", which is close to
/// undiagnosable. These cover the shapes the readable part actually arrives in.
final class APIErrorMessageTests: XCTestCase {

    // MARK: - Extraction

    func testReadsTheNestedOpenAIShape() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "error": [
                "message": "The model `gpt-9` does not exist or you do not have access to it.",
                "type": "invalid_request_error",
            ]
        ])

        XCTAssertEqual(
            APIErrorMessageReader.message(from: data),
            "The model `gpt-9` does not exist or you do not have access to it."
        )
    }

    func testReadsTheNestedAnthropicShape() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "error",
            "error": ["type": "authentication_error", "message": "invalid x-api-key"],
        ])

        XCTAssertEqual(APIErrorMessageReader.message(from: data), "invalid x-api-key")
    }

    /// LM Studio and several gateways put a bare string under "error".
    func testReadsABareStringError() throws {
        let data = try JSONSerialization.data(withJSONObject: ["error": "Model unloaded"])

        XCTAssertEqual(APIErrorMessageReader.message(from: data), "Model unloaded")
    }

    func testFallsBackToTypeWhenNoMessageIsPresent() throws {
        let data = try JSONSerialization.data(withJSONObject: ["error": ["type": "overloaded_error"]])

        XCTAssertEqual(APIErrorMessageReader.message(from: data), "overloaded_error")
    }

    func testReadsATopLevelMessage() throws {
        let data = try JSONSerialization.data(withJSONObject: ["message": "Not Found"])

        XCTAssertEqual(APIErrorMessageReader.message(from: data), "Not Found")
    }

    /// A reverse proxy in front of a local server often answers with HTML rather than JSON.
    func testFallsBackToTheRawBody() throws {
        let data = try XCTUnwrap("upstream connect error".data(using: .utf8))

        XCTAssertEqual(APIErrorMessageReader.message(from: data), "upstream connect error")
    }

    func testCollapsesWhitespaceSoTheLineStaysReadable() throws {
        let data = try XCTUnwrap("<html>\n  <body>502\n\tBad Gateway</body>\n</html>".data(using: .utf8))

        XCTAssertEqual(APIErrorMessageReader.message(from: data), "<html> <body>502 Bad Gateway</body> </html>")
    }

    func testEmptyBodyYieldsNoMessage() {
        XCTAssertNil(APIErrorMessageReader.message(from: Data()))
        XCTAssertNil(APIErrorMessageReader.message(from: Data("   \n ".utf8)))
    }

    // MARK: - Bounding

    func testAnOversizedBodyIsTruncatedRatherThanFloodingTheUI() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "error": ["message": String(repeating: "a", count: 5_000)]
        ])

        let message = try XCTUnwrap(APIErrorMessageReader.message(from: data))

        XCTAssertEqual(message.count, APIErrorMessageReader.maxLength + 1)
        XCTAssertTrue(message.hasSuffix("\u{2026}"))
    }

    func testAMessageAtTheLimitIsLeftIntact() throws {
        let exact = String(repeating: "b", count: APIErrorMessageReader.maxLength)
        let data = try JSONSerialization.data(withJSONObject: ["error": ["message": exact]])

        XCTAssertEqual(APIErrorMessageReader.message(from: data), exact)
    }

    // MARK: - Surfacing

    func testErrorDescriptionCarriesTheEndpointMessage() {
        let error = EmotionAnalysisRequestError.httpStatus(
            provider: "OpenAI",
            statusCode: 404,
            message: "model not found"
        )

        XCTAssertEqual(error.errorDescription, "OpenAI API returned HTTP 404: model not found")
    }

    func testErrorDescriptionStaysCleanWithoutAMessage() {
        let error = EmotionAnalysisRequestError.httpStatus(provider: "Claude", statusCode: 500, message: nil)

        XCTAssertEqual(error.errorDescription, "Claude API returned HTTP 500")
    }

    /// The status badge is a few characters wide, so it must not inherit the body text.
    func testShortLabelIgnoresTheMessage() {
        let error = EmotionAnalysisRequestError.httpStatus(
            provider: "OpenAI",
            statusCode: 400,
            message: String(repeating: "noise ", count: 40)
        )

        XCTAssertEqual(error.shortLabel, "HTTP 400")
    }
}
