import Foundation

enum EmotionAnalysisProvider: String, CaseIterable, Identifiable {
    case claude
    case openAI = "openai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude:
            "Claude"
        case .openAI:
            "OpenAI"
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .claude:
            "Anthropic API Key"
        case .openAI:
            "OpenAI API Key"
        }
    }

    var apiKeyURL: URL {
        switch self {
        case .claude:
            URL(string: "https://console.anthropic.com/settings/keys")!
        case .openAI:
            URL(string: "https://platform.openai.com/api-keys")!
        }
    }
}

enum EmotionAnalysisModel: String, CaseIterable, Identifiable {
    case claudeHaiku45 = "claude-haiku-4-5-20251001"
    case claudeSonnet46 = "claude-sonnet-4-6"
    case openAIGPT54Nano = "gpt-5.4-nano"
    case openAIGPT54Mini = "gpt-5.4-mini"

    var id: String { rawValue }

    var provider: EmotionAnalysisProvider {
        switch self {
        case .claudeHaiku45, .claudeSonnet46:
            .claude
        case .openAIGPT54Nano, .openAIGPT54Mini:
            .openAI
        }
    }

    var displayName: String {
        switch self {
        case .claudeHaiku45:
            "Claude Haiku 4.5"
        case .claudeSonnet46:
            "Claude Sonnet 4.6"
        case .openAIGPT54Nano:
            "GPT-5.4 nano"
        case .openAIGPT54Mini:
            "GPT-5.4 mini"
        }
    }

    static func models(for provider: EmotionAnalysisProvider) -> [EmotionAnalysisModel] {
        allCases.filter { $0.provider == provider }
    }

    static func defaultModel(for provider: EmotionAnalysisProvider) -> EmotionAnalysisModel {
        switch provider {
        case .claude:
            .claudeHaiku45
        case .openAI:
            .openAIGPT54Nano
        }
    }
}

struct AppSettings {
    static let hideSpriteWhenIdleKey = "hideSpriteWhenIdle"

    private static let notificationSoundKey = "notificationSound"
    private static let isMutedKey = "isMuted"
    private static let previousSoundKey = "previousNotificationSound"
    private static let isUsageEnabledKey = "isUsageEnabled"
    private static let claudeUsageRecoverySnapshotKey = "claudeUsageRecoverySnapshot"
    private static let claudeExtraUsageObservationKey = "claudeExtraUsageObservation"
    private static let emotionAnalysisProviderKey = "emotionAnalysisProvider"
    private static let emotionAnalysisClaudeModelKey = "emotionAnalysisClaudeModel"
    private static let emotionAnalysisOpenAIModelKey = "emotionAnalysisOpenAIModel"

    static var isUsageEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: isUsageEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: isUsageEnabledKey) }
    }

    static var hideSpriteWhenIdle: Bool {
        get { UserDefaults.standard.bool(forKey: hideSpriteWhenIdleKey) }
        set { UserDefaults.standard.set(newValue, forKey: hideSpriteWhenIdleKey) }
    }

    private static let selectedSkinNameKey = "selectedSkinName"

    static var selectedSkinName: String {
        get { UserDefaults.standard.string(forKey: selectedSkinNameKey) ?? "Default" }
        set { UserDefaults.standard.set(newValue, forKey: selectedSkinNameKey) }
    }

    static var claudeUsageRecoverySnapshot: ClaudeUsageRecoverySnapshot? {
        get {
            guard let data = UserDefaults.standard.data(forKey: claudeUsageRecoverySnapshotKey) else {
                return nil
            }
            return try? JSONDecoder().decode(ClaudeUsageRecoverySnapshot.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: claudeUsageRecoverySnapshotKey)
            } else {
                UserDefaults.standard.removeObject(forKey: claudeUsageRecoverySnapshotKey)
            }
        }
    }

    static var claudeExtraUsageObservation: ClaudeExtraUsageObservation? {
        get {
            guard let data = UserDefaults.standard.data(forKey: claudeExtraUsageObservationKey) else {
                return nil
            }
            return try? JSONDecoder().decode(ClaudeExtraUsageObservation.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: claudeExtraUsageObservationKey)
            } else {
                UserDefaults.standard.removeObject(forKey: claudeExtraUsageObservationKey)
            }
        }
    }

    static var anthropicApiKey: String? {
        get { KeychainManager.getAnthropicApiKey(allowInteraction: true) }
        set { KeychainManager.setAnthropicApiKey(newValue) }
    }

    static var openAIApiKey: String? {
        get { KeychainManager.getOpenAIApiKey(allowInteraction: true) }
        set { KeychainManager.setOpenAIApiKey(newValue) }
    }

    static var emotionAnalysisProvider: EmotionAnalysisProvider {
        get {
            if let rawValue = UserDefaults.standard.string(forKey: emotionAnalysisProviderKey),
               let provider = EmotionAnalysisProvider(rawValue: rawValue) {
                return provider
            }

            let hasAnthropicKey = KeychainManager.getAnthropicApiKey(allowInteraction: false)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
            let hasOpenAIKey = KeychainManager.getOpenAIApiKey(allowInteraction: false)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false

            if hasOpenAIKey && !hasAnthropicKey {
                return .openAI
            }

            return .claude
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: emotionAnalysisProviderKey)
        }
    }

    static func apiKey(for provider: EmotionAnalysisProvider) -> String? {
        switch provider {
        case .claude:
            anthropicApiKey
        case .openAI:
            openAIApiKey
        }
    }

    static func setApiKey(_ key: String?, for provider: EmotionAnalysisProvider) {
        switch provider {
        case .claude:
            anthropicApiKey = key
        case .openAI:
            openAIApiKey = key
        }
    }

    static func selectedEmotionAnalysisModel(for provider: EmotionAnalysisProvider) -> EmotionAnalysisModel {
        storedEmotionAnalysisModel(for: provider) ?? EmotionAnalysisModel.defaultModel(for: provider)
    }

    static func storedEmotionAnalysisModel(for provider: EmotionAnalysisProvider) -> EmotionAnalysisModel? {
        guard let rawValue = UserDefaults.standard.string(forKey: emotionAnalysisModelKey(for: provider)),
              let model = EmotionAnalysisModel(rawValue: rawValue),
              model.provider == provider else {
            return nil
        }
        return model
    }

    static func setEmotionAnalysisModel(_ model: EmotionAnalysisModel, for provider: EmotionAnalysisProvider) {
        guard model.provider == provider else { return }
        UserDefaults.standard.set(model.rawValue, forKey: emotionAnalysisModelKey(for: provider))
    }

    private static func emotionAnalysisModelKey(for provider: EmotionAnalysisProvider) -> String {
        switch provider {
        case .claude:
            emotionAnalysisClaudeModelKey
        case .openAI:
            emotionAnalysisOpenAIModelKey
        }
    }

    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: notificationSoundKey),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .purr
            }
            return sound
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: notificationSoundKey)
        }
    }

    static var isMuted: Bool {
        get { UserDefaults.standard.bool(forKey: isMutedKey) }
        set { UserDefaults.standard.set(newValue, forKey: isMutedKey) }
    }

    static func toggleMute() {
        if isMuted {
            notificationSound = previousSound ?? .purr
            isMuted = false
        } else {
            previousSound = notificationSound
            notificationSound = .none
            isMuted = true
        }
    }

    private static var previousSound: NotificationSound? {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: previousSoundKey) else {
                return nil
            }
            return NotificationSound(rawValue: rawValue)
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue, forKey: previousSoundKey)
        }
    }
}
