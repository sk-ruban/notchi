import Foundation
struct PendingQuestion {
    static let freeTextOptionLabel = String(localized: "Type something")
    private static let rawFreeTextOptionLabel = "Type something"

    let question: String
    let header: String?
    let options: [(label: String, description: String?)]

    static func isFreeTextOptionLabel(_ label: String, localizedLabel: String = freeTextOptionLabel) -> Bool {
        let normalized = normalizedFreeTextLabel(label)
        return [rawFreeTextOptionLabel, localizedLabel].contains {
            normalized.caseInsensitiveCompare(normalizedFreeTextLabel($0)) == .orderedSame
        }
    }

    private static func normalizedFreeTextLabel(_ label: String) -> String {
        label.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }
}

@MainActor
@Observable
final class SessionData: Identifiable {
    let id: String
    let provider: AgentProvider
    let rawSessionId: String
    let sessionKey: ProviderSessionKey
    let cwd: String
    let sessionStartTime: Date
    let spriteXPosition: CGFloat
    let spriteYOffset: CGFloat
    let isInteractive: Bool

    private(set) var task: NotchiTask = .idle
    let emotionState = EmotionState()
    var state: NotchiState {
        NotchiState(task: task, emotion: emotionState.currentEmotion, spriteFamily: provider.spriteFamily)
    }
    private(set) var isProcessing: Bool = false
    private(set) var lastActivity: Date
    private(set) var recentEvents: [SessionEvent] = []
    private(set) var recentAssistantMessages: [AssistantMessage] = []
    private(set) var lastUserPrompt: String?
    private(set) var lastUserPromptHasAttachments: Bool = false
    private(set) var lastUserPromptImageAttachments: [UserPromptImageAttachment] = []
    private(set) var lastUserPromptHasOtherAttachments: Bool = false
    private(set) var promptSubmitTime: Date?
    private(set) var permissionMode: String = "default"
    private(set) var isFastMode = false
    private(set) var contextTokens: Int?
    private(set) var contextWindowTokens = SessionData.standardContextWindow
    private(set) var gitBranch: String?
    private(set) var gitPullRequest: GitPullRequest?
    private(set) var pendingQuestions: [PendingQuestion] = []
    private(set) var pendingQuestionResponseContext: PendingQuestionResponseContext?
    private(set) var currentSpinnerVerb: String
    private(set) var claudeProcessId: Int?
    /// Raw `CLAUDE_CONFIG_DIR` the session ran with; nil for the default Claude account.
    private(set) var claudeConfigDir: String?
    /// The session's Claude config directory on disk; nil when unknown.
    private(set) var claudeConfigDirectory: URL?
    private(set) var devinProcessId: Int?
    private(set) var codexProcessId: Int?
    private(set) var codexOrigin: CodexOrigin?
    private(set) var hostBundleIdentifier: String?
    private(set) var codexTitle: String?
    private(set) var claudeSessionName: String?
    private(set) var codexTranscriptPath: String?
    private(set) var codexArchived: Bool = false
    private(set) var hasResolvedCodexThread: Bool = false
    private(set) var codexCompactionSignal: CodexCompactionSignal?

    private var sleepTimer: Task<Void, Never>?

    private static let maxEvents = 20
    private static let storedPromptMaxLength = 2000
    private static let maxAssistantMessages = 10
    private static let sleepDelay: Duration = .seconds(300)

    var projectName: String {
        Self.projectName(forDirectory: cwd)
    }

    // T3 Code runs project-less threads in `<base>/scratch/<date>-<prompt words>-<id>`, where <id> is the
    // thread UUID's last 8 characters, or, when that folder is taken, all 32 plus an optional random 8.
    // Exact lengths keep a long last prompt word from being read as the id.
    nonisolated private static let t3ScratchParentName = "scratch"
    nonisolated private static let t3FullThreadId = #/[a-z0-9]{32}/#
    nonisolated private static let t3ScratchFolder =
        #/^\d{4}-\d{2}-\d{2}-(?<words>[a-z0-9-]+?)-(?:[a-z0-9]{8}|[a-z0-9]{32}(?:-[a-z0-9]{8})?)$/#

