import Foundation

enum ToolStatus {
    case running
    case success
    case error
}

struct SessionEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let type: String
    let tool: String?
    var status: ToolStatus
    let toolInput: [String: Any]?
    let toolUseId: String?
}

@MainActor
@Observable
final class SessionStats {
    var sessionStartTime: Date?
    var eventCount: Int = 0
    var recentEvents: [SessionEvent] = []
    private(set) var formattedDuration: String = "0m 00s"

    private var durationTimer: Task<Void, Never>?
    private static let maxEvents = 20

    func recordPreToolUse(tool: String?, toolInput: [String: Any]?, toolUseId: String?) {
        eventCount += 1
        let event = SessionEvent(
            timestamp: Date(),
            type: "PreToolUse",
            tool: tool,
            status: .running,
            toolInput: toolInput,
            toolUseId: toolUseId
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
                toolUseId: toolUseId
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

    func startSession() {
        sessionStartTime = Date()
        eventCount = 0
        recentEvents = []
        formattedDuration = "0m 00s"
        startDurationTimer()
    }

    func endSession() {
        durationTimer?.cancel()
        durationTimer = nil
        sessionStartTime = nil
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
