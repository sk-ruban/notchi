import Foundation
import XCTest
@testable import notchi

final class ModelCatalogTests: XCTestCase {
    private static let claudeModelKey = "emotionAnalysisClaudeModel"
    private static let openAIModelKey = "emotionAnalysisOpenAIModel"

    private var savedClaudeModel: String?
    private var savedOpenAIModel: String?

    override func setUp() {
        super.setUp()
        savedClaudeModel = UserDefaults.standard.string(forKey: Self.claudeModelKey)
        savedOpenAIModel = UserDefaults.standard.string(forKey: Self.openAIModelKey)
    }

    override func tearDown() {
        restore(savedClaudeModel, forKey: Self.claudeModelKey)
        restore(savedOpenAIModel, forKey: Self.openAIModelKey)
        super.tearDown()
    }

    private func restore(_ value: String?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Catalog endpoint

    func testModelsEndpointURLDefaultsWhenBaseURLMissing() {
        XCTAssertEqual(
            EmotionAnalysisProvider.claude.modelsEndpointURL(fromBaseURL: nil),
            URL(string: "https://api.anthropic.com/v1/models")
        )
        XCTAssertEqual(
            EmotionAnalysisProvider.openAI.modelsEndpointURL(fromBaseURL: "   "),
            URL(string: "https://api.openai.com/v1/models")
        )
    }

    func testModelsEndpointURLNormalizesCommonBaseURLShapes() {
        XCTAssertEqual(
            EmotionAnalysisProvider.openAI.modelsEndpointURL(fromBaseURL: "https://relay.example.com"),
            URL(string: "https://relay.example.com/v1/models")
        )
        XCTAssertEqual(
            EmotionAnalysisProvider.openAI.modelsEndpointURL(fromBaseURL: "https://relay.example.com/v1"),
            URL(string: "https://relay.example.com/v1/models")
        )
        XCTAssertEqual(
            EmotionAnalysisProvider.openAI.modelsEndpointURL(fromBaseURL: "relay.example.com/proxy/"),
            URL(string: "https://relay.example.com/proxy/v1/models")
        )
    }

    /// A base URL pasted as the full chat route must not produce ".../v1/messages/v1/models".
    func testModelsEndpointURLStripsAChatRouteFromTheBaseURL() {
        XCTAssertEqual(
            EmotionAnalysisProvider.claude.modelsEndpointURL(fromBaseURL: "https://relay.example.com/v1/messages"),
            URL(string: "https://relay.example.com/v1/models")
        )
        XCTAssertEqual(
            EmotionAnalysisProvider.openAI.modelsEndpointURL(fromBaseURL: "https://relay.example.com/v1/chat/completions"),
            URL(string: "https://relay.example.com/v1/models")
        )
        XCTAssertEqual(
            EmotionAnalysisProvider.claude.modelsEndpointURL(fromBaseURL: "https://relay.example.com/proxy/v1/messages"),
            URL(string: "https://relay.example.com/proxy/v1/models")
        )
    }

    /// Stripping the chat route must not change how the chat endpoint itself is built.
    func testChatEndpointURLIsUnchangedByCatalogSupport() {
        XCTAssertEqual(
            EmotionAnalysisProvider.claude.endpointURL(fromBaseURL: "https://relay.example.com/v1/messages"),
            URL(string: "https://relay.example.com/v1/messages")
        )
        XCTAssertEqual(
            EmotionAnalysisProvider.openAI.endpointURL(fromBaseURL: "https://relay.example.com/v1"),
            URL(string: "https://relay.example.com/v1/chat/completions")
        )
    }

    func testModelsEndpointURLRejectsGarbage() {
        XCTAssertNil(EmotionAnalysisProvider.openAI.modelsEndpointURL(fromBaseURL: "http://"))
    }

    // MARK: - Response parsing

    func testParsesOpenAIAndAnthropicCatalogShape() throws {
        let data = Data("""
        {"object": "list", "data": [{"id": "gpt-4.1-mini"}, {"id": "local-llama"}]}
        """.utf8)

        let models = try ModelCatalogService.models(from: data, for: .openAI)

        XCTAssertEqual(models.map(\.rawValue), ["gpt-4.1-mini", "local-llama"])
    }

    func testParsesGatewaysThatKeyTheListOnModels() throws {
        let data = Data("""
        {"models": [{"id": "mixtral"}, {"name": "qwen-chat"}]}
        """.utf8)

        let models = try ModelCatalogService.models(from: data, for: .openAI)

        XCTAssertEqual(models.map(\.rawValue), ["mixtral", "qwen-chat"])
    }

    func testParsesABareArray() throws {
        let data = Data("""
        [{"id": "solo-model"}]
        """.utf8)

        XCTAssertEqual(try ModelCatalogService.models(from: data, for: .openAI).map(\.rawValue), ["solo-model"])
    }

    /// An undecodable body must not masquerade as an endpoint that simply lists nothing.
    func testMalformedPayloadThrowsInvalidResponse() {
        for payload in ["not json", "{}"] {
            XCTAssertThrowsError(try ModelCatalogService.models(from: Data(payload.utf8), for: .openAI)) { error in
                XCTAssertEqual(error as? EmotionAnalysisRequestError, .invalidResponse)
            }
        }
    }

    func testSuccessfullyDecodedEmptyCatalogIsNotAnError() throws {
        XCTAssertTrue(try ModelCatalogService.models(from: Data(#"{"data": []}"#.utf8), for: .openAI).isEmpty)
    }

    func testCatalogDropsDuplicateIds() throws {
        let data = Data("""
        {"data": [{"id": "gpt-4.1-mini"}, {"id": "gpt-4.1-mini"}]}
        """.utf8)

        XCTAssertEqual(try ModelCatalogService.models(from: data, for: .openAI).count, 1)
    }

    func testFetchedIdsKeepPresetDisplayNames() throws {
        let data = Data("""
        {"data": [{"id": "claude-haiku-4-5-20251001"}]}
        """.utf8)

        let models = try ModelCatalogService.models(from: data, for: .claude)

        XCTAssertEqual(models, [.claudeHaiku45])
        XCTAssertEqual(models.first?.displayName, "Claude Haiku 4.5")
    }

    // MARK: - Filtering

    func testFilterDropsModelsThatCannotChat() {
        let ids = ["gpt-4.1-mini", "text-embedding-3-small", "whisper-1", "dall-e-3", "omni-moderation-latest"]

        XCTAssertEqual(ModelCatalogFilter.chatCapable(ids), ["gpt-4.1-mini"])
    }

    /// An unfamiliar catalog is better shown in full than hidden behind an empty picker.
    func testFilterKeepsEverythingWhenItWouldOtherwiseEmptyTheList() {
        let ids = ["my-embedding-only-server"]

        XCTAssertEqual(ModelCatalogFilter.chatCapable(ids), ids)
    }

    // MARK: - Output token budget

    /// Presets keep the budget the app shipped with, so nothing gets more expensive by default.
    func testPresetsKeepTheirOriginalTokenBudget() {
        XCTAssertEqual(EmotionAnalysisModel.claudeHaiku45.maxOutputTokens, 50)
        XCTAssertEqual(EmotionAnalysisModel.openAIGPT54Mini.maxOutputTokens, 80)
    }

    /// A local reasoning model can spend 77 reasoning tokens before writing a character, so an
    /// unknown model needs far more room than the curated ones.
    func testCustomModelsGetABudgetThatSurvivesReasoningTokens() {
        let custom = EmotionAnalysisModel.custom("gemma-4-26b-a4b-it", provider: .openAI)

        XCTAssertEqual(custom.maxOutputTokens, EmotionAnalysisModel.customModelOutputTokens)
        XCTAssertGreaterThan(custom.maxOutputTokens, EmotionAnalysisModel.openAIGPT54Mini.maxOutputTokens)
    }

    // MARK: - Custom model persistence

    func testResolveMapsKnownIdsToPresetsAndKeepsUnknownOnes() {
        XCTAssertEqual(EmotionAnalysisModel.resolve("gpt-5.4-mini", for: .openAI), .openAIGPT54Mini)
        XCTAssertTrue(EmotionAnalysisModel.resolve("gpt-5.4-mini", for: .openAI).isPreset)

        let custom = EmotionAnalysisModel.resolve("llama3.2:latest", for: .openAI)
        XCTAssertFalse(custom.isPreset)
        XCTAssertEqual(custom.displayName, "llama3.2:latest")
    }

    /// The bug this change fixes: an id outside the curated list used to be discarded on read,
    /// so the picker silently snapped back to the default model.
    @MainActor
    func testCustomModelIdSurvivesAStorageRoundTrip() {
        let custom = EmotionAnalysisModel.custom("llama3.2:latest", provider: .openAI)

        AppSettings.setEmotionAnalysisModel(custom, for: .openAI)

        XCTAssertEqual(AppSettings.storedEmotionAnalysisModel(for: .openAI), custom)
        XCTAssertEqual(AppSettings.selectedEmotionAnalysisModel(for: .openAI).rawValue, "llama3.2:latest")
    }

    @MainActor
    func testBlankStoredModelFallsBackToTheDefault() {
        UserDefaults.standard.set("   ", forKey: Self.openAIModelKey)

        XCTAssertNil(AppSettings.storedEmotionAnalysisModel(for: .openAI))
        XCTAssertEqual(AppSettings.selectedEmotionAnalysisModel(for: .openAI), .openAIGPT54Mini)
    }

    @MainActor
    func testModelsAreNotWrittenAcrossProviders() {
        AppSettings.setEmotionAnalysisModel(.openAIGPT54Nano, for: .openAI)

        AppSettings.setEmotionAnalysisModel(.claudeHaiku45, for: .openAI)

        XCTAssertEqual(AppSettings.selectedEmotionAnalysisModel(for: .openAI), .openAIGPT54Nano)
    }
}
