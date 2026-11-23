import Foundation

/// One usage service per Claude account running notchi. The default account keeps the shared
/// service; the others are created as accounts are switched on and dropped when switched off.
@MainActor
final class ClaudeUsageServices {
    static let shared = ClaudeUsageServices()

    private let defaultService: ClaudeUsageService
    private let isUsageEnabled: () -> Bool
    private let makeService: @MainActor (ClaudeUsageAccount) -> ClaudeUsageService
    private var services: [ClaudeUsageAccount: ClaudeUsageService] = [:]
    /// Accounts with notchi on; a view can still look up a switched-off account, but it isn't polled.
    private var accountsWithNotchi: Set<ClaudeUsageAccount> = []

    init(
        defaultService: ClaudeUsageService = .shared,
        isUsageEnabled: @escaping () -> Bool = { AppSettings.isUsageEnabled },
        makeService: @escaping @MainActor (ClaudeUsageAccount) -> ClaudeUsageService = {
            ClaudeUsageService(dependencies: .live(for: $0))
        }
    ) {
        self.defaultService = defaultService
        self.isUsageEnabled = isUsageEnabled
        self.makeService = makeService
    }

    // The isolated-deinit back-deploy shim aborts on macOS 15; this deinit only releases stored properties.
    nonisolated deinit {}

    var trackedAccounts: Set<ClaudeUsageAccount> {
        Set(services.keys)
    }

    func service(for account: ClaudeUsageAccount) -> ClaudeUsageService {
        if account == .default { return defaultService }
        if let service = services[account] { return service }
        let service = makeService(account)
        services[account] = service
        if accountsWithNotchi.contains(account), isUsageEnabled() { service.startPolling() }
        return service
    }

    func sync(with accounts: [ClaudeUsageAccount]) {
        let wanted = Set(accounts).subtracting([.default])
        for (account, service) in services where !wanted.contains(account) {
            service.stopPolling()
            services[account] = nil
        }
        let added = wanted.subtracting(accountsWithNotchi)
        accountsWithNotchi = wanted
        for account in added {
            if let existing = services[account] {
                if isUsageEnabled() { existing.startPolling() }
            } else {
                _ = service(for: account)
            }
        }
    }

    /// The usage service for a Claude session's account, or the most recently active account when
    /// there's no Claude session; nil for the default account, whose service callers already hold.
    func service(forSession session: SessionData?, accounts: ClaudeAccountStore = .shared) -> ClaudeUsageService? {
        guard let account = account(forSession: session, accounts: accounts) else { return nil }
        let usageAccount = accounts.usageAccount(for: account)
        return usageAccount == .default ? nil : service(for: usageAccount)
    }

    /// The account name to show next to Claude usage, only when more than one account is on.
    func accountName(forSession session: SessionData?, accounts: ClaudeAccountStore = .shared) -> String? {
        guard accounts.showsAccountBadges else { return nil }
        return account(forSession: session, accounts: accounts)?.name
    }

    /// The Claude account a session belongs to, or the most recently active one without a Claude session.
    func account(forSession session: SessionData?, accounts: ClaudeAccountStore = .shared) -> ClaudeAccount? {
        if let session, session.provider == .claude {
            return accounts.account(forSessionDirectory: session.claudeConfigDirectory)
        }
        return accounts.mostRecentlyActiveAccount
    }

    /// Covers the accounts other than the default, whose shared service is driven directly.
    func startPolling(afterSystemWake: Bool = false) {
        guard isUsageEnabled() else { return }
        pollingServices.forEach { $0.startPolling(afterSystemWake: afterSystemWake) }
    }

    /// Connects every account with fresh credentials, so a login fixed since the last failure is picked up.
    /// The default goes first: connecting it turns the usage switch on, which the other accounts check.
    func connectAndStartPolling() {
        defaultService.connectAndStartPolling()
        pollingServices.forEach { $0.connectAndStartPolling() }
    }

    /// Whether the default account or any account with notchi on has connected usage.
    var isAnyAccountConnected: Bool {
        defaultService.isConnected || pollingServices.contains { $0.isConnected }
    }

    private var pollingServices: [ClaudeUsageService] {
        services.compactMap { accountsWithNotchi.contains($0.key) ? $0.value : nil }
    }

    func stopPolling() {
        services.values.forEach { $0.stopPolling() }
    }

    /// A resume trigger only acts on a service waiting for Claude Code, so every account can get it.
    func handleClaudeResumeTrigger(_ trigger: ClaudeUsageResumeTrigger) {
        defaultService.handleClaudeResumeTrigger(trigger)
        services.values.forEach { $0.handleClaudeResumeTrigger(trigger) }
    }
}
