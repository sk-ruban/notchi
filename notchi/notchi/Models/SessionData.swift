import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "SessionData")

struct PendingQuestion {
    let question: String
    let header: String?
    let options: [(label: String, description: String?)]
}

@MainActor
@Observable
final class SessionData: Identifiable {
    let id: String
    let provider: SessionProvider
    let cwd: String
    let sessionNumber: Int
    let sessionStartTime: Date
    let spriteXPosition: CGFloat
    let spriteYOffset: CGFloat
    let isInteractive: Bool

    private(set) var task: NotchiTask = .idle
    let emotionState = EmotionState()
    var state: NotchiState {
        NotchiState(
            task: task,
            emotion: emotionState.currentEmotion,
            creature: provider.spriteCreature
        )
    }
    private(set) var isProcessing: Bool = false
    private(set) var lastActivity: Date
    private(set) var recentEvents: [SessionEvent] = []
    private(set) var recentAssistantMessages: [AssistantMessage] = []
    private(set) var lastUserPrompt: String?
    private(set) var promptSubmitTime: Date?
    private(set) var permissionMode: String = "default"
    private(set) var pendingQuestions: [PendingQuestion] = []

    private var durationTimer: Task<Void, Never>?
    private var sleepTimer: Task<Void, Never>?
    private(set) var formattedDuration: String = "0m 00s"

    private static let maxEvents = 20
    private static let maxAssistantMessages = 10
    private static let sleepDelay: Duration = .seconds(300)

    var projectName: String {
        (cwd as NSString).lastPathComponent
    }

    var currentModeDisplay: String? {
        switch permissionMode {
        case "plan": return "Plan Mode"
        case "acceptEdits": return "Accept Edits"
        case "dontAsk": return "Don't Ask"
        case "bypassPermissions": return "Bypass"
        default: return nil
        }
    }

    var displayTitle: String {
        let title = "\(projectName) #\(sessionNumber)"
        if let prompt = lastUserPrompt {
            return "\(title) - \(prompt)"
        }
        return title
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

    // Sprite positioning constants (normalized 0..1 range for X, points for Y)
    private static let xPositionMin: CGFloat = 0.05
    private static let xPositionRange: CGFloat = 0.90
    private static let xMinSeparation: CGFloat = 0.15
    private static let xCollisionRetries = 10
    private static let xNudgeStep: CGFloat = 0.23

    private static let yOffsetBase: CGFloat = -5.0
    private static let yOffsetRange: UInt = 51

    init(
        sessionId: String,
        provider: SessionProvider,
        cwd: String,
        sessionNumber: Int,
        isInteractive: Bool = true,
        existingXPositions: [CGFloat] = []
    ) {
        self.id = sessionId
        self.provider = provider
        self.cwd = cwd
        self.sessionNumber = sessionNumber
        self.isInteractive = isInteractive
        self.sessionStartTime = Date()
        self.lastActivity = Date()

        let hash = UInt(bitPattern: sessionId.hashValue)
        self.spriteXPosition = Self.resolveXPosition(hash: hash, existingPositions: existingXPositions)
        self.spriteYOffset = Self.resolveYOffset(hash: hash)

        startDurationTimer()
    }

    private static func resolveXPosition(hash: UInt, existingPositions: [CGFloat]) -> CGFloat {
        var candidate = xPositionMin + CGFloat(hash % 900) / 1000.0

        for _ in 0..<xCollisionRetries {
            let tooClose = existingPositions.contains { abs($0 - candidate) < xMinSeparation }
            if !tooClose { break }
            candidate = (candidate + xNudgeStep).truncatingRemainder(dividingBy: xPositionRange) + xPositionMin
        }

        return candidate
    }

    private static func resolveYOffset(hash: UInt) -> CGFloat {
        let yBits = (hash >> 8) & 0xFF
        return yOffsetBase - CGFloat(yBits % yOffsetRange)
    }

    func updateTask(_ newTask: NotchiTask) {
        task = newTask
        lastActivity = Date()
    }

    func updateProcessingState(isProcessing: Bool) {
        self.isProcessing = isProcessing
        lastActivity = Date()
    }

    func recordUserPrompt(_ prompt: String) {
        let now = Date()
        lastUserPrompt = prompt.truncatedForPrompt()
        promptSubmitTime = now
        lastActivity = now
        logger.debug("Setting promptSubmitTime to: \(now)")
    }

    func updatePermissionMode(_ mode: String) {
        permissionMode = mode
    }

    func setPendingQuestions(_ questions: [PendingQuestion]) {
        pendingQuestions = questions
        lastActivity = Date()
    }

    func clearPendingQuestions() {
        pendingQuestions = []
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

    func resetSleepTimer() {
        sleepTimer?.cancel()
        sleepTimer = Task {
            try? await Task.sleep(for: Self.sleepDelay)
            guard !Task.isCancelled else { return }
            updateTask(.sleeping)
        }
    }

    func endSession() {
        durationTimer?.cancel()
        durationTimer = nil
        sleepTimer?.cancel()
        sleepTimer = nil
        isProcessing = false
    }

    private func trimEvents() {
        while recentEvents.count > Self.maxEvents {
            recentEvents.removeFirst()
        }
    }

    private func startDurationTimer() {
        durationTimer = Task {
            while !Task.isCancelled {
                updateFormattedDuration()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func updateFormattedDuration() {
        let total = Int(Date().timeIntervalSince(sessionStartTime))
        let minutes = total / 60
        let seconds = total % 60
        formattedDuration = String(format: "%dm %02ds", minutes, seconds)
    }
}
