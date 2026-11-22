import Foundation
import XCTest
@testable import notchi

@MainActor
final class ClaudeAccountStoreTests: XCTestCase {
    private var home: URL!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var claudeHooksEnabled = true
    private var sharedScriptRemovals = 0
    private var addHooksSucceeds = true
    private var removeHooksSucceeds = true
    private var accountsWithHooks: Set<String> = []
    private var addedHooks: [String] = []
    private var removedHooks: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeAccountStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defaultsSuiteName = "ClaudeAccountStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeAccount(_ name: String, marker: String = "projects") throws -> URL {
        let directory = home.appendingPathComponent(name, isDirectory: true)
        let markerURL = directory.appendingPathComponent(marker)
        if marker.hasSuffix(".json") {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: markerURL)
        } else {
            try FileManager.default.createDirectory(at: markerURL, withIntermediateDirectories: true)
        }
        return directory
    }

    private func makeStore() -> ClaudeAccountStore {
        let store = ClaudeAccountStore(
            home: home,
            defaultDirectory: { [home] in home!.appendingPathComponent(".claude", isDirectory: true) },
            defaults: defaults,
            setClaudeHooksEnabled: { [unowned self] enabled in claudeHooksEnabled = enabled },
            removeSharedScript: { [unowned self] in sharedScriptRemovals += 1 },
            hasNotchiHooks: { [unowned self] directory in accountsWithHooks.contains(directory.lastPathComponent) },
            addHooks: { [unowned self] directory in
                guard addHooksSucceeds else { return false }
                addedHooks.append(directory.lastPathComponent)
                accountsWithHooks.insert(directory.lastPathComponent)
                return true
            },
            removeHooks: { [unowned self] directory in
                guard removeHooksSucceeds else { return }
                removedHooks.append(directory.lastPathComponent)
                accountsWithHooks.remove(directory.lastPathComponent)
            },
            accountsDidChange: { _ in }
        )
        store.refresh()
        return store
    }

    private func account(_ folder: String, in store: ClaudeAccountStore) throws -> ClaudeAccount {
        try XCTUnwrap(store.accounts.first { $0.directory.lastPathComponent == folder })
    }

    // MARK: - Finding accounts

    func testDefaultAccountIsListedFirst() throws {
        try makeAccount(".claude-personal", marker: ".claude.json")
        try makeAccount(".claude")

        XCTAssertEqual(makeStore().accounts.map(\.directory.lastPathComponent), [".claude", ".claude-personal"])
    }

    func testFoldersWithoutClaudeDataAreNotAccounts() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-server-commander", marker: "config.json")

        XCTAssertEqual(makeStore().accounts.map(\.directory.lastPathComponent), [".claude"])
    }

    func testSessionFromAFolderOutsideHomeAddsThatAccount() throws {
        try makeAccount(".claude")
        let elsewhere = home.appendingPathComponent("work/claude-config", isDirectory: true)
        let store = makeStore()

        store.noteSession(directory: elsewhere, rawConfigDir: elsewhere.path)

        XCTAssertEqual(store.account(forSessionDirectory: elsewhere)?.directory.path, elsewhere.path)
    }

    func testAccountSwitchedOnOutsideHomeIsListedAfterARestart() throws {
        try makeAccount(".claude")
        let elsewhere = home.appendingPathComponent("work/claude-config", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let firstRun = makeStore()
        firstRun.noteSession(directory: elsewhere, rawConfigDir: elsewhere.path)
        firstRun.setNotchiEnabled(true, for: try XCTUnwrap(firstRun.account(forSessionDirectory: elsewhere)))

        XCTAssertNotNil(makeStore().account(forSessionDirectory: elsewhere))
    }

    func testSessionWithoutAFolderBelongsToTheDefaultAccount() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-personal")

        XCTAssertEqual(makeStore().account(forSessionDirectory: nil)?.directory.lastPathComponent, ".claude")
    }

    // MARK: - Names and colors

    func testDefaultAccountIsNamedDefault() throws {
        try makeAccount(".claude")

        XCTAssertEqual(try account(".claude", in: makeStore()).name, "Default")
    }

    func testOtherAccountsAreNamedAfterTheirFolder() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-personal")
        try makeAccount(".claude_my-team")
        let store = makeStore()

        XCTAssertEqual(
            [try account(".claude-personal", in: store).name, try account(".claude_my-team", in: store).name],
            ["Personal", "My Team"]
        )
    }

    func testRenamedAccountKeepsItsNameAcrossLaunches() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-personal")
        makeStore().rename(try account(".claude-personal", in: makeStore()), to: "Side projects")

        XCTAssertEqual(try account(".claude-personal", in: makeStore()).name, "Side projects")
    }

    func testRenamingToBlankGoesBackToTheFolderName() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-personal")
        let store = makeStore()
        store.rename(try account(".claude-personal", in: store), to: "Side projects")

        store.rename(try account(".claude-personal", in: store), to: "   ")

        XCTAssertEqual(try account(".claude-personal", in: store).name, "Personal")
    }

    func testSavingAnUnchangedNameKeepsFollowingTheFolderName() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-personal")
        let store = makeStore()

        store.rename(try account(".claude-personal", in: store), to: "Personal")

        XCTAssertNil(ClaudeAccountStore.preferences(in: defaults).values.first?.name)
    }

    func testAnAccountKeepsItsColorWhenANewAccountAppears() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-personal")
        let colorBefore = try account(".claude-personal", in: makeStore()).color
        try makeAccount(".claude-alpha")

        XCTAssertEqual(try account(".claude-personal", in: makeStore()).color, colorBefore)
    }

    func testAccountsStartWithTheFirstPaletteColorsInOrder() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-personal")
        try makeAccount(".claude-work")

        XCTAssertEqual(makeStore().accounts.map(\.color), [.orange, .blue, .green])
    }

    func testChosenColorIsKeptAcrossLaunches() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-personal")
        let chosen = ClaudeAccountColor.pink
        makeStore().setColor(chosen, for: try account(".claude-personal", in: makeStore()))

        XCTAssertEqual(try account(".claude-personal", in: makeStore()).color, chosen)
    }

    // MARK: - notchi per account

    func testSwitchingOnAnAccountAddsNotchiHooksThere() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-personal")
        let store = makeStore()

        store.setNotchiEnabled(true, for: try account(".claude-personal", in: store))

        XCTAssertEqual(addedHooks, [".claude-personal"])
    }

    func testSwitchingOnAnAccountIsRememberedForReinstalls() throws {
        try makeAccount(".claude")
        let personal = try makeAccount(".claude-personal")
        let store = makeStore()

        store.setNotchiEnabled(true, for: try account(".claude-personal", in: store))

        XCTAssertEqual(
            ClaudeAccountStore.accountDirectoriesWithNotchi(in: defaults).map(\.path),
            [personal.resolvingSymlinksInPath().path]
        )
    }

    func testSwitchingOffAnAccountRemovesNotchiHooksThere() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-personal")
        accountsWithHooks = [".claude-personal"]
        let store = makeStore()

        store.setNotchiEnabled(false, for: try account(".claude-personal", in: store))

        XCTAssertEqual(removedHooks, [".claude-personal"])
    }

    func testAccountShowsSwitchedOnWhenItsSettingsRunNotchi() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-personal")
        accountsWithHooks = [".claude-personal"]

        XCTAssertTrue(try account(".claude-personal", in: makeStore()).isNotchiEnabled)
    }

    func testDefaultAccountCanBeSwitchedOffOnItsOwn() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-personal")
        accountsWithHooks = [".claude", ".claude-personal"]
        let store = makeStore()

        store.setNotchiEnabled(false, for: try account(".claude", in: store))

        XCTAssertEqual(store.accounts.map(\.isNotchiEnabled), [false, true])
    }

    func testSwitchingOnAnAccountTurnsClaudeHooksOn() throws {
        try makeAccount(".claude")
        claudeHooksEnabled = false
        let store = makeStore()

        store.setNotchiEnabled(true, for: try account(".claude", in: store))

        XCTAssertTrue(claudeHooksEnabled)
    }

    func testSwitchingOffTheLastAccountTurnsClaudeHooksOff() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-personal")
        accountsWithHooks = [".claude-personal"]
        let store = makeStore()

        store.setNotchiEnabled(false, for: try account(".claude-personal", in: store))

        XCTAssertFalse(claudeHooksEnabled)
    }

    func testSwitchingOffTheLastAccountRemovesTheSharedScript() throws {
        try makeAccount(".claude")
        accountsWithHooks = [".claude"]
        let store = makeStore()

        store.setNotchiEnabled(false, for: try account(".claude", in: store))

        XCTAssertEqual(sharedScriptRemovals, 1)
    }

    func testSwitchingOffOneOfTwoAccountsKeepsClaudeHooksOn() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-personal")
        accountsWithHooks = [".claude", ".claude-personal"]
        let store = makeStore()

        store.setNotchiEnabled(false, for: try account(".claude-personal", in: store))

        XCTAssertTrue(claudeHooksEnabled)
    }

    func testSwitchingOffOneOfTwoAccountsKeepsTheSharedScript() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-personal")
        accountsWithHooks = [".claude", ".claude-personal"]
        let store = makeStore()

        store.setNotchiEnabled(false, for: try account(".claude-personal", in: store))

        XCTAssertEqual(sharedScriptRemovals, 0)
    }

    func testFailedSwitchOnLeavesTheAccountOff() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-personal")
        addHooksSucceeds = false
        let store = makeStore()

        XCTAssertFalse(store.setNotchiEnabled(true, for: try account(".claude-personal", in: store)))
    }

    func testFailedSwitchOffReportsFailure() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-personal")
        accountsWithHooks = [".claude", ".claude-personal"]
        removeHooksSucceeds = false
        let store = makeStore()

        XCTAssertFalse(store.setNotchiEnabled(false, for: try account(".claude-personal", in: store)))
    }

    func testAccountThatStartedRunningNotchiShowsOnWhenItsFirstSessionArrives() throws {
        try makeAccount(".claude")
        let work = try makeAccount(".claude-work")
        accountsWithHooks = [".claude"]
        let store = makeStore()
        accountsWithHooks.insert(".claude-work")

        store.noteSession(directory: work, rawConfigDir: work.path)

        XCTAssertTrue(store.showsAccountBadges)
    }

    // An account can run notchi without being in the saved list, e.g. one outside `~` seen in a session.
    func testSwitchingOffTheDefaultAccountKeepsItOffAtTheNextLaunch() throws {
        try makeAccount(".claude")
        let elsewhere = home.appendingPathComponent("work/claude-config", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        accountsWithHooks = [".claude", "claude-config"]
        ClaudeAccountStore.trackDefaultAccountIfNeeded(home.appendingPathComponent(".claude"), in: defaults)
        let store = makeStore()
        store.noteSession(directory: elsewhere, rawConfigDir: elsewhere.path)

        store.setNotchiEnabled(false, for: try account(".claude", in: store))

        let atNextLaunch = ClaudeAccountStore.accountsToInstall(
            defaultDirectory: home.appendingPathComponent(".claude"),
            migrated: [],
            in: defaults
        )
        XCTAssertEqual(atNextLaunch.map(\.lastPathComponent), ["claude-config"])
    }

    // MARK: - Usage

    // The first 8 hex digits of `printf '%s' "/Users/someone/.claude-work/" | shasum -a 256`.
    private static let reportedConfigDir = "/Users/someone/.claude-work/"
    private static let reportedConfigDirService = "Claude Code-credentials-fb460960"

    func testDefaultAccountReadsTheDefaultLogin() throws {
        try makeAccount(".claude")

        XCTAssertEqual(makeStore().usageAccount(for: try account(".claude", in: makeStore())), .default)
    }

    func testAccountReadsTheLoginNamedAfterTheConfigDirItsSessionsReport() throws {
        try makeAccount(".claude")
        let work = try makeAccount(".claude-work")
        let store = makeStore()

        store.noteSession(directory: work, rawConfigDir: Self.reportedConfigDir)

        XCTAssertEqual(store.usageAccount(for: try account(".claude-work", in: store)).credentialsService, Self.reportedConfigDirService)
    }

    // The first 8 hex digits of `printf '%s' "/Users/someone/.claude-work" | shasum -a 256`.
    private static let respelledConfigDir = "/Users/someone/.claude-work"
    private static let respelledConfigDirService = "Claude Code-credentials-18cc900a"

    func testAccountFollowsALaterSessionThatSpellsItsConfigDirDifferently() throws {
        try makeAccount(".claude")
        let work = try makeAccount(".claude-work")
        let store = makeStore()
        store.noteSession(directory: work, rawConfigDir: Self.reportedConfigDir)

        store.noteSession(directory: work, rawConfigDir: Self.respelledConfigDir)

        XCTAssertEqual(store.usageAccount(for: try account(".claude-work", in: store)).credentialsService, Self.respelledConfigDirService)
    }

    func testALaterLoginForTheSameFolderKeepsItsOwnSavedUsageState() throws {
        try makeAccount(".claude")
        let work = try makeAccount(".claude-work")
        let store = makeStore()
        store.noteSession(directory: work, rawConfigDir: Self.reportedConfigDir)
        let firstLogin = store.usageAccount(for: try account(".claude-work", in: store)).storageSuffix

        store.noteSession(directory: work, rawConfigDir: Self.respelledConfigDir)

        XCTAssertNotEqual(store.usageAccount(for: try account(".claude-work", in: store)).storageSuffix, firstLogin)
    }

    func testReportedConfigDirIsRememberedAcrossLaunches() throws {
        try makeAccount(".claude")
        let work = try makeAccount(".claude-work")
        makeStore().noteSession(directory: work, rawConfigDir: Self.reportedConfigDir)

        let store = makeStore()

        XCTAssertEqual(store.usageAccount(for: try account(".claude-work", in: store)).credentialsService, Self.reportedConfigDirService)
    }

    func testAccountWithoutSessionsReadsTheLoginNamedAfterItsFolder() throws {
        try makeAccount(".claude")
        let work = try makeAccount(".claude-work")
        let store = makeStore()

        XCTAssertEqual(
            store.usageAccount(for: try account(".claude-work", in: store)).credentialsService,
            KeychainManager.claudeCredentialsService(forConfigDir: work.path)
        )
    }

    func testDefaultAccountWithAConfigDirKeepsItsUsageStateApart() throws {
        let defaultFolder = try makeAccount(".claude")
        let store = makeStore()

        store.noteSession(directory: defaultFolder, rawConfigDir: defaultFolder.path)

        XCTAssertNotNil(store.usageAccount(for: try account(".claude", in: store)).storageSuffix)
    }

    func testAccountsKeepTheirUsageStateApart() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-work")
        let store = makeStore()

        XCTAssertNotNil(store.usageAccount(for: try account(".claude-work", in: store)).storageSuffix)
    }

    func testMostRecentlyActiveAccountFollowsTheLatestSession() throws {
        try makeAccount(".claude")
        let work = try makeAccount(".claude-work")
        let store = makeStore()
        store.noteSession(directory: home.appendingPathComponent(".claude"), rawConfigDir: nil)

        store.noteSession(directory: work, rawConfigDir: Self.reportedConfigDir)

        XCTAssertEqual(store.mostRecentlyActiveAccount?.directory.lastPathComponent, ".claude-work")
    }

    // MARK: - Launch install

    func testFirstLaunchAfterUpdateInstallsTheDefaultAccount() {
        let defaultDirectory = home.appendingPathComponent(".claude")

        let accounts = ClaudeAccountStore.accountsToInstall(defaultDirectory: defaultDirectory, migrated: [], in: defaults)

        XCTAssertEqual(accounts.map(\.lastPathComponent), [".claude"])
    }

    func testLaunchAfterEveryAccountWasSwitchedOffInstallsNone() throws {
        try makeAccount(".claude")
        accountsWithHooks = [".claude"]
        ClaudeAccountStore.trackDefaultAccountIfNeeded(home.appendingPathComponent(".claude"), in: defaults)
        let store = makeStore()
        store.setNotchiEnabled(false, for: try account(".claude", in: store))

        let accounts = ClaudeAccountStore.accountsToInstall(
            defaultDirectory: home.appendingPathComponent(".claude"),
            migrated: [],
            in: defaults
        )

        XCTAssertEqual(accounts, [])
    }

    func testLaunchAdoptsAccountsAlreadyRunningNotchi() {
        let defaultDirectory = home.appendingPathComponent(".claude")
        let personal = home.appendingPathComponent(".claude-personal")

        let accounts = ClaudeAccountStore.accountsToInstall(defaultDirectory: defaultDirectory, migrated: [personal], in: defaults)

        XCTAssertEqual(accounts.map(\.lastPathComponent).sorted(), [".claude", ".claude-personal"])
    }

    // MARK: - Badges

    func testBadgesAreHiddenWithOneAccountSwitchedOn() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-personal")
        accountsWithHooks = [".claude"]

        XCTAssertFalse(makeStore().showsAccountBadges)
    }

    func testBadgesShowWithTwoAccountsSwitchedOn() throws {
        try makeAccount(".claude")
        try makeAccount(".claude-personal")
        accountsWithHooks = [".claude", ".claude-personal"]

        XCTAssertTrue(makeStore().showsAccountBadges)
    }
}
