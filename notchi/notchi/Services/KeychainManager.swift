import CryptoKit
import Foundation
import Security

struct ClaudeOAuthCredentials: Equatable {
    let accessToken: String
    let expiresAt: Date?
    let scopes: Set<String>
}

// Claude credential reads wait on /usr/bin/security for up to 2 s, so usage services call them
// from background executors instead of the project's MainActor default.
nonisolated enum KeychainManager {
    private static let claudeCodeService = "Claude Code-credentials"
    private static let configDirHashLength = 8
    private static let notchiService = "com.ruban.notchi"
    private static let anthropicApiKeyAccount = "anthropicApiKey"
    private static let openAIApiKeyAccount = "openAIApiKey"
    private static let recentCredentialCacheTTL: TimeInterval = 5
    private static let securityCLIBackoffInterval: TimeInterval = 60
    private static let credentialReadLock = NSLock()
    private nonisolated(unsafe) static var recentCredentialCacheEntries: [String: ClaudeCredentialCacheEntry] = [:]
    private nonisolated(unsafe) static var lastSecurityCLIFailureAt: [String: Date] = [:]
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoBasic = ISO8601DateFormatter()

    private struct ClaudeCredentialCacheEntry {
        let credentials: ClaudeOAuthCredentials
        let resolvedAt: Date
    }

    #if DEBUG
    private nonisolated(unsafe) static var taskSecurityCLIReadOverride: (() -> [String: Any]?)?
    private nonisolated(unsafe) static var taskSecurityFrameworkReadOverride: ((Bool) -> [String: Any]?)?
    private nonisolated(unsafe) static var taskNowOverride: (() -> Date)?
    #endif

    /// The keychain item Claude Code keeps an account's login in. Like Claude Code, this hashes the
    /// `CLAUDE_CONFIG_DIR` value as set apart from NFC normalization, so a trailing slash names another
    /// login; unset or empty is the default account.
    static func claudeCredentialsService(forConfigDir configDir: String?) -> String {
        guard let configDir, !configDir.isEmpty else { return claudeCodeService }
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(claudeCodeService)-\(hex.prefix(configDirHashLength))"
    }

    static func refreshAccessTokenSilently(service: String = claudeCodeService) -> String? {
        guard let credentials = getOAuthCredentials(service: service, allowInteraction: false) else {
            return nil
        }
        cacheOAuthToken(credentials.accessToken, service: service)
        return credentials.accessToken
    }

    // MARK: - Anthropic API Key

    static func getAnthropicApiKey(allowInteraction: Bool = false) -> String? {
        readString(
            service: notchiService,
            account: anthropicApiKeyAccount,
            allowInteraction: allowInteraction
        )
    }

    static func setAnthropicApiKey(_ key: String?) {
        if let key, !key.isEmpty {
            saveString(key, service: notchiService, account: anthropicApiKeyAccount)
        } else {
            deleteItem(service: notchiService, account: anthropicApiKeyAccount)
        }
    }

    static func getOpenAIApiKey(allowInteraction: Bool = false) -> String? {
        readString(
            service: notchiService,
            account: openAIApiKeyAccount,
            allowInteraction: allowInteraction
        )
    }

    static func setOpenAIApiKey(_ key: String?) {
        if let key, !key.isEmpty {
            saveString(key, service: notchiService, account: openAIApiKeyAccount)
        } else {
            deleteItem(service: notchiService, account: openAIApiKeyAccount)
        }
    }

    // MARK: - Cached OAuth Token

    // Kept in memory, not notchi's keychain: writing that item prompts again whenever notchi's code
    // signature changes (every update or rebuild). A fresh launch re-reads Claude Code's own item
    // through /usr/bin/security, which doesn't prompt.
    private static let cachedTokenLock = NSLock()
    private nonisolated(unsafe) static var cachedTokens: [String: String] = [:]

    static func getCachedOAuthToken(service: String = claudeCodeService) -> String? {
        cachedTokenLock.withLock { cachedTokens[service] }
    }

    static func cacheOAuthToken(_ token: String, service: String = claudeCodeService) {
        cachedTokenLock.withLock { cachedTokens[service] = token }
    }

    static func clearCachedOAuthToken(service: String = claudeCodeService) {
        cachedTokenLock.withLock { cachedTokens[service] = nil }
    }

    // MARK: - Claude Code Credentials

    static func getOAuthCredentials(
        service: String = claudeCodeService,
        allowInteraction: Bool
    ) -> ClaudeOAuthCredentials? {
        let now = currentDate()
        if let cached = recentCredentialCache(for: service, at: now) {
            return cached.credentials
        }

        // Primary: /usr/bin/security CLI (avoids ACL dialog)
        if shouldAttemptSecurityCLI(service: service, at: now) {
            if let json = readClaudeCodeKeychainViaCLI(service: service),
               let credentials = decodeClaudeOAuthCredentials(from: json) {
                cacheRecentCredential(credentials, for: service, at: now)
                clearSecurityCLIBackoff(service: service)
                return credentials
            }
            recordSecurityCLIFailure(service: service, at: now)
        }

        // Fallback: Security.framework using the caller's interaction policy.
        guard let json = readClaudeCodeKeychain(service: service, allowInteraction: allowInteraction),
              let credentials = decodeClaudeOAuthCredentials(from: json) else {
            return nil
        }
        cacheRecentCredential(credentials, for: service, at: now)
        return credentials
    }

    private static func readClaudeCodeKeychainViaCLI(service: String) -> [String: Any]? {
        #if DEBUG
        if let override = taskSecurityCLIReadOverride {
            return override()
        }
        #endif

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        if done.wait(timeout: .now() + .seconds(2)) == .timedOut {
            process.terminate()
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func readClaudeCodeKeychain(service: String, allowInteraction: Bool) -> [String: Any]? {
        #if DEBUG
        if let override = taskSecurityFrameworkReadOverride {
            return override(allowInteraction)
        }
        #endif

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if !allowInteraction {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return json
    }

    private static func recentCredentialCache(for service: String, at now: Date) -> ClaudeCredentialCacheEntry? {
        credentialReadLock.lock()
        defer { credentialReadLock.unlock() }

        guard let entry = recentCredentialCacheEntries[service] else {
            return nil
        }

        guard now.timeIntervalSince(entry.resolvedAt) <= recentCredentialCacheTTL else {
            recentCredentialCacheEntries[service] = nil
            return nil
        }

        return entry
    }

    private static func cacheRecentCredential(
        _ credentials: ClaudeOAuthCredentials,
        for service: String,
        at now: Date
    ) {
        credentialReadLock.lock()
        recentCredentialCacheEntries[service] = ClaudeCredentialCacheEntry(
            credentials: credentials,
            resolvedAt: now
        )
        credentialReadLock.unlock()
    }

    // Per login, so one account's missing item doesn't skip the prompt-free CLI read for the others.
    private static func shouldAttemptSecurityCLI(service: String, at now: Date) -> Bool {
        credentialReadLock.lock()
        defer { credentialReadLock.unlock() }

        guard let lastFailure = lastSecurityCLIFailureAt[service] else {
            return true
        }

        if now.timeIntervalSince(lastFailure) >= securityCLIBackoffInterval {
            lastSecurityCLIFailureAt[service] = nil
            return true
        }

        return false
    }

    private static func recordSecurityCLIFailure(service: String, at now: Date) {
        credentialReadLock.lock()
        lastSecurityCLIFailureAt[service] = now
        credentialReadLock.unlock()
    }

    private static func clearSecurityCLIBackoff(service: String) {
        credentialReadLock.lock()
        lastSecurityCLIFailureAt[service] = nil
        credentialReadLock.unlock()
    }

    private static func currentDate() -> Date {
        #if DEBUG
        if let override = taskNowOverride {
            return override()
        }
        #endif
        return Date()
    }

    #if DEBUG
    static func _setSecurityCLIReadOverrideForTesting(_ override: (() -> [String: Any]?)?) {
        taskSecurityCLIReadOverride = override
    }

    static func _setSecurityFrameworkReadOverrideForTesting(_ override: ((Bool) -> [String: Any]?)?) {
        taskSecurityFrameworkReadOverride = override
    }

    static func _setNowOverrideForTesting(_ override: (() -> Date)?) {
        taskNowOverride = override
    }

    nonisolated(unsafe) static var keychainWritesForTesting = 0

    static func _resetCredentialResolutionStateForTesting() {
        keychainWritesForTesting = 0
        cachedTokenLock.withLock { cachedTokens = [:] }
        credentialReadLock.lock()
        recentCredentialCacheEntries = [:]
        lastSecurityCLIFailureAt = [:]
        credentialReadLock.unlock()
        taskSecurityCLIReadOverride = nil
        taskSecurityFrameworkReadOverride = nil
        taskNowOverride = nil
    }
    #endif

    static func decodeClaudeOAuthCredentials(from json: [String: Any]) -> ClaudeOAuthCredentials? {
        guard let oauth = json["claudeAiOauth"] as? [String: Any],
              let rawToken = oauth["accessToken"] as? String else {
            return nil
        }

        let accessToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            return nil
        }

        return ClaudeOAuthCredentials(
            accessToken: accessToken,
            expiresAt: parseExpiresAt(from: oauth["expiresAt"] ?? oauth["expires_at"]),
            scopes: parseScopes(from: oauth["scopes"])
        )
    }

    private static func parseScopes(from rawValue: Any?) -> Set<String> {
        if let scopes = rawValue as? [String] {
            return Set(scopes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }

        if let scopeString = rawValue as? String {
            let separators = CharacterSet(charactersIn: ", ")
            let scopes = scopeString
                .components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Set(scopes)
        }

        return []
    }

    private static func parseExpiresAt(from rawValue: Any?) -> Date? {
        switch rawValue {
        case let date as Date:
            return date
        case let number as NSNumber:
            return parseEpoch(number.doubleValue)
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let epoch = Double(trimmed) {
                return parseEpoch(epoch)
            }
            return isoFractional.date(from: trimmed) ?? isoBasic.date(from: trimmed)
        default:
            return nil
        }
    }

    private static func parseEpoch(_ value: Double) -> Date {
        let seconds = value > 1_000_000_000_000 ? value / 1000.0 : value
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - Generic Keychain Helpers

    // Even own-service keychain items can trigger a Security dialog when the app's
    // code signature changes between Xcode rebuilds, invalidating prior "Always Allow".
    private static func readString(service: String, account: String, allowInteraction: Bool) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if !allowInteraction {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    private static func saveString(_ value: String, service: String, account: String) {
        #if DEBUG
        keychainWritesForTesting += 1
        #endif
        let data = Data(value.utf8)

        // Try to update existing item first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private static func deleteItem(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
