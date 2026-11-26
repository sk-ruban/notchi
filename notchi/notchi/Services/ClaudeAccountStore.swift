import CryptoKit
import Foundation
import Observation

/// The Claude Code accounts (config directories) on this Mac, with the name, color and
/// per-account notchi switch the user picked for each.
@MainActor @Observable
final class ClaudeAccountStore {
    // Empty until the launch refresh after the hooks install. Until then no session has an account, so
    // views show the default account either way, and a session's hook event refreshes on arrival.
    static let shared = ClaudeAccountStore()

    private(set) var accounts: [ClaudeAccount] = []
    private(set) var mostRecentlyActiveAccountKey: String?

    nonisolated private static let preferencesKey = "claudeAccountPreferences"
    nonisolated private static let accountsWithNotchiKey = "claudeAccountsWithNotchi"
    nonisolated private static let accountFolderPrefix = ".claude"
    // A real config dir holds transcripts or its own login state; other `.claude*` folders
    // (MCP servers and the like) have neither.
    nonisolated private static let accountMarkers = ["projects", ".claude.json"]
    private static let minimumAccountsForBadges = 2

    private let home: URL
    private let defaultDirectory: () -> URL
    private let defaults: UserDefaults
    private let setClaudeHooksEnabled: (Bool) -> Void
    private let removeSharedScript: () -> Void
    private let hasNotchiHooks: @Sendable (URL) -> Bool
    private let addHooks: (URL) -> Bool
    private let removeHooks: (URL) -> Void
    private let accountsDidChange: @MainActor ([ClaudeUsageAccount]) -> Void
    private let costAccountsDidChange: @MainActor ([ClaudeAccount]) -> Void
    private var sessionDirectories: Set<String> = []
    private var accountsByKey: [String: ClaudeAccount] = [:]
    private var keysBySessionPath: [String: String] = [:]
    private var accountKeysWithSessions: Set<String> = []
    private var reportedConfigDirs: [String: String?] = [:]
    @ObservationIgnored private var refreshGeneration = 0
    // Views look this up on every render; it only changes when preferences are saved.
    @ObservationIgnored private var usageAccountsByKey: [String: ClaudeUsageAccount] = [:]

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaultDirectory: @escaping () -> URL = { ClaudeConfigDirectoryResolver.resolveWithoutProbing() },
        defaults: UserDefaults = .standard,
        setClaudeHooksEnabled: @escaping (Bool) -> Void = { AppSettings.setHooksEnabled($0, for: .claude) },
        removeSharedScript: @escaping () -> Void = { HookInstaller.removeSharedScript() },
        hasNotchiHooks: @escaping @Sendable (URL) -> Bool = { HookInstaller.isHookInstalled(inAccount: $0) },
        addHooks: @escaping (URL) -> Bool = { HookInstaller.addHooks(toAccount: $0) },
        removeHooks: @escaping (URL) -> Void = { HookInstaller.removeHooks(fromAccount: $0) },
        accountsDidChange: @escaping @MainActor ([ClaudeUsageAccount]) -> Void = { ClaudeUsageServices.shared.sync(with: $0) },
        costAccountsDidChange: @escaping @MainActor ([ClaudeAccount]) -> Void = { ClaudeCostStores.shared.sync(with: $0) }
    ) {
        self.home = home
        self.defaultDirectory = defaultDirectory
        self.defaults = defaults
        self.setClaudeHooksEnabled = setClaudeHooksEnabled
        self.removeSharedScript = removeSharedScript
        self.hasNotchiHooks = hasNotchiHooks
        self.addHooks = addHooks
        self.removeHooks = removeHooks
        self.accountsDidChange = accountsDidChange
        self.costAccountsDidChange = costAccountsDidChange
    }

    // The isolated-deinit back-deploy shim aborts on macOS 15; this deinit only releases stored properties.
    nonisolated deinit {}

    var showsAccountBadges: Bool {
        accounts.filter(\.isNotchiEnabled).count >= Self.minimumAccountsForBadges
    }

    func refresh() {
        refreshGeneration &+= 1
        apply(Self.scanAccounts(
            home: home,
            defaultDirectory: defaultDirectory(),
            switchedOn: Self.accountDirectoriesWithNotchi(in: defaults),
            seenInSessions: sessionDirectories,
            hasNotchiHooks: hasNotchiHooks
        ))
    }

    /// `refresh` with the disk reads (the home folder and every account's settings) off the main thread.
    func refreshInBackground() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let home = home
        let defaultDirectory = defaultDirectory()
        let switchedOn = Self.accountDirectoriesWithNotchi(in: defaults)
        let seenInSessions = sessionDirectories
        let hasNotchiHooks = hasNotchiHooks
        let scan = await Task.detached(priority: .utility) {
            Self.scanAccounts(
                home: home,
                defaultDirectory: defaultDirectory,
                switchedOn: switchedOn,
                seenInSessions: seenInSessions,
                hasNotchiHooks: hasNotchiHooks
            )
        }.value
        // A refresh that ran meanwhile read newer sessions and settings than this scan did.
        guard generation == refreshGeneration else { return }
        apply(scan)
    }

    /// What `refresh` reads from disk: which folders are accounts, and which of them run notchi.
    nonisolated private struct AccountScan: Sendable {
        let defaultKey: String
        let orderedKeys: [String]
        let directoriesByKey: [String: URL]
        let keysWithNotchiHooks: Set<String>
    }

    nonisolated private static func scanAccounts(
        home: URL,
        defaultDirectory: URL,
        switchedOn: [URL],
        seenInSessions: Set<String>,
        hasNotchiHooks: (URL) -> Bool
    ) -> AccountScan {
        let defaultKey = key(for: defaultDirectory)
        var directoriesByKey: [String: URL] = [defaultKey: defaultDirectory]
        let existingSwitchedOn = switchedOn.filter { FileManager.default.fileExists(atPath: $0.path) }
        let sessionURLs = seenInSessions.map { URL(fileURLWithPath: $0, isDirectory: true) }
        for directory in discoveredDirectories(in: home) + existingSwitchedOn + sessionURLs {
            let key = Self.key(for: directory)
            directoriesByKey[key] = directoriesByKey[key] ?? directory
        }
        return AccountScan(
            defaultKey: defaultKey,
            orderedKeys: [defaultKey] + directoriesByKey.keys.filter { $0 != defaultKey }.sorted(),
            directoriesByKey: directoriesByKey,
            keysWithNotchiHooks: Set(directoriesByKey.filter { hasNotchiHooks($0.value) }.keys)
        )
    }

    private func apply(_ scan: AccountScan) {
        let defaultKey = scan.defaultKey
        let orderedKeys = scan.orderedKeys
        let directoriesByKey = scan.directoriesByKey
        var preferences = Self.preferences(in: defaults)

        // Colors are kept once given, so a new account appearing never recolors the others.
        var didAssignColor = false
        for key in orderedKeys where preferences[key]?.color == nil {
            let taken = Set(preferences.values.compactMap(\.color))
            let palette = ClaudeAccountColor.allCases
            preferences[key, default: ClaudeAccountPreference()].color =
                palette.first { !taken.contains($0) } ?? palette[taken.count % palette.count]
            didAssignColor = true
        }
        if didAssignColor { save(preferences) }

        accounts = orderedKeys.compactMap { key in
            guard let directory = directoriesByKey[key], let color = preferences[key]?.color else { return nil }
            let isDefault = key == defaultKey
            return ClaudeAccount(
                key: key,
                directory: directory,
                isDefault: isDefault,
                name: preferences[key]?.name ?? ClaudeAccount.folderName(for: directory, isDefault: isDefault),
                color: color,
                isNotchiEnabled: scan.keysWithNotchiHooks.contains(key)
            )
        }
        accountsByKey = Dictionary(uniqueKeysWithValues: accounts.map { ($0.key, $0) })
        let accountsOn = accounts.filter(\.isNotchiEnabled)
        accountsDidChange(accountsOn.map(usageAccount(for:)))
        costAccountsDidChange(accountsOn)
    }

    var mostRecentlyActiveAccount: ClaudeAccount? {
        mostRecentlyActiveAccountKey.flatMap { accountsByKey[$0] }
    }

    /// The Claude Code login an account's usage is read from, and where its usage state is kept.
    func usageAccount(for account: ClaudeAccount) -> ClaudeUsageAccount {
        if let cached = usageAccountsByKey[account.key] { return cached }
        let usageAccount = resolvedUsageAccount(for: account)
        usageAccountsByKey[account.key] = usageAccount
        return usageAccount
    }

    private func resolvedUsageAccount(for account: ClaudeAccount) -> ClaudeUsageAccount {
        // Before its first session, a non-default account is assumed to be set the way it's spelled on disk.
        let configDir = Self.preferences(in: defaults)[account.key]?.configDir
            ?? (account.isDefault ? nil : account.directory.path)
        // Only the default login keeps the original state keys, which the shared usage service also uses.
        guard let configDir else { return .default }
        return ClaudeUsageAccount(
            credentialsService: KeychainManager.claudeCredentialsService(forConfigDir: configDir),
            // Each login keeps its own saved quota, so a respelled folder doesn't restore another login's backoff.
            storageSuffix: Self.storageSuffix(for: account.key + "\n" + configDir)
        )
    }

    /// The account a session belongs to; sessions without a known directory belong to the default one.
    func account(forSessionDirectory directory: URL?) -> ClaudeAccount? {
        guard let directory else { return accounts.first(where: \.isDefault) }
        return accountsByKey[sessionKey(for: directory)]
    }

    /// Called for every Claude hook event. Tracks the most recent account and the `CLAUDE_CONFIG_DIR`
    /// its sessions report; on an account's first session it also adds an account discovery missed
    /// (e.g. a config dir outside `~`) and rechecks its hooks, which may have changed since the last refresh.
    func noteSession(directory: URL?, rawConfigDir: String?) {
        guard let directory else {
            let defaultKey = accounts.first(where: \.isDefault)?.key
            if mostRecentlyActiveAccountKey != defaultKey { mostRecentlyActiveAccountKey = defaultKey }
            return
        }
        let key = sessionKey(for: directory)
        if mostRecentlyActiveAccountKey != key { mostRecentlyActiveAccountKey = key }
        // The same folder can be launched with a different spelling, which names a different login.
        guard reportedConfigDirs[key] != .some(rawConfigDir) else { return }
        reportedConfigDirs[key] = .some(rawConfigDir)
        let isFirstSession = accountKeysWithSessions.insert(key).inserted

        if isFirstSession, account(forSessionDirectory: directory) == nil {
            sessionDirectories.insert(directory.path)
        }
        var preferences = Self.preferences(in: defaults)
        if preferences[key]?.configDir != rawConfigDir {
            preferences[key, default: ClaudeAccountPreference()].configDir = rawConfigDir
            save(preferences)
        }
        refresh()
        if isFirstSession, account(forSessionDirectory: directory)?.isNotchiEnabled == true {
            Self.rememberAccountsWithNotchi([directory], in: defaults)
        }
    }

    func rename(_ account: ClaudeAccount, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != account.name else { return }
        let folderName = ClaudeAccount.folderName(for: account.directory, isDefault: account.isDefault)
        updatePreference(for: account) { $0.name = trimmed.isEmpty || trimmed == folderName ? nil : trimmed }
    }

    func setColor(_ color: ClaudeAccountColor, for account: ClaudeAccount) {
        updatePreference(for: account) { $0.color = color }
    }

    /// Claude hooks count as on while any account has notchi; the shared script goes with the last one.
    /// Returns false when the account's settings didn't end up as asked, e.g. they can't be parsed or written.
    @discardableResult
    func setNotchiEnabled(_ enabled: Bool, for account: ClaudeAccount) -> Bool {
        if enabled {
            guard addHooks(account.directory) else { return false }
        } else {
            removeHooks(account.directory)
        }
        refresh()
        guard accountsByKey[account.key]?.isNotchiEnabled == enabled else { return false }

        // The files are the truth; the saved list mirrors them so the next launch reinstalls the same set.
        let accountsOn = accounts.filter(\.isNotchiEnabled)
        defaults.set(accountsOn.map(\.key).sorted(), forKey: Self.accountsWithNotchiKey)
        if accountsOn.isEmpty { removeSharedScript() }
        setClaudeHooksEnabled(!accountsOn.isEmpty)
        return true
    }

    /// Accounts running notchi as of the last switch or launch; the launch install keeps them that way.
    nonisolated static func accountDirectoriesWithNotchi(in defaults: UserDefaults = .standard) -> [URL] {
        (defaults.stringArray(forKey: accountsWithNotchiKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Before accounts had their own switches, Claude hooks on meant the default account. Only a list that
    /// was never saved counts: an empty saved list means the user switched every account off.
    nonisolated static func trackDefaultAccountIfNeeded(_ directory: URL, in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: accountsWithNotchiKey) == nil else { return }
        defaults.set([key(for: directory)], forKey: accountsWithNotchiKey)
    }

    /// The accounts the launch install should run notchi in: the saved list, seeded on first launch,
    /// plus accounts found already running notchi.
    nonisolated static func accountsToInstall(
        defaultDirectory: URL,
        migrated: [URL],
        in defaults: UserDefaults = .standard
    ) -> [URL] {
        trackDefaultAccountIfNeeded(defaultDirectory, in: defaults)
        rememberAccountsWithNotchi(migrated, in: defaults)
        return accountDirectoriesWithNotchi(in: defaults)
    }

    /// Whether an account other than `directory` runs notchi, as of the last switch or launch.
    nonisolated static func hasAccountsWithNotchi(besides directory: URL, in defaults: UserDefaults = .standard) -> Bool {
        let excludedKey = key(for: directory)
        return (defaults.stringArray(forKey: accountsWithNotchiKey) ?? []).contains { $0 != excludedKey }
    }

    nonisolated static func preferences(in defaults: UserDefaults = .standard) -> [String: ClaudeAccountPreference] {
        guard let data = defaults.data(forKey: preferencesKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ClaudeAccountPreference].self, from: data)) ?? [:]
    }

    nonisolated static func forgetAccountsWithNotchi(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: accountsWithNotchiKey)
    }

    nonisolated static func rememberAccountsWithNotchi(_ directories: [URL], in defaults: UserDefaults = .standard) {
        let keys = Set(defaults.stringArray(forKey: accountsWithNotchiKey) ?? []).union(directories.map(key(for:)))
        defaults.set(keys.sorted(), forKey: accountsWithNotchiKey)
    }

    // MARK: - Private

    nonisolated static func key(for directory: URL) -> String {
        directory.standardizedFileURL.resolvingSymlinksInPath().path
    }

    nonisolated private static func discoveredDirectories(in home: URL) -> [URL] {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: home.path)) ?? []
        return names
            .filter { $0.hasPrefix(accountFolderPrefix) }
            .map { home.appendingPathComponent($0, isDirectory: true) }
            .filter { directory in
                accountMarkers.contains { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }
            }
    }

    nonisolated private static let storageSuffixLength = 8

    nonisolated static func storageSuffix(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(storageSuffixLength).description
    }

    // Resolving symlinks touches the disk, and this runs for every hook event.
    private func sessionKey(for directory: URL) -> String {
        if let key = keysBySessionPath[directory.path] { return key }
        let key = Self.key(for: directory)
        keysBySessionPath[directory.path] = key
        return key
    }

    private func save(_ preferences: [String: ClaudeAccountPreference]) {
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Self.preferencesKey)
        usageAccountsByKey = [:]
    }

    private func updatePreference(for account: ClaudeAccount, _ change: (inout ClaudeAccountPreference) -> Void) {
        var preferences = Self.preferences(in: defaults)
        change(&preferences[account.key, default: ClaudeAccountPreference()])
        save(preferences)
        refresh()
    }
}
