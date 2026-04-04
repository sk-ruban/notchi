import Foundation

private let promptMaxLength = 100

extension String {
    func truncatedForPrompt() -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > promptMaxLength else { return trimmed }
        let index = trimmed.index(trimmed.startIndex, offsetBy: promptMaxLength)
        return String(trimmed[..<index]) + "..."
    }
}

enum ToolStatus {
    case running
    case success
    case error
}

struct AssistantMessage: Identifiable {
    let id: String
    let text: String
    let timestamp: Date
}

struct SessionEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let type: String
    let tool: String?
    var status: ToolStatus
    let toolInput: [String: Any]?
    let toolUseId: String?
    let description: String?
}

extension SessionEvent {
    static func deriveDescription(tool: String?, toolInput: [String: Any]?) -> String? {
        guard let tool, let input = toolInput else { return nil }

        switch tool {
        case "Read":
            if let path = input["file_path"] as? String { return "Reading \(path)" }
        case "Write":
            if let path = input["file_path"] as? String { return "Writing \(path)" }
        case "Edit":
            if let path = input["file_path"] as? String { return "Editing \(path)" }
        case "Bash":
            if let command = input["command"] as? String {
                return command
            }
        case "Grep":
            if let pattern = input["pattern"] as? String {
                return "Searching: \(pattern)"
            }
        case "Glob":
            if let pattern = input["pattern"] as? String {
                return "Finding: \(pattern)"
            }
        case "Task":
            if let desc = input["description"] as? String {
                return desc
            }
        case "exec_command":
            if let command = input["cmd"] as? String {
                return command
            }
        case "write_stdin":
            if let chars = input["chars"] as? String, !chars.isEmpty {
                return "Sending input to running command"
            }
            return "Polling running command"
        case "read_thread_terminal":
            return "Reading thread terminal"
        case "update_plan":
            return "Updating plan"
        case "view_image":
            if let path = input["path"] as? String {
                return "Viewing \(path)"
            }
            return "Viewing image"
        case "apply_patch":
            return "Applying patch"
        default:
            break
        }

        for (_, value) in input {
            if let str = value as? String, !str.isEmpty {
                return str
            }
        }

        return nil
    }
}

@MainActor
@Observable
final class SessionStats {
    var sessionStartTime: Date?
    var eventCount: Int = 0
    var recentEvents: [SessionEvent] = []
    private(set) var formattedDuration: String = "0m 00s"
    private(set) var isProcessing: Bool = false
    private(set) var lastUserPrompt: String?

    // Assistant message storage
    private(set) var recentAssistantMessages: [AssistantMessage] = []
    private(set) var currentSessionId: String?
    private(set) var currentCwd: String?

    private var durationTimer: Task<Void, Never>?
    private static let maxEvents = 20
    private static let maxAssistantMessages = 10

    func updateProcessingState(status: String) {
        isProcessing = status != "waiting_for_input"
    }

    func recordPreToolUse(tool: String?, toolInput: [String: Any]?, toolUseId: String?) {
        eventCount += 1
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
    }

    func recordPostToolUse(tool: String?, toolUseId: String?, success: Bool) {
        eventCount += 1

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
    }

    private func trimEvents() {
        while recentEvents.count > Self.maxEvents {
            recentEvents.removeFirst()
        }
    }

    func recordUserPrompt(_ text: String) {
        lastUserPrompt = text.truncatedForPrompt()
    }

    func clearAssistantMessages() {
        recentAssistantMessages = []
    }

    func recordSessionInfo(sessionId: String, cwd: String) {
        currentSessionId = sessionId
        currentCwd = cwd
    }

    func recordAssistantMessages(_ messages: [AssistantMessage]) {
        recentAssistantMessages.append(contentsOf: messages)
        while recentAssistantMessages.count > Self.maxAssistantMessages {
            recentAssistantMessages.removeFirst()
        }
    }

    func startSession() {
        sessionStartTime = Date()
        eventCount = 0
        recentEvents = []
        recentAssistantMessages = []
        formattedDuration = "0m 00s"
        isProcessing = true
        lastUserPrompt = nil
        startDurationTimer()
    }

    func endSession() {
        durationTimer?.cancel()
        durationTimer = nil
        sessionStartTime = nil
        isProcessing = false
    }

    private func startDurationTimer() {
        durationTimer?.cancel()
        durationTimer = Task {
            while !Task.isCancelled {
                updateFormattedDuration()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func updateFormattedDuration() {
        guard let start = sessionStartTime else {
            formattedDuration = "0m 00s"
            return
        }
        let total = Int(Date().timeIntervalSince(start))
        let minutes = total / 60
        let seconds = total % 60
        formattedDuration = String(format: "%dm %02ds", minutes, seconds)
    }
}
