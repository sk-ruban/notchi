import Foundation
import XCTest
@testable import notchi

final class OpenAIResponseHandlingTests: XCTestCase {

    // MARK: - Response reading

    func testReadsJSONFromContent() throws {
        let result = try OpenAIChatResponseReader.emotion(
            from: payload(content: #"{"emotion": "happy", "intensity": 0.8}"#, finishReason: "stop")
        )

        XCTAssertEqual(result.emotion, "happy")
        XCTAssertEqual(result.intensity, 0.8, accuracy: 0.0001)
    }

    func testEmptyContentStoppedOnLengthReportsTruncation() throws {
        XCTAssertThrowsError(
            try OpenAIChatResponseReader.emotion(from: payload(content: "", finishReason: "length"))
        ) { error in
            XCTAssertEqual(error as? EmotionAnalysisRequestError, .truncatedResponse)
        }
    }

    /// A model that hit the cap mid-answer leaves partial JSON, which is truncation rather than
    /// malformed output. Only empty content was checked before.
    func testPartialJSONStoppedOnLengthReportsTruncation() throws {
        XCTAssertThrowsError(
            try OpenAIChatResponseReader.emotion(from: payload(content: #"{"emotion": "hap"#, finishReason: "length"))
        ) { error in
            XCTAssertEqual(error as? EmotionAnalysisRequestError, .truncatedResponse)
        }
    }

    /// Genuinely malformed output that stopped normally must not be blamed on the token budget.
    func testPartialJSONStoppedNormallyIsNotTruncation() throws {
        XCTAssertThrowsError(
            try OpenAIChatResponseReader.emotion(from: payload(content: #"{"emotion": "hap"#, finishReason: "stop"))
        ) { error in
            XCTAssertNotEqual(error as? EmotionAnalysisRequestError, .truncatedResponse)
        }
    }

    func testAnswerDeliveredInTheReasoningChannelIsUsed() throws {
        let result = try OpenAIChatResponseReader.emotion(
            from: payload(
                content: "",
                reasoningContent: #"{"emotion": "sad", "intensity": 0.4}"#,
                finishReason: "stop"
            )
        )

        XCTAssertEqual(result.emotion, "sad")
        XCTAssertEqual(result.intensity, 0.4, accuracy: 0.0001)
    }

    func testResponseWithoutChoicesIsInvalid() throws {
        let data = try JSONSerialization.data(withJSONObject: ["choices": []])

        XCTAssertThrowsError(try OpenAIChatResponseReader.emotion(from: data)) { error in
            XCTAssertEqual(error as? EmotionAnalysisRequestError, .invalidResponse)
        }
    }

    // MARK: - Helpers

    private func payload(
        content: String?,
        reasoningContent: String? = nil,
        finishReason: String
    ) throws -> Data {
        var message: [String: Any] = [:]
        if let content {
            message["content"] = content
        }
        if let reasoningContent {
            message["reasoning_content"] = reasoningContent
        }

        return try JSONSerialization.data(
            withJSONObject: ["choices": [["message": message, "finish_reason": finishReason]]]
        )
    }
}
