import Foundation

struct AppSettings {
    static let showSpriteWhenIdleKey = "showSpriteWhenIdle"
    static let islandBackgroundKey = "islandBackground"
    static let showGrassIslandKey = "showGrassIsland"
    static let showGitBranchAndPullRequestKey = "showGitBranchAndPullRequest"
    static let sleepRetirementKey = "sleepRetirement"
    static let expandOnHoverKey = "expandOnHover"
    static let panelToggleShortcutKey = "panelToggleShortcut"
    static let notchLeftContentKey = "notchLeftContent"
    static let notchRightContentKey = "notchRightContent"
    static let expandedPanelScaleKey = "expandedPanelScale"
    static let mainUsageBarPeriodKey = "mainUsageBarPeriod"

    private static let notificationSoundSelectionKey = "notificationSoundSelection"
    private static let customNotificationSoundsKey = "customNotificationSounds"
    static let isMutedKey = "isMuted"
    private static let previousSoundSelectionKey = "previousNotificationSoundSelection"
    private static let isUsageEnabledKey = "isUsageEnabled"
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

    static var mainUsageBarPeriod: MainUsageBarPeriod {
        get { mainUsageBarPeriod(fromRaw: UserDefaults.standard.string(forKey: mainUsageBarPeriodKey)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: mainUsageBarPeriodKey) }
    }

    static func mainUsageBarPeriod(fromRaw raw: String?) -> MainUsageBarPeriod {
        MainUsageBarPeriod(rawValue: raw ?? "") ?? .session
    }

    static func expandedPanelScale(in defaults: UserDefaults) -> ExpandedPanelScale {
        ExpandedPanelScale(rawValue: defaults.string(forKey: expandedPanelScaleKey) ?? "") ?? .automatic
    }

    static var expandedPanelScale: ExpandedPanelScale {
        get { expandedPanelScale(in: .standard) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: expandedPanelScaleKey) }
    }

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            showSpriteWhenIdleKey: true,
            showGrassIslandKey: true,
            showGitBranchAndPullRequestKey: true,
        ])
    }

    static func sleepRetirement(fromRaw raw: String?) -> SleepRetirement {
        SleepRetirement(rawValue: raw ?? "") ?? .fiveHours
    }

    static var sleepRetirement: SleepRetirement {
        get { sleepRetirement(fromRaw: UserDefaults.standard.string(forKey: sleepRetirementKey)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sleepRetirementKey) }
    }

    static func showSpriteWhenIdle(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: showSpriteWhenIdleKey) as? Bool ?? true
    }

    static func islandBackground(in defaults: UserDefaults) -> IslandBackground {
        IslandBackground.resolve(defaults.string(forKey: islandBackgroundKey))
    }

    static var islandBackground: IslandBackground {
        get { islandBackground(in: .standard) }
        set {
            if newValue == .automatic, islandBackground != .automatic {
                IslandBackgroundRotation.shared.restart()
            }
            UserDefaults.standard.set(newValue.rawValue, forKey: islandBackgroundKey)
        }
    }

    static var expandOnHover: Bool {
        get { UserDefaults.standard.bool(forKey: expandOnHoverKey) }
        set { UserDefaults.standard.set(newValue, forKey: expandOnHoverKey) }
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

    static var claudeExtraUsageObservation: ClaudeExtraUsageObservation? {
        get { decodedValue(ClaudeExtraUsageObservation.self, forKey: claudeExtraUsageObservationKey) }
        set { setEncodedValue(newValue, forKey: claudeExtraUsageObservationKey) }
    }

    static var emotionAnalysisProvider: EmotionAnalysisProvider {
        get {
            if let rawValue = UserDefaults.standard.string(forKey: emotionAnalysisProviderKey),
               let provider = EmotionAnalysisProvider(rawValue: rawValue) {
                return provider
            }

            let hasAnthropicKey = EmotionAnalysisCredentials.shared.apiKey(for: .claude)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
            let hasOpenAIKey = EmotionAnalysisCredentials.shared.apiKey(for: .openAI)?
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
        EmotionAnalysisCredentials.shared.apiKey(for: provider, allowInteraction: true)
    }

    static func setApiKey(_ key: String?, for provider: EmotionAnalysisProvider) {
        EmotionAnalysisCredentials.shared.setApiKey(key, for: provider)
    }

    static func apiBaseURL(for provider: EmotionAnalysisProvider, in defaults: UserDefaults = .standard) -> String? {
        let value = defaults.string(forKey: apiBaseURLKey(for: provider))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func setApiBaseURL(
        _ baseURL: String?,
        for provider: EmotionAnalysisProvider,
        in defaults: UserDefaults = .standard
    ) {
        let trimmed = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            defaults.set(trimmed, forKey: apiBaseURLKey(for: provider))
        } else {
            defaults.removeObject(forKey: apiBaseURLKey(for: provider))
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
        guard let rawValue = UserDefaults.standard.string(forKey: emotionAnalysisModelKey(for: provider))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return EmotionAnalysisModel.resolve(rawValue, for: provider)
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
            decodedValue(NotificationSoundSelection.self, forKey: notificationSoundSelectionKey) ?? .defaultValue
        }
        set {
            setEncodedValue(newValue, forKey: notificationSoundSelectionKey)
            UserDefaults.standard.set(newValue == .system(.none), forKey: isMutedKey)
        }
    }

    static var customNotificationSounds: [CustomNotificationSound] {
        get {
            let sounds = decodedValue([CustomNotificationSound].self, forKey: customNotificationSoundsKey) ?? []
            return sounds.sorted { $0.createdAt > $1.createdAt }
        }
        set {
            setEncodedValue(newValue.sorted { $0.createdAt > $1.createdAt }, forKey: customNotificationSoundsKey)
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
            notificationSoundSelection = previousSoundSelection ?? .defaultValue
            isMuted = false
        } else {
            previousSoundSelection = notificationSoundSelection
            notificationSoundSelection = .system(.none)
            isMuted = true
        }
    }

    private static var previousSoundSelection: NotificationSoundSelection? {
        get { decodedValue(NotificationSoundSelection.self, forKey: previousSoundSelectionKey) }
        set { setEncodedValue(newValue, forKey: previousSoundSelectionKey) }
    }

    private static func decodedValue<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Removes the stored value when there is none to store or it can't be encoded.
    private static func setEncodedValue<Value: Encodable>(_ value: Value?, forKey key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
