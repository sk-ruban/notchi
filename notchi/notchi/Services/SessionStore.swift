import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "SessionStore")

extension Notification.Name {
    static let sessionStoreActiveSessionCountDidChange = Notification.Name("sessionStoreActiveSessionCountDidChange")
}

@MainActor
@Observable
final class SessionStore {
    static let shared = SessionStore()

    private(set) var sessions: [String: SessionData] = [:]
    private(set) var selectedSessionId: String?
    private var displaySessionNumbersById: [String: Int] = [:]

    private init() {}

    var sortedSessions: [SessionData] {
        sessions.values.sorted { lhs, rhs in
            if lhs.isProcessing != rhs.isProcessing {
                return lhs.isProcessing
            }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    var activeSessionCount: Int {
        sessions.count
    }

    var selectedSession: SessionData? {
        guard let id = selectedSessionId else { return nil }
        return sessions[id]
    }

    var effectiveSession: SessionData? {
        if let selected = selectedSession {
            return selected
        }
        if sessions.count == 1 {
            return sessions.values.first
        }
        return sortedSessions.first
    }

    func selectSession(_ sessionId: String?) {
        if let id = sessionId {
            guard sessions[id] != nil else { return }
        }
        selectedSessionId = sessionId
        logger.info("Selected session: \(sessionId ?? "nil", privacy: .public)")
    }

    func process(_ event: HookEvent) -> SessionData {
        let isInteractive = event.interactive ?? true
        let session = getOrCreateSession(sessionId: event.sessionId, cwd: event.cwd, isInteractive: isInteractive)
        let isProcessing = event.status != "waiting_for_input"
        session.updateProcessingState(isProcessing: isProcessing)

        if let mode = event.permissionMode {
            session.updatePermissionMode(mode)
        }

        switch event.event {
        case "UserPromptSubmit":
            if let prompt = event.userPrompt {
                session.recordUserPrompt(prompt)
            }
            session.clearRecentEvents()
            session.clearAssistantMessages()
            session.clearPendingQuestions()
            if Self.isLocalSlashCommand(event.userPrompt) {
                session.updateTask(.idle)
            } else {
                session.advanceSpinnerVerbForReply()
                session.updateTask(.working)
            }

        case "PreCompact":
            session.updateTask(.compacting)

        case "SessionStart":
            if isProcessing {
                session.updateTask(.working)
            }

        case "PreToolUse":
            let toolInput = event.toolInput?.mapValues { $0.value }
            session.recordPreToolUse(tool: event.tool, toolInput: toolInput, toolUseId: event.toolUseId)
            if event.tool == "AskUserQuestion" {
                session.updateTask(.waiting)
                session.setPendingQuestions(Self.parseQuestions(from: event.toolInput))
            } else {
                session.clearPendingQuestions()
                session.updateTask(.working)
            }

        case "PermissionRequest":
            let question = Self.buildPermissionQuestion(tool: event.tool, toolInput: event.toolInput)
            session.updateTask(.waiting)
            session.setPendingQuestions([question])

        case "PostToolUse":
            let success = event.status != "error"
            session.recordPostToolUse(tool: event.tool, toolUseId: event.toolUseId, success: success)
            session.clearPendingQuestions()
            session.updateTask(.working)

        case "Stop", "SubagentStop":
            session.clearPendingQuestions()
            session.updateTask(.idle)

        case "SessionEnd":
            session.endSession()
            removeSession(event.sessionId)

        default:
            if !isProcessing && session.task != .idle {
                session.updateTask(.idle)
            }
        }

        return session
    }

    func recordAssistantMessages(_ messages: [AssistantMessage], for sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        session.recordAssistantMessages(messages)
    }

    func displaySessionNumber(for session: SessionData) -> Int {
        displaySessionNumbersById[session.id] ?? 1
    }

    func displaySessionLabel(for session: SessionData) -> String {
        "\(session.projectName) #\(displaySessionNumber(for: session))"
    }

    func displayTitle(for session: SessionData) -> String {
        let label = displaySessionLabel(for: session)
        if let prompt = session.lastUserPrompt {
            return "\(label) - \(prompt)"
        }
        return label
    }

    private func getOrCreateSession(sessionId: String, cwd: String, isInteractive: Bool) -> SessionData {
        if let existing = sessions[sessionId] {
            return existing
        }

        let existingXPositions = sessions.values.map(\.spriteXPosition)
        let session = SessionData(sessionId: sessionId, cwd: cwd, isInteractive: isInteractive, existingXPositions: existingXPositions)
        sessions[sessionId] = session
        recomputeDisplaySessionNumbers()
        logger.info("Created session #\(self.displaySessionNumber(for: session)): \(sessionId, privacy: .public) at \(cwd, privacy: .public)")
        postActiveSessionCountChange()

        if activeSessionCount == 1 {
            selectedSessionId = sessionId
        } else {
            selectedSessionId = nil
        }

        return session
    }

    private func removeSession(_ sessionId: String) {
        sessions.removeValue(forKey: sessionId)
        recomputeDisplaySessionNumbers()
        logger.info("Removed session: \(sessionId, privacy: .public)")
        postActiveSessionCountChange()

        if selectedSessionId == sessionId {
            selectedSessionId = nil
        }

        if activeSessionCount == 1 {
            selectedSessionId = sessions.keys.first
        }
    }

    func dismissSession(_ sessionId: String) {
        sessions[sessionId]?.endSession()
        removeSession(sessionId)
    }

    private func postActiveSessionCountChange() {
        NotificationCenter.default.post(
            name: .sessionStoreActiveSessionCountDidChange,
            object: self
        )
    }

    private func recomputeDisplaySessionNumbers() {
        let groupedSessions = Dictionary(grouping: sessions.values, by: \.projectName)
        var displayNumbers: [String: Int] = [:]

        for projectSessions in groupedSessions.values {
            let orderedSessions = projectSessions.sorted { lhs, rhs in
                if lhs.sessionStartTime != rhs.sessionStartTime {
                    return lhs.sessionStartTime < rhs.sessionStartTime
                }
                return lhs.id < rhs.id
            }

            for (index, session) in orderedSessions.enumerated() {
                displayNumbers[session.id] = index + 1
            }
        }

        displaySessionNumbersById = displayNumbers
    }

    private static func parseQuestions(from toolInput: [String: AnyCodable]?) -> [PendingQuestion] {
        guard let input = toolInput?.mapValues({ $0.value }),
              let questions = input["questions"] as? [[String: Any]] else { return [] }

        return questions.compactMap { q in
            guard let questionText = q["question"] as? String else { return nil }
            let header = q["header"] as? String
            let rawOptions = q["options"] as? [[String: Any]] ?? []
            let options = rawOptions.compactMap { opt -> (label: String, description: String?)? in
                guard let label = opt["label"] as? String else { return nil }
                return (label: label, description: opt["description"] as? String)
            }
            return PendingQuestion(question: questionText, header: header, options: options)
        }
    }

    private static let localSlashCommands: Set<String> = [
        "/clear", "/help", "/cost", "/status",
        "/vim", "/fast", "/model", "/login", "/logout",
    ]

    static func isLocalSlashCommand(_ prompt: String?) -> Bool {
        guard let prompt, prompt.hasPrefix("/") else { return false }
        let command = String(prompt.prefix(while: { !$0.isWhitespace }))
        return localSlashCommands.contains(command)
    }

    private static func buildPermissionQuestion(tool: String?, toolInput: [String: AnyCodable]?) -> PendingQuestion {
        let toolName = tool ?? "Tool"
        let input = toolInput?.mapValues { $0.value }
        let description = SessionEvent.deriveDescription(tool: tool, toolInput: input)
        return PendingQuestion(
            question: description ?? "\(toolName) wants to proceed",
            header: "Permission Request",
            // Claude Code permission prompts always present these three choices
            options: [
                (label: "Yes", description: nil),
                (label: "Yes, and don't ask again", description: nil),
                (label: "No", description: nil),
            ]
        )
    }
}
