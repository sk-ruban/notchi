import Foundation
import XCTest
@testable import notchi

final class OpenAIResponseHandlingTests: XCTestCase {

    // MARK: - Reasoning suppression gating

    func testSuppressionIsOffForOpenAIItself() {
        XCTAssertFalse(OpenAISettingsConfig.suppressesReasoning(at: OpenAISettingsConfig.defaultAPIURL))
        XCTAssertFalse(
            OpenAISettingsConfig.suppressesReasoning(
                at: URL(string: "https://API.OpenAI.com/v1/chat/completions")!
            )
        )
    }

    func testSuppressionIsOnForCustomEndpoints() {
        XCTAssertTrue(
            OpenAISettingsConfig.suppressesReasoning(at: URL(string: "http://localhost:1234/v1/chat/completions")!)
        )
        XCTAssertTrue(
            OpenAISettingsConfig.suppressesReasoning(at: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        )
    }

    /// A fine-tuned id is still served by OpenAI, so it must not cost a rejected request and a retry.
    func testCustomModelIdOnOpenAIDoesNotTriggerSuppression() {
        let model = EmotionAnalysisModel.custom("ft:gpt-4.1-mini:acme::abc123", provider: .openAI)

        XCTAssertFalse(model.isPreset)
        XCTAssertFalse(OpenAISettingsConfig.suppressesReasoning(at: OpenAISettingsConfig.defaultAPIURL))
    }

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
