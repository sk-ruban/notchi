import Foundation

/// Remembers the emotion analysis API keys and Claude Code's settings.json fallback, so a prompt or
/// a settings screen doesn't read the Keychain or the file every time.
@MainActor
@Observable
final class EmotionAnalysisCredentials {
    static let shared = EmotionAnalysisCredentials()

    private enum StoredKey: Equatable {
        case value(String)
        /// Unconfirmed when only a non-interactive read missed, which a locked item does too.
        case missing(confirmed: Bool, checkedAt: Date)
    }

    private struct SettingsFileSignature: Equatable {
        let path: String
        let size: UInt64?
        let modifiedAt: Date?
    }

    /// Changes whenever a key is saved, so screens showing whether one is set can refresh.
    private(set) var revision = 0
    @ObservationIgnored private var storedKeys: [EmotionAnalysisProvider: StoredKey] = [:]
    @ObservationIgnored private var claudeSettings: (signature: SettingsFileSignature, config: ClaudeSettingsConfig?)?
    @ObservationIgnored private let readKey: (EmotionAnalysisProvider, Bool) -> String?
    @ObservationIgnored private let writeKey: (String?, EmotionAnalysisProvider) -> Bool
    @ObservationIgnored private let claudeSettingsURL: () -> URL
    @ObservationIgnored private let loadClaudeSettings: (URL) -> ClaudeSettingsConfig?
    @ObservationIgnored private let now: () -> Date

    // A locked Keychain also misses a non-interactive read, so such a miss is checked again later.
    static let unconfirmedMissRetryInterval: TimeInterval = 5 * 60

    init(
        readKey: @escaping (EmotionAnalysisProvider, Bool) -> String? = { provider, allowInteraction in
            switch provider {
            case .claude:
                KeychainManager.getAnthropicApiKey(allowInteraction: allowInteraction)
            case .openAI:
                KeychainManager.getOpenAIApiKey(allowInteraction: allowInteraction)
            }
        },
        writeKey: @escaping (String?, EmotionAnalysisProvider) -> Bool = { key, provider in
            switch provider {
            case .claude:
                KeychainManager.setAnthropicApiKey(key)
            case .openAI:
                KeychainManager.setOpenAIApiKey(key)
            }
        },
        claudeSettingsURL: @escaping () -> URL = { ClaudeConfigDirectoryResolver.resolve().settingsURL },
        loadClaudeSettings: @escaping (URL) -> ClaudeSettingsConfig? = { ClaudeSettingsConfig.load(from: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.readKey = readKey
        self.writeKey = writeKey
        self.claudeSettingsURL = claudeSettingsURL
        self.loadClaudeSettings = loadClaudeSettings
        self.now = now
    }

    // The isolated-deinit back-deploy shim aborts on macOS 15; this deinit only releases stored properties.
    nonisolated deinit {}

    func apiKey(for provider: EmotionAnalysisProvider, allowInteraction: Bool = false) -> String? {
        switch storedKeys[provider] {
        case .value(let key):
            return key
        case .missing(let confirmed, let checkedAt)
            where confirmed || (!allowInteraction && now().timeIntervalSince(checkedAt) < Self.unconfirmedMissRetryInterval):
            return nil
        case .missing, nil:
            break
        }

        let key = readKey(provider, allowInteraction)
        storedKeys[provider] = key.map(StoredKey.value) ?? .missing(confirmed: allowInteraction, checkedAt: now())
        return key
    }

    func setApiKey(_ key: String?, for provider: EmotionAnalysisProvider) {
        if !writeKey(key, provider) {
            // Forget the cached key so the next read reports what the Keychain actually holds.
            storedKeys[provider] = nil
        } else if let key, !key.isEmpty {
            storedKeys[provider] = .value(key)
        } else {
            storedKeys[provider] = .missing(confirmed: true, checkedAt: now())
        }
        revision += 1
    }

    /// Re-reads settings.json only when its size or modification time changed since the last read.
    func claudeSettingsConfig() -> ClaudeSettingsConfig? {
        let url = claudeSettingsURL()
        let signature = Self.signature(of: url)
        if let claudeSettings, claudeSettings.signature == signature {
            return claudeSettings.config
        }

        let config = loadClaudeSettings(url)
        claudeSettings = (signature, config)
        return config
    }

    private static func signature(of url: URL) -> SettingsFileSignature {
        // A symlink's own attributes don't change when its target (often a dotfiles checkout) is edited.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        return SettingsFileSignature(
            path: url.path,
            size: attributes?[.size] as? UInt64,
            modifiedAt: attributes?[.modificationDate] as? Date
        )
    }
}