    /// The folder's name, or for a T3 Code scratch folder the prompt words it was named after.
    nonisolated static func projectName(forDirectory directory: String) -> String {
        let folder = (directory as NSString).lastPathComponent
        let parent = ((directory as NSString).deletingLastPathComponent as NSString).lastPathComponent
        guard parent == t3ScratchParentName,
              let match = folder.wholeMatch(of: t3ScratchFolder),
              // A word-less `<date>-<full id>-<random>` folder would otherwise read its id as the words.
              match.words.wholeMatch(of: t3FullThreadId) == nil else {
            return folder
        }
        return match.words.replacingOccurrences(of: "-", with: " ")
    }

    var currentModeDisplay: String? {
        switch permissionMode {
        case "plan": return String(localized: "Plan Mode")
        case "acceptEdits": return String(localized: "Accept Edits")
        case "auto": return String(localized: "Auto")
        case "dontAsk": return String(localized: "Don't Ask")
        case "bypassPermissions": return String(localized: "Bypass")
        case CodexPermissionMode.readOnly: return String(localized: "Read Only")
        case CodexPermissionMode.standard: return String(localized: "Default")
        case CodexPermissionMode.fullAccess: return String(localized: "Full Access")
        default: return nil
        }
    }

    var activityPreview: String? {
        if let lastEvent = recentEvents.last {
            return lastEvent.description ?? lastEvent.tool ?? lastEvent.type
        }
        if let lastMessage = recentAssistantMessages.last {
            return String(lastMessage.text.prefix(50))
        }
        return nil
    }

    var isCodexProcessMonitored: Bool {
        provider == .codex && codexProcessId != nil && (codexOrigin == .cli || hostBundleIdentifier != nil)
    }

    var isClaudeProcessBacked: Bool {
        provider == .claude && claudeProcessId != nil
    }

    var isCodexThreadBacked: Bool {
        provider == .codex && codexTranscriptPath != nil
    }

    var hostProcessId: Int? {
        switch provider {
        case .claude:
            claudeProcessId
        case .codex:
            codexProcessId
        case .devin:
            devinProcessId
        }
    }

    // Sprite positioning constants (normalized 0..1 range for X, points for Y)
    private static let xPositionMin: CGFloat = 0.05
    private static let xPositionRange: CGFloat = 0.90
    private static let xMinSeparation: CGFloat = 0.15
    private static let xCollisionRetries = 10
    private static let xNudgeStep: CGFloat = 0.23

    private static let yOffsetBase: CGFloat = -5.0
    private static let yOffsetRange: UInt = 51

    init(
        sessionKey: ProviderSessionKey,
        cwd: String,
        isInteractive: Bool = true,
        existingXPositions: [CGFloat] = [],
        sessionStartTime: Date = Date()
    ) {
        self.id = sessionKey.stableId
        self.provider = sessionKey.provider
        self.rawSessionId = sessionKey.rawSessionId
        self.sessionKey = sessionKey
        self.cwd = cwd
        self.isInteractive = isInteractive
        self.sessionStartTime = sessionStartTime
        self.lastActivity = sessionStartTime
        self.currentSpinnerVerb = SpinnerVerbs.providerVerb(for: sessionKey.provider)

        let hash = UInt(bitPattern: sessionKey.stableId.hashValue)
        self.spriteXPosition = Self.resolveXPosition(hash: hash, existingPositions: existingXPositions)
        self.spriteYOffset = Self.resolveYOffset(hash: hash)
    }

    nonisolated deinit {}

    convenience init(
        sessionId: String,
        provider: AgentProvider = .claude,
        cwd: String,
        isInteractive: Bool = true,
        existingXPositions: [CGFloat] = [],
        sessionStartTime: Date = Date()
    ) {
        self.init(
            sessionKey: ProviderSessionKey(provider: provider, rawSessionId: sessionId),
            cwd: cwd,
            isInteractive: isInteractive,
            existingXPositions: existingXPositions,
            sessionStartTime: sessionStartTime
        )
    }

