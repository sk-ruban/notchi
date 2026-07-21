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
            String(localized: "Anthropic API Key")
        case .openAI:
            String(localized: "OpenAI API Key")
        }
    }

    var apiBaseURLPlaceholder: String {
        switch self {
        case .claude:
            "api.anthropic.com"
        case .openAI:
            "api.openai.com"
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
    case openAIGPT41Mini = "gpt-4.1-mini"

    var id: String { rawValue }

    var provider: EmotionAnalysisProvider {
        switch self {
        case .claudeHaiku45, .claudeSonnet46:
            .claude
        case .openAIGPT54Nano, .openAIGPT54Mini, .openAIGPT41Mini:
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
        case .openAIGPT41Mini:
            "GPT-4.1 mini"
        }
    }

    static func models(for provider: EmotionAnalysisProvider) -> [EmotionAnalysisModel] {
        switch provider {
        case .claude:
            [.claudeHaiku45, .claudeSonnet46]
        case .openAI:
            [.openAIGPT54Mini, .openAIGPT54Nano, .openAIGPT41Mini]
        }
    }

    static func defaultModel(for provider: EmotionAnalysisProvider) -> EmotionAnalysisModel {
        switch provider {
        case .claude:
            .claudeHaiku45
        case .openAI:
            .openAIGPT54Mini
        }
    }
}

enum NotchSlotContent: String, CaseIterable, Identifiable {
    case latest
    case ring
    case claude
    case codex
    case nothing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .latest: String(localized: "Latest Session")
        case .ring: String(localized: "Usage")
        case .claude: "Claude"
        case .codex: "Codex"
        case .nothing: String(localized: "Nothing")
        }
    }

    var spriteProvider: AgentProvider? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .nothing, .ring, .latest: nil
        }
    }

    var isSprite: Bool {
        switch self {
        case .latest, .claude, .codex: true
        case .nothing, .ring: false
        }
    }

    static func conflict(_ a: NotchSlotContent, _ b: NotchSlotContent) -> Bool {
        guard a != .nothing, b != .nothing else { return false }
        return a == b || (a.isSprite && b.isSprite && (a == .latest || b == .latest))
    }
}

enum ExpandedPanelMode: String, CaseIterable {
    case full
    case compact
    case islandOnly
}

struct AppSettings {
    static let hideSpriteWhenIdleKey = "hideSpriteWhenIdle"
    static let hideGrassIslandKey = "hideGrassIsland"
    static let panelToggleShortcutKey = "panelToggleShortcut"
    static let notchLeftContentKey = "notchLeftContent"
    static let notchRightContentKey = "notchRightContent"

    private static let notificationSoundKey = "notificationSound"
    private static let notificationSoundSelectionKey = "notificationSoundSelection"
    private static let customNotificationSoundsKey = "customNotificationSounds"
    private static let isMutedKey = "isMuted"
    private static let previousSoundKey = "previousNotificationSound"
    private static let previousSoundSelectionKey = "previousNotificationSoundSelection"
    private static let isUsageEnabledKey = "isUsageEnabled"
    private static let claudeUsageRecoverySnapshotKey = "claudeUsageRecoverySnapshot"
    private static let claudeExtraUsageObservationKey = "claudeExtraUsageObservation"
    private static let emotionAnalysisProviderKey = "emotionAnalysisProvider"
    private static let emotionAnalysisClaudeModelKey = "emotionAnalysisClaudeModel"
    private static let emotionAnalysisOpenAIModelKey = "emotionAnalysisOpenAIModel"
    private static let emotionAnalysisClaudeBaseURLKey = "emotionAnalysisClaudeBaseURL"
    private static let emotionAnalysisOpenAIBaseURLKey = "emotionAnalysisOpenAIBaseURL"
    private static let lastUsedAgentProviderKey = "lastUsedAgentProvider"
    nonisolated private static let agentHooksDisabledProvidersKey = "agentHooksDisabledProviders"

    nonisolated static func areHooksEnabled(for provider: AgentProvider) -> Bool {
        let disabledProviders = UserDefaults.standard.stringArray(forKey: agentHooksDisabledProvidersKey) ?? []
        return !disabledProviders.contains(provider.rawValue)
    }

