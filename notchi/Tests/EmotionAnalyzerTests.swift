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

        let config = EmotionAnalyzer.loadClaudeSettingsConfig(from: settingsURL)

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
