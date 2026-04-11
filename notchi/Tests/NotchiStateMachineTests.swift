import Foundation
import XCTest
@testable import notchi

@MainActor
final class NotchiStateMachineTests: XCTestCase {
    override func tearDown() async throws {
        let sessionIds = Array(SessionStore.shared.sessions.keys)
        sessionIds.forEach { SessionStore.shared.dismissSession($0) }
        NotchiStateMachine.shared.resetTestingHooks()
        try await super.tearDown()
    }

    func testAssistantMessagesWakeIdleAndSleepingInteractiveSessionsWithActiveWatcher() {
        let stateMachine = NotchiStateMachine.shared
        let result = ParseResult(messages: [makeAssistantMessage()], interrupted: false)

        for initialTask in [NotchiTask.idle, .sleeping] {
            let sessionId = "wake-\(initialTask.rawValue)-\(UUID().uuidString)"
            let session = makeInteractiveSession(sessionId: sessionId)
            session.updateTask(initialTask)
            session.updateProcessingState(isProcessing: false)

            stateMachine.reconcileFileSyncResult(result, for: sessionId, hasActiveWatcher: true)

            XCTAssertEqual(session.task, .working)
            XCTAssertTrue(session.isProcessing)

            SessionStore.shared.dismissSession(sessionId)
        }
    }

    func testAssistantMessagesDoNotWakeIdleSessionAfterStopWithoutWatcher() {
        let stateMachine = NotchiStateMachine.shared
        let sessionId = "stop-\(UUID().uuidString)"
        let session = makeInteractiveSession(sessionId: sessionId)

        _ = SessionStore.shared.process(makeEvent(sessionId: sessionId, event: "Stop", status: "waiting_for_input"))
        XCTAssertEqual(session.task, .idle)
        XCTAssertFalse(session.isProcessing)

        let result = ParseResult(messages: [makeAssistantMessage()], interrupted: false)
        SessionStore.shared.recordAssistantMessages(result.messages, for: sessionId)
        stateMachine.reconcileFileSyncResult(result, for: sessionId, hasActiveWatcher: false)

        XCTAssertEqual(session.task, .idle)
        XCTAssertFalse(session.isProcessing)
    }

    func testSessionStartForwardsToClaudeUsageHandler() {
        let stateMachine = NotchiStateMachine.shared
        var receivedTriggers: [ClaudeUsageResumeTrigger] = []
        stateMachine.handleClaudeUsageResumeTrigger = { trigger in
            receivedTriggers.append(trigger)
        }

        stateMachine.handleEvent(makeEvent(
            sessionId: "session-start-\(UUID().uuidString)",
            event: "SessionStart",
            status: "processing"
        ))

        XCTAssertEqual(receivedTriggers, [.sessionStart])
    }

    func testInteractiveUserPromptSubmitForwardsToClaudeUsageHandler() {
        let stateMachine = NotchiStateMachine.shared
        var receivedTriggers: [ClaudeUsageResumeTrigger] = []
        stateMachine.handleClaudeUsageResumeTrigger = { trigger in
            receivedTriggers.append(trigger)
        }

        stateMachine.handleEvent(makeEvent(
            sessionId: "prompt-submit-\(UUID().uuidString)",
            event: "UserPromptSubmit",
            status: "processing",
            userPrompt: "hello"
        ))

        XCTAssertEqual(receivedTriggers, [.userPromptSubmit])
    }

    func testLocalSlashUserPromptSubmitDoesNotForwardToClaudeUsageHandler() {
        let stateMachine = NotchiStateMachine.shared
        var receivedTriggers: [ClaudeUsageResumeTrigger] = []
        stateMachine.handleClaudeUsageResumeTrigger = { trigger in
            receivedTriggers.append(trigger)
        }

        stateMachine.handleEvent(makeEvent(
            sessionId: "local-prompt-\(UUID().uuidString)",
            event: "UserPromptSubmit",
            status: "processing",
            userPrompt: "/help"
        ))

        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    func testNonInteractiveUserPromptSubmitDoesNotForwardToClaudeUsageHandler() {
        let stateMachine = NotchiStateMachine.shared
        var receivedTriggers: [ClaudeUsageResumeTrigger] = []
        stateMachine.handleClaudeUsageResumeTrigger = { trigger in
            receivedTriggers.append(trigger)
        }

        stateMachine.handleEvent(makeEvent(
            sessionId: "noninteractive-prompt-\(UUID().uuidString)",
            event: "UserPromptSubmit",
            status: "processing",
            userPrompt: "hello",
            interactive: false
        ))

        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    func testHookEventAllowsMissingTranscriptPathForStaleHooks() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "session_id": "stale-hook",
            "cwd": "/tmp",
            "event": "SessionStart",
            "status": "waiting_for_input",
        ])

        let event = try JSONDecoder().decode(HookEvent.self, from: data)

        XCTAssertNil(event.transcriptPath)
        XCTAssertEqual(event.sessionId, "stale-hook")
    }

    private func makeInteractiveSession(sessionId: String) -> SessionData {
        SessionStore.shared.process(makeEvent(
            sessionId: sessionId,
            event: "UserPromptSubmit",
            status: "processing",
            userPrompt: "hello"
        ))
    }

    private func makeAssistantMessage() -> AssistantMessage {
        AssistantMessage(id: UUID().uuidString, text: "Still working", timestamp: Date())
    }

    private func makeEvent(
        sessionId: String,
        event: String,
        status: String,
        userPrompt: String? = nil,
        interactive: Bool = true
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            transcriptPath: nil,
            cwd: "/tmp",
            event: event,
            status: status,
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            userPrompt: userPrompt,
            permissionMode: nil,
            interactive: interactive
        )
    }
}
