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
    private(set) var promptSubmitTime: Date?
    private(set) var permissionMode: String = "default"
    private(set) var pendingQuestions: [PendingQuestion] = []
    private(set) var pendingQuestionResponseContext: PendingQuestionResponseContext?
    private(set) var currentSpinnerVerb: String
    private(set) var claudeProcessId: Int?
    private(set) var codexProcessId: Int?
    private(set) var codexOrigin: CodexOrigin?
    private(set) var codexTitle: String?
    private(set) var codexTranscriptPath: String?
    private(set) var codexArchived: Bool = false
    private(set) var codexCompactionSignal: CodexCompactionSignal?

    private var sleepTimer: Task<Void, Never>?

    private static let maxEvents = 20
    private static let maxAssistantMessages = 10
    private static let sleepDelay: Duration = .seconds(300)

    var projectName: String {
        (cwd as NSString).lastPathComponent
    }

    var currentModeDisplay: String? {
        switch permissionMode {
        case "plan": return String(localized: "Plan Mode")
        case "acceptEdits": return String(localized: "Accept Edits")
        case "dontAsk": return String(localized: "Don't Ask")
        case "bypassPermissions": return String(localized: "Bypass")
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

    var isCodexCLIProcessBacked: Bool {
        provider == .codex && codexOrigin == .cli && codexProcessId != nil
    }

    var isClaudeProcessBacked: Bool {
        provider == .claude && claudeProcessId != nil
    }

    var isCodexThreadBacked: Bool {
        provider == .codex && codexTranscriptPath != nil
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

    func recordUserPrompt(_ prompt: String?, hasAttachments: Bool = false) {
        let now = Date()
        if let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedPrompt.isEmpty {
            lastUserPrompt = trimmedPrompt.truncatedForPrompt()
        } else {
            lastUserPrompt = nil
        }
        lastUserPromptHasAttachments = hasAttachments
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

    func updateClaudeRuntime(processId: Int?) {
        guard provider == .claude,
              let processId,
              processId > 0 else { return }

        claudeProcessId = processId
    }

    func updateCodexRuntime(processId: Int?, origin: CodexOrigin?) {
        guard provider == .codex else { return }

        if let processId, processId > 0 {
            codexProcessId = processId
        }

        if let origin {
            codexOrigin = origin
        }
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

        codexTranscriptPath = trimmedPath

        guard let metadata else { return }
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
