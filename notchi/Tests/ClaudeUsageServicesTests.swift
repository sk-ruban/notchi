import Foundation
import XCTest
@testable import notchi

@MainActor
final class ClaudeUsageServicesTests: XCTestCase {
    private static let workAccount = ClaudeUsageAccount(
        credentialsService: "Claude Code-credentials-18cc900a",
        storageSuffix: "18cc900a"
    )
    private static let personalAccount = ClaudeUsageAccount(
        credentialsService: "Claude Code-credentials-b1b2c3d4",
        storageSuffix: "b1b2c3d4"
    )

    private var defaultService: ClaudeUsageService!
    private var createdAccounts: [ClaudeUsageAccount] = []
    private var credentialReads: [ClaudeUsageAccount] = []

    private func makeRegistry(isUsageEnabled: Bool = false) -> ClaudeUsageServices {
        defaultService = ClaudeUsageService(dependencies: Self.inertDependencies())
        return ClaudeUsageServices(
            defaultService: defaultService,
            isUsageEnabled: { isUsageEnabled },
            makeService: { [unowned self] account in
                createdAccounts.append(account)
                return ClaudeUsageService(dependencies: Self.inertDependencies { [unowned self] in credentialReads.append(account) })
            }
        )
    }

    /// Lets the polling tasks the registry started read credentials.
    private func settle() async {
        for _ in 0..<Self.settleYields { await Task.yield() }
    }

    private static let settleYields = 20

    private static func inertDependencies(onCredentialRead: @escaping () -> Void = {}) -> ClaudeUsageServiceDependencies {
        ClaudeUsageServiceDependencies(
            fetchUsage: { _ in throw URLError(.notConnectedToInternet) },
            getOAuthTokenFromEnvironment: { nil },
            getCachedOAuthToken: { nil },
            getOAuthCredentials: { _ in onCredentialRead(); return nil },
            cacheOAuthToken: { _ in },
            refreshAccessTokenSilently: { nil },
            clearCachedOAuthToken: {},
            loadRecoverySnapshot: { nil },
            saveRecoverySnapshot: { _ in },
            clearRecoverySnapshot: {},
            resolveUserAgent: { nil },
            pollJitter: { 0 },
            now: { Date() },
            schedulePoll: { _, _ in InertPollTimer() },
            isUsageEnabled: { false },
            setUsageEnabled: { _ in },
            loadExtraUsageObservation: { nil },
            saveExtraUsageObservation: { _ in }
        )
    }

