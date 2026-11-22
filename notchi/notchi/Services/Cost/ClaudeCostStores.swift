import Foundation

/// One cost history per Claude account running notchi, read from that account's own folder.
/// The account in `~/.claude` reuses the shared store, which already reads that folder.
@MainActor
final class ClaudeCostStores {
    static let shared = ClaudeCostStores()

    private let sharedStore: CostHistoryStore
    private let sharedStoreKey: String
    private let makeStore: @MainActor (ClaudeAccount) -> CostHistoryStore
    /// Stores stay after their account is switched off, so switching it back on can't start a second
    /// scan of the same cache file while the first is still running.
    private var stores: [String: CostHistoryStore] = [:]
    private var accountKeysWithNotchi: Set<String> = []

    init(
        sharedStore: CostHistoryStore = .shared,
        sharedStoreDirectory: URL = CostHistoryStore.sharedClaudeDirectory,
        makeStore: @escaping @MainActor (ClaudeAccount) -> CostHistoryStore = { account in
            CostHistoryStore.claudeAccountStore(
                projectsRoot: account.directory.appendingPathComponent("projects", isDirectory: true),
                cacheFile: "claude-\(ClaudeAccountStore.storageSuffix(for: account.key)).json"
            )
        }
    ) {
        self.sharedStore = sharedStore
        self.sharedStoreKey = ClaudeAccountStore.key(for: sharedStoreDirectory)
        self.makeStore = makeStore
    }

    // The isolated-deinit back-deploy shim aborts on macOS 15; this deinit only releases stored properties.
    nonisolated deinit {}

    var trackedAccountKeys: Set<String> {
        accountKeysWithNotchi.subtracting([sharedStoreKey])
    }

    /// Nil for an account that isn't running notchi.
    func store(for account: ClaudeAccount) -> CostHistoryStore? {
        guard accountKeysWithNotchi.contains(account.key) else { return nil }
        return account.key == sharedStoreKey ? sharedStore : stores[account.key]
    }

    func sync(with accounts: [ClaudeAccount]) {
        let wanted = Dictionary(accounts.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for key in accountKeysWithNotchi where wanted[key] == nil {
            stores[key]?.stop()
        }
        accountKeysWithNotchi = Set(wanted.keys)
        for (key, account) in wanted where key != sharedStoreKey {
            let store = stores[key] ?? makeStore(account)
            stores[key] = store
            store.start()
        }
    }
}
