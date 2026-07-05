import Foundation
import XCTest
@testable import notchi

final class EmotionAnalysisBaseURLTests: XCTestCase {
    private static let defaultClaudeEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let defaultOpenAIEndpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    @MainActor
    override func setUp() {
        super.setUp()
        clearStoredBaseURLs()
    }

    @MainActor
    override func tearDown() {
        clearStoredBaseURLs()
        super.tearDown()
    }

    @MainActor
    private func clearStoredBaseURLs() {
        AppSettings.setApiBaseURL(nil, for: .claude)
        AppSettings.setApiBaseURL(nil, for: .openAI)
    }

    func testEndpointURLDefaultsWhenBaseURLMissing() {
        XCTAssertEqual(EmotionAnalysisProvider.claude.endpointURL(fromBaseURL: nil), Self.defaultClaudeEndpoint)
        XCTAssertEqual(EmotionAnalysisProvider.claude.endpointURL(fromBaseURL: ""), Self.defaultClaudeEndpoint)
        XCTAssertEqual(EmotionAnalysisProvider.claude.endpointURL(fromBaseURL: "   "), Self.defaultClaudeEndpoint)
        XCTAssertEqual(EmotionAnalysisProvider.openAI.endpointURL(fromBaseURL: nil), Self.defaultOpenAIEndpoint)
    }

    func testEndpointURLNormalizesCommonClaudeBaseURLShapes() {
        XCTAssertEqual(
            EmotionAnalysisProvider.claude.endpointURL(fromBaseURL: "https://relay.example.com"),
            URL(string: "https://relay.example.com/v1/messages")
        )
        XCTAssertEqual(
            EmotionAnalysisProvider.claude.endpointURL(fromBaseURL: "https://relay.example.com/"),
            URL(string: "https://relay.example.com/v1/messages")
        )
        XCTAssertEqual(
            EmotionAnalysisProvider.claude.endpointURL(fromBaseURL: "https://relay.example.com/v1"),
            URL(string: "https://relay.example.com/v1/messages")
        )
        XCTAssertEqual(
            EmotionAnalysisProvider.claude.endpointURL(fromBaseURL: "https://relay.example.com/v1/messages"),
            URL(string: "https://relay.example.com/v1/messages")
        )
        XCTAssertEqual(
            EmotionAnalysisProvider.claude.endpointURL(fromBaseURL: "https://relay.example.com/proxy/"),
            URL(string: "https://relay.example.com/proxy/v1/messages")
        )
    }

    func testEndpointURLNormalizesCommonOpenAIBaseURLShapes() {
        XCTAssertEqual(
            EmotionAnalysisProvider.openAI.endpointURL(fromBaseURL: "https://relay.example.com"),
            URL(string: "https://relay.example.com/v1/chat/completions")
        )
        XCTAssertEqual(
            EmotionAnalysisProvider.openAI.endpointURL(fromBaseURL: "https://relay.example.com/v1"),
            URL(string: "https://relay.example.com/v1/chat/completions")
        )
        XCTAssertEqual(
            EmotionAnalysisProvider.openAI.endpointURL(fromBaseURL: "https://relay.example.com/v1/chat/completions"),
            URL(string: "https://relay.example.com/v1/chat/completions")
        )
        XCTAssertEqual(
            EmotionAnalysisProvider.openAI.endpointURL(fromBaseURL: "https://relay.example.com/proxy"),
            URL(string: "https://relay.example.com/proxy/v1/chat/completions")
        )
    }

    func testEndpointURLPrependsHTTPSWhenSchemeMissing() {
        XCTAssertEqual(
            EmotionAnalysisProvider.claude.endpointURL(fromBaseURL: "relay.example.com"),
            URL(string: "https://relay.example.com/v1/messages")
        )
    }

    func testEndpointURLRejectsUnparseableBaseURL() {
        XCTAssertNil(EmotionAnalysisProvider.claude.endpointURL(fromBaseURL: "https://"))
        XCTAssertNil(EmotionAnalysisProvider.claude.endpointURL(fromBaseURL: "not a url"))
        XCTAssertNil(EmotionAnalysisProvider.openAI.endpointURL(fromBaseURL: "https://exa mple.com"))
    }

    @MainActor
    func testApiBaseURLRoundTripIsProviderScoped() {
        AppSettings.setApiBaseURL("https://claude-relay.example.com", for: .claude)
        AppSettings.setApiBaseURL("https://openai-relay.example.com", for: .openAI)

        XCTAssertEqual(AppSettings.apiBaseURL(for: .claude), "https://claude-relay.example.com")
        XCTAssertEqual(AppSettings.apiBaseURL(for: .openAI), "https://openai-relay.example.com")
    }

    @MainActor
    func testApiBaseURLStoresTrimmedValueAndClearsWhenEmpty() {
        AppSettings.setApiBaseURL("  https://relay.example.com  ", for: .claude)
        XCTAssertEqual(AppSettings.apiBaseURL(for: .claude), "https://relay.example.com")

        AppSettings.setApiBaseURL("   ", for: .claude)
        XCTAssertNil(AppSettings.apiBaseURL(for: .claude))

        AppSettings.setApiBaseURL(nil, for: .claude)
        XCTAssertNil(AppSettings.apiBaseURL(for: .claude))
    }

    @MainActor
    func testManualEndpointURLUsesStoredBaseURLAndFallsBackToDefault() {
        XCTAssertEqual(EmotionAnalyzer.manualEndpointURL(for: .claude), Self.defaultClaudeEndpoint)

        AppSettings.setApiBaseURL("https://relay.example.com", for: .claude)
        XCTAssertEqual(
            EmotionAnalyzer.manualEndpointURL(for: .claude),
            URL(string: "https://relay.example.com/v1/messages")
        )

        AppSettings.setApiBaseURL("https://", for: .claude)
        XCTAssertNil(EmotionAnalyzer.manualEndpointURL(for: .claude))
    }

    @MainActor
    func testTestConfigurationThrowsForInvalidBaseURL() async {
        do {
            _ = try await EmotionAnalyzer.shared.testConfiguration(
                provider: .claude,
                model: .claudeHaiku45,
                apiKey: "sk-test",
                baseURL: "https://"
            )
            XCTFail("Expected invalidBaseURL error")
        } catch let error as EmotionAnalysisRequestError {
            guard case .invalidBaseURL = error else {
                XCTFail("Expected invalidBaseURL, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