    private static func resolveXPosition(hash: UInt, existingPositions: [CGFloat]) -> CGFloat {
        let initialCandidate = xPositionMin + CGFloat(hash % 900) / 1000.0
        var bestCandidate = initialCandidate
        var bestMinimumSeparation = minimumSeparation(for: initialCandidate, existingPositions: existingPositions)

        for attempt in 0...xCollisionRetries {
            let candidate = wrappedXPosition(initialCandidate + (CGFloat(attempt) * xNudgeStep))
            let minimumSeparation = minimumSeparation(for: candidate, existingPositions: existingPositions)

            if minimumSeparation >= xMinSeparation {
                return candidate
            }

            if minimumSeparation > bestMinimumSeparation {
                bestCandidate = candidate
                bestMinimumSeparation = minimumSeparation
            }
        }

        return bestCandidate
    }

    private static func wrappedXPosition(_ value: CGFloat) -> CGFloat {
        let offset = (value - xPositionMin).truncatingRemainder(dividingBy: xPositionRange)
        let normalizedOffset = offset >= 0 ? offset : offset + xPositionRange
        return normalizedOffset + xPositionMin
    }

    private static func minimumSeparation(for candidate: CGFloat, existingPositions: [CGFloat]) -> CGFloat {
        existingPositions.map { abs($0 - candidate) }.min() ?? .greatestFiniteMagnitude
    }

#if DEBUG
    static func resolveXPositionForTesting(hash: UInt, existingPositions: [CGFloat]) -> CGFloat {
        resolveXPosition(hash: hash, existingPositions: existingPositions)
    }
#endif

    private static func resolveYOffset(hash: UInt) -> CGFloat {
        let yBits = (hash >> 8) & 0xFF
        return yOffsetBase - CGFloat(yBits % yOffsetRange)
    }

    func updateTask(_ newTask: NotchiTask) {
        if newTask == .working, task == .compacting, hasActiveCodexCompactionSignal {
            lastActivity = Date()
            return
        }

        task = newTask
        lastActivity = Date()
    }

    private var hasActiveCodexCompactionSignal: Bool {
        guard provider == .codex,
              isProcessing,
              let signal = codexCompactionSignal,
              signal.tokenLimitReached else {
            return false
        }

        if let promptSubmitTime, signal.observedAt < promptSubmitTime {
            return false
        }

        return true
    }

    func updateProcessingState(isProcessing: Bool) {
        self.isProcessing = isProcessing
        lastActivity = Date()
    }

    private nonisolated static let harnessInjectedPromptMarkers = [
        "<task-notification>",
        "<system-reminder>",
        "[SYSTEM NOTIFICATION",
        "<agent-message",
    ]

    nonisolated static func isHarnessInjectedPrompt(_ prompt: String?) -> Bool {
        guard let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return harnessInjectedPromptMarkers.contains { trimmed.hasPrefix($0) }
    }

