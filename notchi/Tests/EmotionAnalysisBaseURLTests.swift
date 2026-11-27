import Foundation
import XCTest
@testable import notchi

final class EmotionAnalysisBaseURLTests: XCTestCase {
    private static let defaultClaudeEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let defaultOpenAIEndpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    // A throwaway store per test: the standard one is the installed app's real preferences.
    private let suiteName = "EmotionAnalysisBaseURLTests-\(UUID().uuidString)"
    private lazy var defaults = UserDefaults(suiteName: suiteName)!

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
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
        AppSettings.setApiBaseURL("https://claude-relay.example.com", for: .claude, in: defaults)
        AppSettings.setApiBaseURL("https://openai-relay.example.com", for: .openAI, in: defaults)

        XCTAssertEqual(AppSettings.apiBaseURL(for: .claude, in: defaults), "https://claude-relay.example.com")
        XCTAssertEqual(AppSettings.apiBaseURL(for: .openAI, in: defaults), "https://openai-relay.example.com")
    }

    @MainActor
    func testApiBaseURLStoresTrimmedValueAndClearsWhenEmpty() {
        AppSettings.setApiBaseURL("  https://relay.example.com  ", for: .claude, in: defaults)
        XCTAssertEqual(AppSettings.apiBaseURL(for: .claude, in: defaults), "https://relay.example.com")

        AppSettings.setApiBaseURL("   ", for: .claude, in: defaults)
        XCTAssertNil(AppSettings.apiBaseURL(for: .claude, in: defaults))

        AppSettings.setApiBaseURL(nil, for: .claude, in: defaults)
        XCTAssertNil(AppSettings.apiBaseURL(for: .claude, in: defaults))
    }

    @MainActor
    func testManualEndpointURLUsesStoredBaseURLAndFallsBackToDefault() {
        XCTAssertEqual(EmotionAnalyzer.manualEndpointURL(for: .claude, in: defaults), Self.defaultClaudeEndpoint)

        AppSettings.setApiBaseURL("https://relay.example.com", for: .claude, in: defaults)
        XCTAssertEqual(
            EmotionAnalyzer.manualEndpointURL(for: .claude, in: defaults),
            URL(string: "https://relay.example.com/v1/messages")
        )

        AppSettings.setApiBaseURL("https://", for: .claude, in: defaults)
        XCTAssertNil(EmotionAnalyzer.manualEndpointURL(for: .claude, in: defaults))
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