    private func makeAccounts() throws -> (store: ClaudeAccountStore, home: URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageServicesTests-\(UUID().uuidString)", isDirectory: true)
        for folder in [".claude", ".claude-personal"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(folder).appendingPathComponent("projects"),
                withIntermediateDirectories: true
            )
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let suiteName = "ClaudeUsageServicesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let store = ClaudeAccountStore(
            home: home,
            defaultDirectory: { home.appendingPathComponent(".claude", isDirectory: true) },
            defaults: defaults,
            setClaudeHooksEnabled: { _ in },
            removeSharedScript: {},
            hasNotchiHooks: { _ in true },
            addHooks: { _ in true },
            removeHooks: { _ in },
            accountsDidChange: { _ in },
            costAccountsDidChange: { _ in }
        )
        store.refresh()
        return (store, home)
    }

    func testUsagePageOpensOnTheAccountOfTheSessionItWasOpenedFrom() throws {
        let (accounts, home) = try makeAccounts()
        let personal = SessionData(sessionId: "personal", provider: .claude, cwd: "/tmp")
        personal.updateClaudeAccount(
            configDir: home.appendingPathComponent(".claude-personal").path,
            transcriptPath: home.appendingPathComponent(".claude-personal/projects/-tmp/1b2c.jsonl").path
        )

        let account = makeRegistry().account(forSession: personal, accounts: accounts)

        XCTAssertEqual(account?.directory.lastPathComponent, ".claude-personal")
    }

    func testUsagePageWithoutAClaudeSessionOpensOnTheMostRecentlyActiveAccount() throws {
        let (accounts, home) = try makeAccounts()
        accounts.noteSession(directory: home.appendingPathComponent(".claude-personal"), rawConfigDir: nil)
        let codex = SessionData(sessionId: "codex", provider: .codex, cwd: "/tmp")

        let account = makeRegistry().account(forSession: codex, accounts: accounts)

        XCTAssertEqual(account?.directory.lastPathComponent, ".claude-personal")
    }

    func testDefaultAccountUsesTheSharedService() {
        let registry = makeRegistry()

        XCTAssertTrue(registry.service(for: .default) === defaultService)
    }

    func testAnAccountKeepsTheSameServiceAcrossLookups() {
        let registry = makeRegistry()
        registry.sync(with: [.default, Self.workAccount])

        XCTAssertTrue(registry.service(for: Self.workAccount) === registry.service(for: Self.workAccount))
    }

    func testSyncCreatesAServicePerAccountWithNotchiOn() {
        let registry = makeRegistry()

        registry.sync(with: [.default, Self.workAccount, Self.personalAccount])

        XCTAssertEqual(Set(createdAccounts), [Self.workAccount, Self.personalAccount])
    }

    func testSyncDropsServicesForAccountsSwitchedOff() {
        let registry = makeRegistry()
        registry.sync(with: [.default, Self.workAccount, Self.personalAccount])

        registry.sync(with: [.default, Self.workAccount])

        XCTAssertEqual(registry.trackedAccounts, [Self.workAccount])
    }

    func testLookingUpASwitchedOffAccountDoesNotPollIt() async {
        let registry = makeRegistry(isUsageEnabled: true)
        registry.sync(with: [.default, Self.workAccount])
        registry.sync(with: [.default])

        _ = registry.service(for: Self.workAccount)
        registry.startPolling()
        await settle()

        XCTAssertEqual(credentialReads, [Self.workAccount])
    }

    func testAnAccountLookedUpBeforeItsSwitchIsOnStartsPollingWhenSynced() async {
        let registry = makeRegistry(isUsageEnabled: true)
        _ = registry.service(for: Self.workAccount)

        registry.sync(with: [.default, Self.workAccount])
        await settle()

        XCTAssertEqual(credentialReads, [Self.workAccount])
    }

    func testConnectingReadsEveryAccountsLoginAgain() async {
        let registry = makeRegistry()
        registry.sync(with: [.default, Self.workAccount, Self.personalAccount])

        registry.connectAndStartPolling()
        await settle()

        XCTAssertEqual(Set(credentialReads), [Self.workAccount, Self.personalAccount])
    }

    func testSyncingTheSameAccountsAgainCreatesNoNewServices() {
        let registry = makeRegistry()
        registry.sync(with: [.default, Self.workAccount])

        registry.sync(with: [.default, Self.workAccount])

        XCTAssertEqual(createdAccounts, [Self.workAccount])
    }

    func testUsageIsConnectedWhenOnlyAnotherAccountWithNotchiOnIsConnected() {
        let registry = makeRegistry()
        registry.sync(with: [.default, Self.workAccount])

        registry.service(for: Self.workAccount).isConnected = true

        XCTAssertTrue(registry.isAnyAccountConnected)
    }

    func testUsageIsConnectedWhenOnlyTheDefaultAccountIsConnected() {
        let registry = makeRegistry()
        registry.sync(with: [.default, Self.workAccount])

        defaultService.isConnected = true

        XCTAssertTrue(registry.isAnyAccountConnected)
    }

    func testUsageIsNotConnectedWhenOnlyASwitchedOffAccountIsConnected() {
        let registry = makeRegistry()

        registry.service(for: Self.workAccount).isConnected = true

        XCTAssertFalse(registry.isAnyAccountConnected)
    }
}

private struct InertPollTimer: UsagePollTimer {
    func invalidate() {}
}
