import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "StateMachine")

@MainActor
@Observable
final class NotchiStateMachine {
    static let shared = NotchiStateMachine()

    private(set) var currentState: NotchiState = .idle
    let stats = SessionStats()

    private var sleepTimer: Task<Void, Never>?
    private var revertTimer: Task<Void, Never>?

    private static let sleepDelay: Duration = .seconds(300)
    private static let revertDelay: Duration = .seconds(3)

    private init() {
        startSleepTimer()
    }

    func handleEvent(_ event: HookEvent) {
        cancelSleepTimer()

        switch event.event {
        case "SessionStart":
            stats.startSession()
            transition(to: .thinking)

        case "PreToolUse":
            let toolInput = event.toolInput?.mapValues { $0.value }
            stats.recordPreToolUse(tool: event.tool, toolInput: toolInput, toolUseId: event.toolUseId)
            cancelRevertTimer()
            transition(to: .working)

        case "PostToolUse":
            let success = event.status != "error"
            stats.recordPostToolUse(tool: event.tool, toolUseId: event.toolUseId, success: success)
            transition(to: success ? .happy : .alert)
            scheduleRevert()

        case "SessionEnd":
            stats.endSession()
            cancelRevertTimer()
            transition(to: .idle)

        default:
            break
        }

        startSleepTimer()
    }

    private func transition(to newState: NotchiState) {
        guard currentState != newState else { return }
        logger.info("State: \(self.currentState.rawValue, privacy: .public) → \(newState.rawValue, privacy: .public)")
        currentState = newState
    }

    private func startSleepTimer() {
        sleepTimer = Task {
            try? await Task.sleep(for: Self.sleepDelay)
            guard !Task.isCancelled else { return }
            transition(to: .sleeping)
        }
    }

    private func cancelSleepTimer() {
        sleepTimer?.cancel()
        sleepTimer = nil
    }

    private func scheduleRevert() {
        revertTimer = Task {
            try? await Task.sleep(for: Self.revertDelay)
            guard !Task.isCancelled else { return }
            transition(to: .idle)
        }
    }

    private func cancelRevertTimer() {
        revertTimer?.cancel()
        revertTimer = nil
    }
}
