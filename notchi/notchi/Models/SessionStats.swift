import Foundation

struct SessionEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let type: String
    let tool: String?
    let success: Bool?
}

@MainActor
@Observable
final class SessionStats {
    var sessionStartTime: Date?
    var eventCount: Int = 0
    var recentEvents: [SessionEvent] = []
    private(set) var formattedDuration: String = "0m 00s"

    private var durationTimer: Task<Void, Never>?

    func recordEvent(type: String, tool: String?, success: Bool?) {
        eventCount += 1
        let event = SessionEvent(timestamp: Date(), type: type, tool: tool, success: success)
        recentEvents.append(event)
        if recentEvents.count > 3 {
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
