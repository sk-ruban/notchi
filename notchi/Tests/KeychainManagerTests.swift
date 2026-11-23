import Foundation
import XCTest
@testable import notchi

final class KeychainManagerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KeychainManager._resetCredentialResolutionStateForTesting()
    }

    override func tearDown() {
        KeychainManager._resetCredentialResolutionStateForTesting()
        super.tearDown()
    }

    func testDecodeClaudeOAuthCredentialsWithScopesAndExpiry() throws {
        let expiresAt = "2099-01-01T01:00:00Z"
        let data = makeCredentialPayload(
            accessToken: "token-123",
            expiresAt: expiresAt,
            scopes: ["user:profile", "openid"]
        )

        let credentials = try XCTUnwrap(KeychainManager.decodeClaudeOAuthCredentials(from: data))

        XCTAssertEqual(credentials.accessToken, "token-123")
        XCTAssertEqual(credentials.scopes, Set(["openid", "user:profile"]))
        XCTAssertEqual(
            credentials.expiresAt,
            ISO8601DateFormatter().date(from: expiresAt)
        )
    }

    func testDecodeClaudeOAuthCredentialsAllowsMissingUserProfileScope() throws {
        let data = makeCredentialPayload(
            accessToken: "token-123",
            scopes: ["openid"]
        )

        let credentials = try XCTUnwrap(KeychainManager.decodeClaudeOAuthCredentials(from: data))

        XCTAssertEqual(credentials.scopes, Set(["openid"]))
        XCTAssertFalse(credentials.scopes.contains("user:profile"))
    }

    func testDecodeClaudeOAuthCredentialsParsesExpiredEpochMetadata() throws {
        let data = makeCredentialPayload(
            accessToken: "token-123",
            expiresAt: 1
        )

        let credentials = try XCTUnwrap(KeychainManager.decodeClaudeOAuthCredentials(from: data))

        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1))
    }

    func testDecodeClaudeOAuthCredentialsAllowsAbsentOptionalMetadata() throws {
        let data = makeCredentialPayload(accessToken: "token-123")

        let credentials = try XCTUnwrap(KeychainManager.decodeClaudeOAuthCredentials(from: data))

        XCTAssertEqual(credentials.accessToken, "token-123")
        XCTAssertNil(credentials.expiresAt)
        XCTAssertTrue(credentials.scopes.isEmpty)
    }

    func testGetOAuthCredentialsCachesRecentCLIResult() throws {
        let json = makeCredentialJSON(accessToken: "cli-token")
        var cliCalls = 0

        KeychainManager._setSecurityCLIReadOverrideForTesting {
            cliCalls += 1
            return json
        }
        KeychainManager._setSecurityFrameworkReadOverrideForTesting { _ in
            XCTFail("Security.framework fallback should not run when CLI succeeds")
            return nil
        }

        let first = try XCTUnwrap(KeychainManager.getOAuthCredentials(allowInteraction: false))
        let second = try XCTUnwrap(KeychainManager.getOAuthCredentials(allowInteraction: false))

        XCTAssertEqual(first.accessToken, "cli-token")
        XCTAssertEqual(second.accessToken, "cli-token")
        XCTAssertEqual(cliCalls, 1)
    }

    func testGetOAuthCredentialsBacksOffCLIForCooldownAfterFailure() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        var cliCalls = 0
        var frameworkCalls = 0

        KeychainManager._setNowOverrideForTesting { now }
        KeychainManager._setSecurityCLIReadOverrideForTesting {
            cliCalls += 1
            return nil
        }
        KeychainManager._setSecurityFrameworkReadOverrideForTesting { allowInteraction in
            frameworkCalls += 1
            XCTAssertFalse(allowInteraction)
            return nil
        }

        XCTAssertNil(KeychainManager.getOAuthCredentials(allowInteraction: false))
        XCTAssertNil(KeychainManager.getOAuthCredentials(allowInteraction: false))
        XCTAssertEqual(cliCalls, 1)
        XCTAssertEqual(frameworkCalls, 2)

        now.addTimeInterval(61)

        XCTAssertNil(KeychainManager.getOAuthCredentials(allowInteraction: false))
        XCTAssertEqual(cliCalls, 2)
        XCTAssertEqual(frameworkCalls, 3)
    }

    func testGetOAuthCredentialsPassesInteractionPolicyToSecurityFrameworkFallback() throws {
        var seenAllowInteraction: [Bool] = []

        KeychainManager._setSecurityCLIReadOverrideForTesting {
            nil
        }
        KeychainManager._setSecurityFrameworkReadOverrideForTesting { allowInteraction in
            seenAllowInteraction.append(allowInteraction)
            return self.makeCredentialJSON(accessToken: allowInteraction ? "interactive" : "silent")
        }

        let interactive = try XCTUnwrap(KeychainManager.getOAuthCredentials(allowInteraction: true))

        KeychainManager._resetCredentialResolutionStateForTesting()
        KeychainManager._setSecurityCLIReadOverrideForTesting {
            nil
        }
        KeychainManager._setSecurityFrameworkReadOverrideForTesting { allowInteraction in
            seenAllowInteraction.append(allowInteraction)
            return self.makeCredentialJSON(accessToken: allowInteraction ? "interactive" : "silent")
        }

        let silent = try XCTUnwrap(KeychainManager.getOAuthCredentials(allowInteraction: false))

        XCTAssertEqual(interactive.accessToken, "interactive")
        XCTAssertEqual(silent.accessToken, "silent")
        XCTAssertEqual(seenAllowInteraction, [true, false])
    }

    private func makeCredentialPayload(
        accessToken: String,
        expiresAt: Any? = nil,
        scopes: [String]? = nil
    ) -> Data {
        var oauth: [String: Any] = [
            "accessToken": accessToken,
        ]
        if let expiresAt {
            oauth["expiresAt"] = expiresAt
        }
        if let scopes {
            oauth["scopes"] = scopes
        }

        let payload: [String: Any] = [
            "claudeAiOauth": oauth,
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func makeCredentialJSON(
        accessToken: String,
        expiresAt: Any? = nil,
        scopes: [String]? = nil
    ) -> [String: Any] {
        let data = makeCredentialPayload(accessToken: accessToken, expiresAt: expiresAt, scopes: scopes)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    // MARK: - Cached token

    func testCachedOAuthTokenIsReadBackInTheSameRun() {
        KeychainManager.cacheOAuthToken("token-a")

        XCTAssertEqual(KeychainManager.getCachedOAuthToken(), "token-a")
    }

    func testClearingTheCachedOAuthTokenForgetsIt() {
        KeychainManager.cacheOAuthToken("token-a")

        KeychainManager.clearCachedOAuthToken()

        XCTAssertNil(KeychainManager.getCachedOAuthToken())
    }

    // Writing notchi's own keychain item prompts whenever notchi's code signature changes.
    func testCachingTheOAuthTokenLeavesTheKeychainAlone() {
        KeychainManager.clearCachedOAuthToken()

        KeychainManager.cacheOAuthToken("token-a")

        XCTAssertEqual(KeychainManager.keychainWritesForTesting, 0)
    }

    // MARK: - Claude accounts

    // Expected suffixes are the first 8 hex digits of `printf '%s' <path> | shasum -a 256`.
    private static let workAccountPath = "/Users/someone/.claude-work"
    private static let workAccountService = "Claude Code-credentials-18cc900a"
    private static let workAccountPathWithSlashService = "Claude Code-credentials-fb460960"

    func testDefaultAccountUsesTheUnsuffixedCredentialsService() {
        XCTAssertEqual(KeychainManager.claudeCredentialsService(forConfigDir: nil), "Claude Code-credentials")
    }

    func testEmptyConfigDirCountsAsTheDefaultAccount() {
        XCTAssertEqual(KeychainManager.claudeCredentialsService(forConfigDir: ""), "Claude Code-credentials")
    }

    func testConfigDirIsHashedIntoTheCredentialsServiceName() {
        XCTAssertEqual(KeychainManager.claudeCredentialsService(forConfigDir: Self.workAccountPath), Self.workAccountService)
    }

    func testConfigDirIsHashedExactlyAsWritten() {
        XCTAssertEqual(
            KeychainManager.claudeCredentialsService(forConfigDir: Self.workAccountPath + "/"),
            Self.workAccountPathWithSlashService
        )
    }

    // `printf '%s' "/Users/someone/.claude-café" | shasum -a 256` with é precomposed; Claude Code
    // NFC-normalizes the folder before hashing, so a decomposed é names the same login.
    private static let accentedPathService = "Claude Code-credentials-e7e7d1c8"

    func testDecomposedAccentNamesTheSameLoginAsClaudeCode() {
        XCTAssertEqual(KeychainManager.claudeCredentialsService(forConfigDir: "/Users/someone/.claude-cafe\u{301}"), Self.accentedPathService)
    }

    func testOneAccountsMissingLoginDoesNotSkipTheCLIReadForAnother() {
        var cliReads = 0
        KeychainManager._setSecurityCLIReadOverrideForTesting {
            cliReads += 1
            return cliReads == 1 ? nil : ["claudeAiOauth": ["accessToken": "work-token"]]
        }
        KeychainManager._setSecurityFrameworkReadOverrideForTesting { _ in nil }
        _ = KeychainManager.getOAuthCredentials(allowInteraction: false)

        let work = KeychainManager.getOAuthCredentials(service: Self.workAccountService, allowInteraction: false)

        XCTAssertEqual(work?.accessToken, "work-token")
    }

    func testCachedTokensAreKeptPerAccount() {
        KeychainManager.cacheOAuthToken("work-token", service: Self.workAccountService)
        KeychainManager.cacheOAuthToken("default-token")

        XCTAssertEqual(KeychainManager.getCachedOAuthToken(service: Self.workAccountService), "work-token")
    }

    func testRecentCredentialsAreKeptPerAccount() throws {
        KeychainManager._setSecurityCLIReadOverrideForTesting { ["claudeAiOauth": ["accessToken": "default-token"]] }
        _ = KeychainManager.getOAuthCredentials(allowInteraction: false)
        KeychainManager._setSecurityCLIReadOverrideForTesting { ["claudeAiOauth": ["accessToken": "work-token"]] }

        let work = KeychainManager.getOAuthCredentials(service: Self.workAccountService, allowInteraction: false)

        XCTAssertEqual(work?.accessToken, "work-token")
    }
}

extension KeychainManager {
    static func decodeClaudeOAuthCredentials(from data: Data) -> ClaudeOAuthCredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return decodeClaudeOAuthCredentials(from: json)
    }
}
