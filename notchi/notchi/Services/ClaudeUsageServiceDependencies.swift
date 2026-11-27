import Foundation

struct ClaudeUsageServiceDependencies {
    var fetchUsage: (URLRequest) async throws -> (Data, URLResponse)
    var getOAuthTokenFromEnvironment: () -> String?
    var getCachedOAuthToken: () -> String?
    var getOAuthCredentials: (_ allowInteraction: Bool) async -> ClaudeOAuthCredentials?
    var cacheOAuthToken: (_ token: String) -> Void
    var refreshAccessTokenSilently: () async -> String?
    var clearCachedOAuthToken: () -> Void
    var loadRecoverySnapshot: () -> ClaudeUsageRecoverySnapshot?
    var saveRecoverySnapshot: (ClaudeUsageRecoverySnapshot) -> Void
    var clearRecoverySnapshot: () -> Void
    var resolveUserAgent: () async -> String?
    var pollJitter: () -> Double
    var now: () -> Date
    var schedulePoll: @MainActor (TimeInterval, @escaping () -> Void) -> any UsagePollTimer
    // Per account, so one account's failed login can't switch the others' usage off.
    var isUsageEnabled: () -> Bool = { AppSettings.isUsageEnabled }
    var setUsageEnabled: (Bool) -> Void = { AppSettings.isUsageEnabled = $0 }
    var loadExtraUsageObservation: () -> ClaudeExtraUsageObservation? = { AppSettings.claudeExtraUsageObservation }
    var saveExtraUsageObservation: (ClaudeExtraUsageObservation?) -> Void = { AppSettings.claudeExtraUsageObservation = $0 }
}

/// Which Claude Code login a usage service reads, and where it keeps its saved state.
struct ClaudeUsageAccount: Hashable, Sendable {
    let credentialsService: String
    /// Nil for the default account, which keeps the original settings keys.
    let storageSuffix: String?

    static let `default` = ClaudeUsageAccount(
        credentialsService: KeychainManager.claudeCredentialsService(forConfigDir: nil),
        storageSuffix: nil
    )
}

extension ClaudeUsageServiceDependencies {
    static var live: Self { live(for: .default) }

    nonisolated private static let recoverySnapshotKey = "claudeUsageRecoverySnapshot"
    nonisolated private static let extraUsageObservationKey = "claudeExtraUsageObservation"
    nonisolated private static let usageDisabledAccountsKey = "claudeUsageDisabledAccounts"
    nonisolated private static let defaultAccountDisabledKey = "default"

    static func live(
        for account: ClaudeUsageAccount,
        defaults: UserDefaults = .standard,
        isGlobalUsageEnabled: @escaping () -> Bool = { AppSettings.isUsageEnabled },
        setGlobalUsageEnabled: @escaping (Bool) -> Void = { AppSettings.isUsageEnabled = $0 },
        hasOtherAccountsWithNotchi: @escaping () -> Bool = {
            ClaudeAccountStore.hasAccountsWithNotchi(besides: ClaudeConfigDirectoryResolver.resolveWithoutProbing())
        }
    ) -> Self {
        let service = account.credentialsService
        let snapshotKey = storageKey(recoverySnapshotKey, for: account)
        let observationKey = storageKey(extraUsageObservationKey, for: account)

        var dependencies = Self(
            fetchUsage: { request in
                try await URLSession.shared.data(for: request)
            },
            getOAuthTokenFromEnvironment: {
                // An environment token belongs to whichever login started notchi, i.e. the default account.
                guard account.storageSuffix == nil else { return nil }
                let rawToken = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let rawToken, !rawToken.isEmpty else {
                    return nil
                }
                return rawToken
            },
            getCachedOAuthToken: {
                KeychainManager.getCachedOAuthToken(service: service)
            },
            getOAuthCredentials: { allowInteraction in
                // WHY: the /usr/bin/security read can block for seconds, and every account does one.
                await Task.detached(priority: .utility) {
                    KeychainManager.getOAuthCredentials(service: service, allowInteraction: allowInteraction)
                }.value
            },
            cacheOAuthToken: { token in
                KeychainManager.cacheOAuthToken(token, service: service)
            },
            refreshAccessTokenSilently: {
                await Task.detached(priority: .utility) {
                    KeychainManager.refreshAccessTokenSilently(service: service)
                }.value
            },
            clearCachedOAuthToken: {
                KeychainManager.clearCachedOAuthToken(service: service)
            },
            loadRecoverySnapshot: {
                decoded(ClaudeUsageRecoverySnapshot.self, forKey: snapshotKey, in: defaults)
            },
            saveRecoverySnapshot: { snapshot in
                store(snapshot, forKey: snapshotKey, in: defaults)
            },
            clearRecoverySnapshot: {
                defaults.removeObject(forKey: snapshotKey)
            },
            resolveUserAgent: {
                // WHY: the resolver can block for seconds on shell/CLI probes, so
                // run it off the main actor that ClaudeUsageService lives on.
                await Task.detached(priority: .utility) {
                    ClaudeCLIResolver.resolveUserAgent()
                }.value
            },
            pollJitter: {
                Double.random(in: -2...2)
            },
            now: {
                Date()
            },
            schedulePoll: { interval, handler in
                let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
                    handler()
                }
                return LiveUsagePollTimer(timer: timer)
            }
        )
        dependencies.loadExtraUsageObservation = {
            decoded(ClaudeExtraUsageObservation.self, forKey: observationKey, in: defaults)
        }
        dependencies.saveExtraUsageObservation = { observation in
            store(observation, forKey: observationKey, in: defaults)
        }

        // Connecting usage is one switch for every account; a failing login only turns its own account off,
        // and the switch itself only when no other account could still show usage.
        let disabledKey = account.storageSuffix ?? defaultAccountDisabledKey
        let disabledAccounts = { Set(defaults.stringArray(forKey: usageDisabledAccountsKey) ?? []) }
        dependencies.isUsageEnabled = {
            isGlobalUsageEnabled() && !disabledAccounts().contains(disabledKey)
        }
        dependencies.setUsageEnabled = { enabled in
            var disabled = disabledAccounts()
            if enabled { disabled.remove(disabledKey) } else { disabled.insert(disabledKey) }
            defaults.set(disabled.sorted(), forKey: usageDisabledAccountsKey)
            guard account.storageSuffix == nil else { return }
            if enabled {
                setGlobalUsageEnabled(true)
            } else if !hasOtherAccountsWithNotchi() {
                setGlobalUsageEnabled(false)
            }
        }
        return dependencies
    }

    nonisolated private static func storageKey(_ base: String, for account: ClaudeUsageAccount) -> String {
        account.storageSuffix.map { "\(base)-\($0)" } ?? base
    }

    nonisolated private static func decoded<Value: Decodable>(
        _ type: Value.Type,
        forKey key: String,
        in defaults: UserDefaults
    ) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    nonisolated private static func store<Value: Encodable>(_ value: Value?, forKey key: String, in defaults: UserDefaults) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
