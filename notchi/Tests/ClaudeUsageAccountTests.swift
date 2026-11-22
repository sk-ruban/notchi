import Foundation
import XCTest
@testable import notchi

@MainActor
final class ClaudeUsageAccountTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var globalUsageEnabled = true

    private static let workAccount = ClaudeUsageAccount(
        credentialsService: "Claude Code-credentials-18cc900a",
        storageSuffix: "18cc900a"
    )
    private static let personalAccount = ClaudeUsageAccount(
        credentialsService: "Claude Code-credentials-b1b2c3d4",
        storageSuffix: "b1b2c3d4"
    )

    override func setUp() {
        super.setUp()
        suiteName = "ClaudeUsageAccountTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private var hasOtherAccounts = false

    private func dependencies(for account: ClaudeUsageAccount) -> ClaudeUsageServiceDependencies {
        ClaudeUsageServiceDependencies.live(
            for: account,
            defaults: defaults,
            isGlobalUsageEnabled: { [unowned self] in globalUsageEnabled },
            setGlobalUsageEnabled: { [unowned self] in globalUsageEnabled = $0 },
            hasOtherAccountsWithNotchi: { [unowned self] in hasOtherAccounts }
        )
    }

    func testDefaultLoginFailingTurnsUsageOffWhenItIsTheOnlyAccount() {
        dependencies(for: .default).setUsageEnabled(false)

        XCTAssertFalse(globalUsageEnabled)
    }

    func testDefaultLoginFailingLeavesTheOtherAccountsUsageOn() {
        hasOtherAccounts = true

        dependencies(for: .default).setUsageEnabled(false)

        XCTAssertTrue(dependencies(for: Self.workAccount).isUsageEnabled())
    }

    func testDefaultLoginFailingTurnsOnlyTheDefaultAccountOffWhenOthersRunNotchi() {
        hasOtherAccounts = true

        dependencies(for: .default).setUsageEnabled(false)

        XCTAssertFalse(dependencies(for: .default).isUsageEnabled())
    }

    func testReconnectingTheDefaultLoginTurnsUsageBackOn() {
        let defaultAccount = dependencies(for: .default)
        defaultAccount.setUsageEnabled(false)

        defaultAccount.setUsageEnabled(true)

        XCTAssertTrue(defaultAccount.isUsageEnabled())
    }

    func testTurningOffAnotherAccountsUsageLeavesTheGlobalSwitchOn() {
        dependencies(for: Self.workAccount).setUsageEnabled(false)

        XCTAssertTrue(globalUsageEnabled)
    }

    func testTurningOffOneAccountsUsageLeavesTheOthersOn() {
        dependencies(for: Self.workAccount).setUsageEnabled(false)

        XCTAssertTrue(dependencies(for: Self.personalAccount).isUsageEnabled())
    }

    func testAccountUsageIsOffWhileTheGlobalSwitchIsOff() {
        globalUsageEnabled = false

        XCTAssertFalse(dependencies(for: Self.workAccount).isUsageEnabled())
    }

    func testAccountUsageComesBackOnWhenItsLoginWorksAgain() {
        let work = dependencies(for: Self.workAccount)
        work.setUsageEnabled(false)

        work.setUsageEnabled(true)

        XCTAssertTrue(work.isUsageEnabled())
    }

    private func snapshot(headersFallbackActive: Bool) -> ClaudeUsageRecoverySnapshot {
        ClaudeUsageRecoverySnapshot(
            oauthBackoffUntil: nil,
            oauthHeadersFallbackProbeUntil: nil,
            isHeadersFallbackActive: headersFallbackActive,
            lastGoodUsage: nil,
            lastGoodWeeklyUsage: nil,
            lastGoodModelUsage: nil,
            lastGoodModelUsageName: nil,
            lastGoodExtraUsage: nil,
            lastObservedExtraUsageCredits: nil,
            extraUsageResetMarker: nil,
            isUsingExtraUsage: nil
        )
    }

    func testRecoverySnapshotsAreKeptPerAccount() {
        dependencies(for: Self.workAccount).saveRecoverySnapshot(snapshot(headersFallbackActive: true))

        XCTAssertNil(dependencies(for: Self.personalAccount).loadRecoverySnapshot())
    }

    func testAccountWithoutAStorageSuffixReadsTheDefaultAccountsSnapshotKey() {
        defaults.set(try? JSONEncoder().encode(snapshot(headersFallbackActive: true)), forKey: "claudeUsageRecoverySnapshot")

        let loaded = dependencies(for: .default).loadRecoverySnapshot()

        XCTAssertEqual(loaded?.isHeadersFallbackActive, true)
    }
}
