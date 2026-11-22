import Foundation
import Observation

/// The Claude Code accounts (config directories) on this Mac, with the name, color and
/// per-account notchi switch the user picked for each.
@MainActor @Observable
final class ClaudeAccountStore {
    static let shared: ClaudeAccountStore = {
        let store = ClaudeAccountStore()
        store.refresh()
        return store
    }()

    private(set) var accounts: [ClaudeAccount] = []

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
    private let hasNotchiHooks: (URL) -> Bool
    private let addHooks: (URL) -> Bool
    private let removeHooks: (URL) -> Void
    private var sessionDirectories: Set<String> = []
    private var accountsByKey: [String: ClaudeAccount] = [:]
    private var keysBySessionPath: [String: String] = [:]
    private var accountKeysWithSessions: Set<String> = []

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaultDirectory: @escaping () -> URL = { ClaudeConfigDirectoryResolver.resolveWithoutProbing() },
        defaults: UserDefaults = .standard,
        setClaudeHooksEnabled: @escaping (Bool) -> Void = { AppSettings.setHooksEnabled($0, for: .claude) },
        removeSharedScript: @escaping () -> Void = { HookInstaller.removeSharedScript() },
        hasNotchiHooks: @escaping (URL) -> Bool = { HookInstaller.isHookInstalled(inAccount: $0) },
        addHooks: @escaping (URL) -> Bool = { HookInstaller.addHooks(toAccount: $0) },
        removeHooks: @escaping (URL) -> Void = { HookInstaller.removeHooks(fromAccount: $0) }
    ) {
        self.home = home
        self.defaultDirectory = defaultDirectory
        self.defaults = defaults
        self.setClaudeHooksEnabled = setClaudeHooksEnabled
        self.removeSharedScript = removeSharedScript
        self.hasNotchiHooks = hasNotchiHooks
        self.addHooks = addHooks
        self.removeHooks = removeHooks
    }

    // The isolated-deinit back-deploy shim aborts on macOS 15; this deinit only releases stored properties.
    nonisolated deinit {}

    var showsAccountBadges: Bool {
        accounts.filter(\.isNotchiEnabled).count >= Self.minimumAccountsForBadges
    }

    func refresh() {
        let defaultDirectory = defaultDirectory()
        let defaultKey = Self.key(for: defaultDirectory)
        var preferences = Self.preferences(in: defaults)

        var directoriesByKey: [String: URL] = [defaultKey: defaultDirectory]
        let switchedOn = Self.accountDirectoriesWithNotchi(in: defaults)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let seenInSessions = sessionDirectories.map { URL(fileURLWithPath: $0, isDirectory: true) }
        for directory in discoveredDirectories() + switchedOn + seenInSessions {
            let key = Self.key(for: directory)
            directoriesByKey[key] = directoriesByKey[key] ?? directory
        }
        let orderedKeys = [defaultKey] + directoriesByKey.keys.filter { $0 != defaultKey }.sorted()

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
                isNotchiEnabled: hasNotchiHooks(directory)
            )
        }
        accountsByKey = Dictionary(uniqueKeysWithValues: accounts.map { ($0.key, $0) })
    }

    /// The account a session belongs to; sessions without a known directory belong to the default one.
    func account(forSessionDirectory directory: URL?) -> ClaudeAccount? {
        guard let directory else { return accounts.first(where: \.isDefault) }
        return accountsByKey[sessionKey(for: directory)]
    }

    /// Adds an account a session came from that discovery missed, e.g. a config dir outside `~`, and
    /// rechecks a known one on its first session, since its hooks may have changed since the last refresh.
    func noteSessionDirectory(_ directory: URL?) {
        guard let directory, accountKeysWithSessions.insert(sessionKey(for: directory)).inserted else { return }
        if account(forSessionDirectory: directory) == nil {
            sessionDirectories.insert(directory.path)
        }
        refresh()
        if account(forSessionDirectory: directory)?.isNotchiEnabled == true {
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

    nonisolated private static func key(for directory: URL) -> String {
        directory.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func discoveredDirectories() -> [URL] {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: home.path)) ?? []
        return names
            .filter { $0.hasPrefix(Self.accountFolderPrefix) }
            .map { home.appendingPathComponent($0, isDirectory: true) }
            .filter { directory in
                Self.accountMarkers.contains { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }
            }
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
    }

    private func updatePreference(for account: ClaudeAccount, _ change: (inout ClaudeAccountPreference) -> Void) {
        var preferences = Self.preferences(in: defaults)
        change(&preferences[account.key, default: ClaudeAccountPreference()])
        save(preferences)
        refresh()
    }
}