    nonisolated static func setHooksEnabled(_ enabled: Bool, for provider: AgentProvider) {
        var disabledProviders = Set(UserDefaults.standard.stringArray(forKey: agentHooksDisabledProvidersKey) ?? [])
        if enabled {
            disabledProviders.remove(provider.rawValue)
        } else {
            disabledProviders.insert(provider.rawValue)
        }
        UserDefaults.standard.set(disabledProviders.sorted(), forKey: agentHooksDisabledProvidersKey)
    }

    static var isUsageEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: isUsageEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: isUsageEnabledKey) }
    }

    static var notchLeftContent: NotchSlotContent {
        get { NotchSlotContent(rawValue: UserDefaults.standard.string(forKey: notchLeftContentKey) ?? "") ?? .ring }
        set {
            writeNotchSlot(
                newValue,
                previous: notchLeftContent,
                other: notchRightContent,
                key: notchLeftContentKey,
                otherKey: notchRightContentKey
            )
        }
    }

    static var notchRightContent: NotchSlotContent {
        get { NotchSlotContent(rawValue: UserDefaults.standard.string(forKey: notchRightContentKey) ?? "") ?? .latest }
        set {
            writeNotchSlot(
                newValue,
                previous: notchRightContent,
                other: notchLeftContent,
                key: notchRightContentKey,
                otherKey: notchLeftContentKey
            )
        }
    }

    private static func writeNotchSlot(
        _ newValue: NotchSlotContent,
        previous: NotchSlotContent,
        other: NotchSlotContent,
        key: String,
        otherKey: String
    ) {
        UserDefaults.standard.set(newValue.rawValue, forKey: key)
        if NotchSlotContent.conflict(newValue, other) {
            let resolved: NotchSlotContent = other == newValue ? previous : .ring
            UserDefaults.standard.set(resolved.rawValue, forKey: otherKey)
        }
    }

    static var hideSpriteWhenIdle: Bool {
        get { UserDefaults.standard.bool(forKey: hideSpriteWhenIdleKey) }
        set { UserDefaults.standard.set(newValue, forKey: hideSpriteWhenIdleKey) }
    }

    static var hideGrassIsland: Bool {
        get { UserDefaults.standard.bool(forKey: hideGrassIslandKey) }
        set { UserDefaults.standard.set(newValue, forKey: hideGrassIslandKey) }
    }

    static var panelToggleShortcut: GlobalShortcut {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: panelToggleShortcutKey),
                  let shortcut = GlobalShortcut(rawValue: rawValue) else {
                return .defaultTogglePanel
            }
            return shortcut
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: panelToggleShortcutKey)
        }
    }

    static var lastUsedAgentProvider: AgentProvider {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: lastUsedAgentProviderKey),
                  let provider = AgentProvider(rawValue: rawValue) else {
                return .claude
            }
            return provider
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: lastUsedAgentProviderKey)
        }
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

    static func apiBaseURL(for provider: EmotionAnalysisProvider) -> String? {
        let value = UserDefaults.standard.string(forKey: apiBaseURLKey(for: provider))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func setApiBaseURL(_ baseURL: String?, for provider: EmotionAnalysisProvider) {
        let trimmed = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: apiBaseURLKey(for: provider))
        } else {
            UserDefaults.standard.removeObject(forKey: apiBaseURLKey(for: provider))
        }
    }

    private static func apiBaseURLKey(for provider: EmotionAnalysisProvider) -> String {
        switch provider {
        case .claude:
            emotionAnalysisClaudeBaseURLKey
        case .openAI:
            emotionAnalysisOpenAIBaseURLKey
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

    static var notificationSoundSelection: NotificationSoundSelection {
        get {
            if let data = UserDefaults.standard.data(forKey: notificationSoundSelectionKey),
               let selection = try? JSONDecoder().decode(NotificationSoundSelection.self, from: data) {
                return selection
            }

            guard let rawValue = UserDefaults.standard.string(forKey: notificationSoundKey),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .defaultValue
            }
            return .system(sound)
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: notificationSoundSelectionKey)
            }
            if case .system(let sound) = newValue {
                UserDefaults.standard.set(sound.rawValue, forKey: notificationSoundKey)
            }
            UserDefaults.standard.set(newValue == .system(.none), forKey: isMutedKey)
        }
    }

    static var customNotificationSounds: [CustomNotificationSound] {
        get {
            guard let data = UserDefaults.standard.data(forKey: customNotificationSoundsKey),
                  let sounds = try? JSONDecoder().decode([CustomNotificationSound].self, from: data) else {
                return []
            }
            return sounds.sorted { $0.createdAt > $1.createdAt }
        }
        set {
            let newestFirst = newValue.sorted { $0.createdAt > $1.createdAt }
            if let data = try? JSONEncoder().encode(newestFirst) {
                UserDefaults.standard.set(data, forKey: customNotificationSoundsKey)
            }
        }
    }

    static func importCustomNotificationSound(from sourceURL: URL) throws -> CustomNotificationSound {
        let directory = customNotificationSoundsDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let displayName = sourceURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let destinationFileName = uniqueCustomSoundFileName(for: sourceURL)
        let destinationURL = directory.appendingPathComponent(destinationFileName)

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        let sound = CustomNotificationSound(
            id: UUID(),
            displayName: displayName.isEmpty ? sourceURL.lastPathComponent : displayName,
            fileName: destinationFileName,
            createdAt: Date()
        )
        customNotificationSounds = [sound] + customNotificationSounds
        return sound
    }

    static func customNotificationSoundURL(for sound: CustomNotificationSound) -> URL {
        customNotificationSoundsDirectory().appendingPathComponent(sound.fileName)
    }

    static func renameCustomNotificationSound(id: UUID, displayName: String) {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        customNotificationSounds = customNotificationSounds.map { sound in
            guard sound.id == id else { return sound }
            var renamed = sound
            renamed.displayName = trimmed
            return renamed
        }
    }

    static func deleteCustomNotificationSound(id: UUID) {
        if let sound = customNotificationSounds.first(where: { $0.id == id }) {
            let url = customNotificationSoundURL(for: sound)
            try? FileManager.default.removeItem(at: url)
        }

        customNotificationSounds = customNotificationSounds.filter { $0.id != id }
        notificationSoundSelection = notificationSoundSelection.fallbackIfDeletingCustomSound(id: id)
        previousSoundSelection = previousSoundSelection?.fallbackIfDeletingCustomSound(id: id)
    }

    private static func customNotificationSoundsDirectory() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport
            .appendingPathComponent("Notchi", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    private static func uniqueCustomSoundFileName(for sourceURL: URL) -> String {
        let fileExtension = sourceURL.pathExtension
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBaseName = sanitizedFileName(baseName.isEmpty ? "sound" : baseName)
        let id = UUID().uuidString

        if fileExtension.isEmpty {
            return "\(safeBaseName)-\(id)"
        }
        return "\(safeBaseName)-\(id).\(fileExtension)"
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ."))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let sanitized = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "sound" : sanitized
    }

    static var isMuted: Bool {
        get { UserDefaults.standard.bool(forKey: isMutedKey) }
        set { UserDefaults.standard.set(newValue, forKey: isMutedKey) }
    }

    static func toggleMute() {
        if isMuted {
            notificationSoundSelection = previousSoundSelection ?? previousSound.map(NotificationSoundSelection.system) ?? .defaultValue
            isMuted = false
        } else {
            previousSoundSelection = notificationSoundSelection
            if case .system(let sound) = notificationSoundSelection {
                previousSound = sound
            } else {
                previousSound = nil
            }
            notificationSoundSelection = .system(.none)
            isMuted = true
        }
    }

    private static var previousSoundSelection: NotificationSoundSelection? {
        get {
            guard let data = UserDefaults.standard.data(forKey: previousSoundSelectionKey) else {
                return nil
            }
            return try? JSONDecoder().decode(NotificationSoundSelection.self, from: data)
        }
        set {
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: previousSoundSelectionKey)
                return
            }
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: previousSoundSelectionKey)
            }
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
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: previousSoundKey)
                return
            }
            UserDefaults.standard.set(newValue.rawValue, forKey: previousSoundKey)
        }
    }
}
