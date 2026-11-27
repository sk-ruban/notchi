import Foundation
import XCTest
@testable import notchi

@MainActor
final class EmotionAnalysisCredentialsTests: XCTestCase {
    private static let storedKey = "sk-stored"
    private static let savedKey = "sk-saved"

    private var keychainReads: [(provider: EmotionAnalysisProvider, allowInteraction: Bool)] = []
    private var keychainWrites: [String?] = []
    private var settingsLoads = 0
    private var settingsDirectory: URL!

    override func setUpWithError() throws {
        settingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmotionAnalysisCredentialsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: settingsDirectory)
    }

    func testStoredKeyIsReadFromTheKeychainOnlyOnce() {
        let expectedReadCount = 1
        let credentials = makeCredentials(keychain: { _ in Self.storedKey })

        _ = credentials.apiKey(for: .claude)
        _ = credentials.apiKey(for: .claude)

        XCTAssertEqual(keychainReads.count, expectedReadCount)
    }

    func testMissingKeyIsReadFromTheKeychainOnlyOnce() {
        let expectedReadCount = 1
        let credentials = makeCredentials(keychain: { _ in nil })

        _ = credentials.apiKey(for: .openAI)
        _ = credentials.apiKey(for: .openAI)

        XCTAssertEqual(keychainReads.count, expectedReadCount)
    }

    func testInteractiveReadRetriesAKeyANonInteractiveReadMissed() {
        let credentials = makeCredentials(keychain: { allowInteraction in allowInteraction ? Self.storedKey : nil })

        _ = credentials.apiKey(for: .claude, allowInteraction: false)

        XCTAssertEqual(credentials.apiKey(for: .claude, allowInteraction: true), Self.storedKey)
    }

    func testSavedKeyIsServedWithoutReadingTheKeychain() {
        let expectedReadCount = 0
        let credentials = makeCredentials(keychain: { _ in Self.storedKey })

        credentials.setApiKey(Self.savedKey, for: .claude)
        _ = credentials.apiKey(for: .claude, allowInteraction: true)

        XCTAssertEqual(keychainReads.count, expectedReadCount)
    }

    func testClearedKeyIsServedAsMissing() {
        let credentials = makeCredentials(keychain: { _ in Self.storedKey })
        _ = credentials.apiKey(for: .claude)

        credentials.setApiKey(nil, for: .claude)

        XCTAssertNil(credentials.apiKey(for: .claude, allowInteraction: true))
    }

    func testSavingAKeyWritesItToTheKeychain() {
        let expectedWrites: [String?] = [Self.savedKey]
        let credentials = makeCredentials(keychain: { _ in nil })

        credentials.setApiKey(Self.savedKey, for: .openAI)

        XCTAssertEqual(keychainWrites, expectedWrites)
    }

    func testSavingAKeyChangesTheRevision() {
        let expectedRevision = 1
        let credentials = makeCredentials(keychain: { _ in nil })

        credentials.setApiKey(Self.savedKey, for: .claude)

        XCTAssertEqual(credentials.revision, expectedRevision)
    }

    func testUnchangedClaudeSettingsAreLoadedOnlyOnce() throws {
        let expectedLoadCount = 1
        try writeSettings(authToken: "token-one")
        let credentials = makeCredentials(keychain: { _ in nil })

        _ = credentials.claudeSettingsConfig()
        _ = credentials.claudeSettingsConfig()

        XCTAssertEqual(settingsLoads, expectedLoadCount)
    }

    func testChangedClaudeSettingsAreLoadedAgain() throws {
        let expectedAuthToken = "token-replaced"
        try writeSettings(authToken: "token-one")
        let credentials = makeCredentials(keychain: { _ in nil })
        _ = credentials.claudeSettingsConfig()

        try writeSettings(authToken: expectedAuthToken)

        XCTAssertEqual(credentials.claudeSettingsConfig()?.apiKey, expectedAuthToken)
    }

    func testClaudeSettingsCreatedAfterAMissAreLoaded() throws {
        let expectedAuthToken = "token-created"
        let credentials = makeCredentials(keychain: { _ in nil })
        XCTAssertNil(credentials.claudeSettingsConfig(), "precondition: no settings.json yet")

        try writeSettings(authToken: expectedAuthToken)

        XCTAssertEqual(credentials.claudeSettingsConfig()?.apiKey, expectedAuthToken)
    }

    func testChangedTargetOfSymlinkedClaudeSettingsIsLoadedAgain() throws {
        let expectedAuthToken = "token-two"
        let targetURL = settingsDirectory.appendingPathComponent("dotfiles-settings.json")
        try writeSettings(authToken: "token-one", to: targetURL)
        try FileManager.default.createSymbolicLink(at: settingsURL, withDestinationURL: targetURL)
        let credentials = makeCredentials(keychain: { _ in nil })
        _ = credentials.claudeSettingsConfig()

        try writeSettings(authToken: expectedAuthToken, to: targetURL)

        XCTAssertEqual(credentials.claudeSettingsConfig()?.apiKey, expectedAuthToken)
    }

    private var settingsURL: URL {
        settingsDirectory.appendingPathComponent("settings.json")
    }

    private func makeCredentials(keychain: @escaping (Bool) -> String?) -> EmotionAnalysisCredentials {
        EmotionAnalysisCredentials(
            readKey: { [unowned self] provider, allowInteraction in
                keychainReads.append((provider, allowInteraction))
                return keychain(allowInteraction)
            },
            writeKey: { [unowned self] key, _ in keychainWrites.append(key) },
            claudeSettingsURL: { [unowned self] in settingsURL },
            loadClaudeSettings: { [unowned self] url in
                settingsLoads += 1
                return ClaudeSettingsConfig.load(from: url)
            }
        )
    }

    private func writeSettings(authToken: String, to url: URL? = nil) throws {
        let data = try JSONSerialization.data(withJSONObject: ["env": ["ANTHROPIC_AUTH_TOKEN": authToken]])
        try data.write(to: url ?? settingsURL)
    }
}
