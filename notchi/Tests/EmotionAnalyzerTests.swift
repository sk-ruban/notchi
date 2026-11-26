import Foundation
import XCTest
@testable import notchi

final class EmotionAnalyzerTests: XCTestCase {
    override func tearDown() {
        ClaudeConfigDirectoryResolver.resetTestingHooks()
        super.tearDown()
    }

    func testParseClaudeSettingsDefaultsBaseURLWhenMissing() throws {
        let data = try makeSettingsJSON(env: [
            "ANTHROPIC_AUTH_TOKEN": "token-123",
        ])

        let config = try XCTUnwrap(ClaudeSettingsConfig.parse(from: data))

        XCTAssertEqual(config.apiURL, URL(string: "https://api.anthropic.com/v1/messages"))
        XCTAssertEqual(config.apiKey, "token-123")
        XCTAssertEqual(config.model, ClaudeSettingsConfig.defaultModel)
    }

    func testParseClaudeSettingsAllowsMissingEnvObject() throws {
        let data = Data("{}".utf8)

        XCTAssertNil(try ClaudeSettingsConfig.parse(from: data))
    }

    func testParseClaudeSettingsNormalizesCustomBaseURL() throws {
        let data = try makeSettingsJSON(env: [
            "ANTHROPIC_BASE_URL": "https://example.com/proxy",
            "ANTHROPIC_AUTH_TOKEN": "token-123",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "custom-model",
        ])

        let config = try XCTUnwrap(ClaudeSettingsConfig.parse(from: data))

        XCTAssertEqual(config.apiURL, URL(string: "https://example.com/proxy/v1/messages"))
        XCTAssertEqual(config.apiKey, "token-123")
        XCTAssertEqual(config.model, "custom-model")
    }

    func testBuildMessagesURLHandlesCommonBaseURLShapes() {
        XCTAssertEqual(
            ClaudeSettingsConfig.buildMessagesURL(from: "https://api.anthropic.com"),
            URL(string: "https://api.anthropic.com/v1/messages")
        )
        XCTAssertEqual(
            ClaudeSettingsConfig.buildMessagesURL(from: "https://api.anthropic.com/v1"),
            URL(string: "https://api.anthropic.com/v1/messages")
        )
        XCTAssertEqual(
            ClaudeSettingsConfig.buildMessagesURL(from: "https://api.anthropic.com/v1/messages"),
            URL(string: "https://api.anthropic.com/v1/messages")
        )
        XCTAssertEqual(
            ClaudeSettingsConfig.buildMessagesURL(from: "https://example.com/proxy/"),
            URL(string: "https://example.com/proxy/v1/messages")
        )
    }

    func testCuratedEmotionModelsAreProviderScoped() {
        XCTAssertEqual(
            EmotionAnalysisModel.models(for: .claude),
            [.claudeHaiku45, .claudeSonnet46]
        )
        XCTAssertEqual(
            EmotionAnalysisModel.models(for: .openAI),
            [.openAIGPT54Mini, .openAIGPT54Nano, .openAIGPT41Mini]
        )
    }

    func testDefaultEmotionModelsStayFastAndCheap() {
        XCTAssertEqual(ClaudeSettingsConfig.defaultModel, EmotionAnalysisModel.claudeHaiku45.rawValue)
        XCTAssertEqual(EmotionAnalysisModel.defaultModel(for: .claude), .claudeHaiku45)
        XCTAssertEqual(EmotionAnalysisModel.defaultModel(for: .openAI), .openAIGPT54Mini)
    }

    @MainActor
    func testAnalyzeReturnsNilWhenNoProviderResolved() async {
        let result = await EmotionAnalyzer.shared.analyze(prompt: "hello", using: nil)
        XCTAssertNil(result)
    }

    @MainActor
    func testAnalyzeReturnsNilWhenProviderThrows() async {
        let result = await EmotionAnalyzer.shared.analyze(
            prompt: "hello",
            using: ThrowingEmotionProvider()
        )
        XCTAssertNil(result)
    }

    @MainActor
    func testLongPromptIsSentAsItsHeadAndTail() async {
        let head = String(repeating: "a", count: 1_500)
        let tail = String(repeating: "c", count: 500)
        let expectedPrompt = head + "\n…\n" + tail
        let provider = CapturingEmotionProvider()

        _ = await EmotionAnalyzer.shared.analyze(
            prompt: head + String(repeating: "b", count: 1_000) + tail,
            using: provider
        )

        XCTAssertEqual(provider.prompts, [expectedPrompt])
    }

    @MainActor
    func testPromptAtTheLengthLimitIsSentUnchanged() async {
        let expectedPrompt = String(repeating: "a", count: 2_000)
        let provider = CapturingEmotionProvider()

        _ = await EmotionAnalyzer.shared.analyze(prompt: expectedPrompt, using: provider)

        XCTAssertEqual(provider.prompts, [expectedPrompt])
    }

    func testEmotionRequestsTimeOutAfterFifteenSeconds() throws {
        let expectedTimeout: TimeInterval = 15
        let request = EmotionAnalysisRequest.post(to: try XCTUnwrap(URL(string: "https://example.com/v1/messages")))

        XCTAssertEqual(request.timeoutInterval, expectedTimeout)
    }

    func testLoadClaudeSettingsConfigReadsCustomResolvedSettingsFile() throws {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-settings.json")
        let data = try makeSettingsJSON(env: [
            "ANTHROPIC_BASE_URL": "https://example.com/proxy",
            "ANTHROPIC_AUTH_TOKEN": "token-xyz",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "haiku-custom",
        ])
        try data.write(to: settingsURL)
        defer {
            try? FileManager.default.removeItem(at: settingsURL)
        }

        let config = ClaudeSettingsConfig.load(from: settingsURL)

        XCTAssertEqual(config?.apiURL, URL(string: "https://example.com/proxy/v1/messages"))
        XCTAssertEqual(config?.apiKey, "token-xyz")
        XCTAssertEqual(config?.model, "haiku-custom")
    }

    private func makeSettingsJSON(env: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "env": env,
        ])
    }
}

private struct ThrowingEmotionProvider: EmotionAnalysisProviding {
    var providerName: String { "Throwing" }

    func analyze(prompt: String, systemPrompt: String) async throws -> (emotion: String, intensity: Double) {
        throw URLError(.notConnectedToInternet)
    }
}

private final class CapturingEmotionProvider: EmotionAnalysisProviding {
    private(set) var prompts: [String] = []

    // The isolated-deinit back-deploy shim aborts on macOS 15; this deinit only releases stored properties.
    nonisolated deinit {}

    var providerName: String { "Capturing" }

    func analyze(prompt: String, systemPrompt: String) async throws -> (emotion: String, intensity: Double) {
        prompts.append(prompt)
        return (emotion: "neutral", intensity: 0)
    }
}