    // Claude Code wraps pasted text in <pasted_content id="…"> tags before it reaches the transcript.
    private nonisolated static let pastedContentTagPattern = /\s*<\/?pasted_content id="[^"]*">\s*/

    nonisolated static func strippingPastedContentTags(_ prompt: String) -> String {
        prompt.replacing(pastedContentTagPattern) { _ in " " }
    }

    func recordUserPrompt(
        _ prompt: String?,
        hasAttachments: Bool = false,
        imageAttachments: [UserPromptImageAttachment] = [],
        hasOtherAttachments: Bool = false
    ) {
        let now = Date()
        if Self.isHarnessInjectedPrompt(prompt) {
            promptSubmitTime = now
            lastActivity = now
            if provider == .codex {
                codexCompactionSignal = nil
            }
            return
        }
        let normalizedPrompt = provider == .claude ? prompt.map(Self.strippingPastedContentTags) : prompt
        if let trimmedPrompt = normalizedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedPrompt.isEmpty {
            lastUserPrompt = String(trimmedPrompt.prefix(Self.storedPromptMaxLength))
        } else {
            lastUserPrompt = nil
        }
        lastUserPromptHasAttachments = hasAttachments
        lastUserPromptImageAttachments = imageAttachments
        lastUserPromptHasOtherAttachments = hasOtherAttachments
        promptSubmitTime = now
        if provider == .codex {
            codexCompactionSignal = nil
        }
        lastActivity = now
    }

    func advanceSpinnerVerbForReply() {
        currentSpinnerVerb = SpinnerVerbs.nextWorkingVerb(after: currentSpinnerVerb)
    }

    func updatePermissionMode(_ mode: String) {
        permissionMode = mode
    }

    func updateFastMode(_ isFastMode: Bool) {
        self.isFastMode = isFastMode
    }

    nonisolated static let standardContextWindow = 200_000
    nonisolated static let extendedContextWindow = 1_000_000

    // Transcripts don't record the window, so a session is taken as 1M once it has outgrown 200k.
    func updateContextTokens(_ tokens: Int, peak: Int? = nil) {
        contextTokens = tokens
        if max(tokens, peak ?? 0) > Self.standardContextWindow {
            contextWindowTokens = Self.extendedContextWindow
        }
    }

    func updateGitBranch(_ branch: String?) {
        gitBranch = branch
    }

    func updateGitPullRequest(_ pullRequest: GitPullRequest?) {
        gitPullRequest = pullRequest
    }

    /// Notchi's Claude usage reads the default account's login, so it only describes these sessions.
    var usesDefaultClaudeAccount: Bool {
        provider != .claude || claudeConfigDir == nil
    }

    func updateClaudeAccount(configDir: String?, transcriptPath: String?) {
        guard provider == .claude else { return }
        claudeConfigDir = configDir
        claudeConfigDirectory = Self.claudeConfigDirectory(transcriptPath: transcriptPath, rawConfigDir: configDir)
    }

    /// Transcripts live at `<config dir>/projects/...`; that path is absolute and normalized, unlike
    /// the raw `CLAUDE_CONFIG_DIR`, which can be relative to wherever Claude was launched.
    nonisolated static func claudeConfigDirectory(transcriptPath: String?, rawConfigDir: String?) -> URL? {
        if let transcriptPath, let projects = transcriptPath.range(of: "/projects/", options: .backwards) {
            return URL(fileURLWithPath: String(transcriptPath[..<projects.lowerBound]), isDirectory: true)
        }
        if let rawConfigDir, rawConfigDir.hasPrefix("/") {
            return URL(fileURLWithPath: rawConfigDir, isDirectory: true)
        }
        return nil
    }

    func updateClaudeRuntime(processId: Int?) {
        guard provider == .claude,
              let processId,
              Self.isValidProcessId(processId) else { return }

        claudeProcessId = processId
    }

    func updateCodexRuntime(processId: Int?, origin: CodexOrigin?) {
        guard provider == .codex else { return }

        if let processId, Self.isValidProcessId(processId) {
            codexProcessId = processId
        }

        if let origin {
            codexOrigin = origin
        }
    }

    func updateDevinRuntime(processId: Int?) {
        guard provider == .devin,
              let processId,
              Self.isValidProcessId(processId) else { return }

        devinProcessId = processId
    }

    private static func isValidProcessId(_ processId: Int) -> Bool {
        processId > 0 && processId <= Int(pid_t.max)
    }

    func updateHostBundleIdentifier(_ bundleIdentifier: String?) {
        hostBundleIdentifier = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
    }

    func updateClaudeSessionName(_ name: String?) {
        let name = name.map { $0.truncatedForPrompt() }.flatMap { $0.isEmpty ? nil : $0 }
        guard provider == .claude, name != claudeSessionName else { return }
        claudeSessionName = name
    }

    func updateCodexTitle(_ title: String?) {
        guard provider == .codex,
              let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return }

        codexTitle = title.truncatedForPrompt()
    }

    func updateCodexThreadMetadata(transcriptPath: String, metadata: CodexThreadMetadata?) {
        guard provider == .codex else { return }

        let trimmedPath = transcriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return }

        if codexTranscriptPath != trimmedPath {
            hasResolvedCodexThread = false
        }
        codexTranscriptPath = trimmedPath

        guard let metadata else { return }
        hasResolvedCodexThread = true
        updateCodexTitle(metadata.title)
        codexArchived = metadata.archived
    }

    func updateCodexCompactionSignal(_ signal: CodexCompactionSignal?) {
        guard provider == .codex else { return }

        guard let signal else {
            codexCompactionSignal = nil
            return
        }

        // WHY: the latest sqlite row can belong to the previous turn until Codex
        // writes this turn's usage row, so don't let it re-enter compacting.
        if let promptSubmitTime, signal.observedAt < promptSubmitTime {
            return
        }

        codexCompactionSignal = signal

        guard isProcessing else { return }

        if signal.tokenLimitReached {
            updateTask(.compacting)
        } else if task == .compacting {
            updateTask(.working)
        }
    }

    func setPendingQuestions(
        _ questions: [PendingQuestion],
        responseContext: PendingQuestionResponseContext? = nil
    ) {
        pendingQuestions = questions
        pendingQuestionResponseContext = responseContext
        lastActivity = Date()
    }

    func clearPendingQuestions() {
        pendingQuestions = []
        pendingQuestionResponseContext = nil
    }

    func recordPreToolUse(tool: String?, toolInput: [String: Any]?, toolUseId: String?) {
        let description = SessionEvent.deriveDescription(tool: tool, toolInput: toolInput)
        let event = SessionEvent(
            timestamp: Date(),
            type: "PreToolUse",
            tool: tool,
            status: .running,
            toolInput: toolInput,
            toolUseId: toolUseId,
            description: description
        )
        recentEvents.append(event)
        trimEvents()
        lastActivity = Date()
    }

    func recordPostToolUse(tool: String?, toolUseId: String?, success: Bool) {
        if let toolUseId,
           let index = recentEvents.lastIndex(where: { $0.toolUseId == toolUseId && $0.status == .running }) {
            recentEvents[index].status = success ? .success : .error
        } else {
            let event = SessionEvent(
                timestamp: Date(),
                type: "PostToolUse",
                tool: tool,
                status: success ? .success : .error,
                toolInput: nil,
                toolUseId: toolUseId,
                description: nil
            )
            recentEvents.append(event)
            trimEvents()
        }
        lastActivity = Date()
    }

    func recordAssistantMessages(_ messages: [AssistantMessage]) {
        recentAssistantMessages.append(contentsOf: messages)
        while recentAssistantMessages.count > Self.maxAssistantMessages {
            recentAssistantMessages.removeFirst()
        }
        lastActivity = Date()
    }

    func clearAssistantMessages() {
        recentAssistantMessages = []
    }

    func clearRecentEvents() {
        recentEvents = []
    }

    func resetSleepTimer() {
        sleepTimer?.cancel()
        sleepTimer = Task {
            try? await Task.sleep(for: Self.sleepDelay)
            guard !Task.isCancelled else { return }
            updateTask(.sleeping)
        }
    }

    func endSession() {
        sleepTimer?.cancel()
        sleepTimer = nil
        isProcessing = false
    }

    private func trimEvents() {
        while recentEvents.count > Self.maxEvents {
            recentEvents.removeFirst()
        }
    }
}

nonisolated struct PendingQuestionResponseContext: Sendable {
    enum Kind: Sendable {
        case askUserQuestion
        case permissionRequest
    }

    let requestId: String
    let hookEventName: String
    let toolInput: [String: AnyCodable]?
    let permissionSuggestions: [AnyCodable]?
    let kind: Kind
}
