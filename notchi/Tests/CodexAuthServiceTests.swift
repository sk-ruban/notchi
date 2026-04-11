import Foundation
import XCTest
@testable import notchi

final class CodexAuthServiceTests: XCTestCase {
    func testDecodeCodexAuthFileMetadataParsesAuthModeAndRefreshTime() throws {
        let payload: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": "access-token-123",
            ],
            "last_refresh": "2026-04-04T02:00:00.849566Z",
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let metadata = try XCTUnwrap(CodexAuthFileMetadata.decode(from: data))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        XCTAssertEqual(metadata.authMode, .chatgpt)
        XCTAssertEqual(
            metadata.lastRefresh,
            formatter.date(from: "2026-04-04T02:00:00.849566Z")
        )
    }

    func testDecodeCodexAuthFileMetadataAllowsMissingTokenPayload() throws {
        let payload: [String: Any] = [
            "auth_mode": "apikey",
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let metadata = try XCTUnwrap(CodexAuthFileMetadata.decode(from: data))

        XCTAssertEqual(metadata.authMode, .apikey)
        XCTAssertNil(metadata.lastRefresh)
    }

    func testParseCodexCLIStatusParsesChatGPTLogin() {
        let status = CodexCLIStatus.parse(output: "Logged in using ChatGPT\n")

        XCTAssertEqual(
            status,
            CodexCLIStatus(isConnected: true, authMode: .chatgpt)
        )
    }

    func testParseCodexCLIStatusParsesAPIKeyLogin() {
        let status = CodexCLIStatus.parse(output: "Logged in using an API key - sk-...\n")

        XCTAssertEqual(
            status,
            CodexCLIStatus(isConnected: true, authMode: .apikey)
        )
    }

    func testParseCodexCLIStatusParsesDisconnectedState() {
        let status = CodexCLIStatus.parse(output: "Not logged in\n")

        XCTAssertEqual(
            status,
            CodexCLIStatus(isConnected: false, authMode: nil)
        )
    }
}
