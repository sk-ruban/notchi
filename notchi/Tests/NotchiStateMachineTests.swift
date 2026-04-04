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

    func testConversationParserReadsAssistantMessagesFromTranscriptPath() async {
        let sessionId = "transcript-\(UUID().uuidString)"
        let transcriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jsonl")
            .path

        let assistantLine = """
        {"parentUuid":"parent","isSidechain":false,"userType":"external","cwd":"/tmp","sessionId":"\(sessionId)","version":"1","gitBranch":"","type":"assistant","message":{"id":"msg-1","type":"message","role":"assistant","model":"claude-sonnet","content":[{"type":"text","text":"Hello from a custom transcript path"}],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":1}},"uuid":"assistant-1","timestamp":"2026-04-04T09:00:00.000Z"}
        """

        FileManager.default.createFile(atPath: transcriptPath, contents: Data(assistantLine.utf8))
        defer {
            try? FileManager.default.removeItem(atPath: transcriptPath)
        }

        let result = await ConversationParser.shared.parseIncremental(
            sessionId: sessionId,
            transcriptPath: transcriptPath
        )
        await ConversationParser.shared.resetState(for: sessionId)

        XCTAssertEqual(result.messages.map(\.text), ["Hello from a custom transcript path"])
        XCTAssertFalse(result.interrupted)
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
            transcriptPath: "/tmp/\(sessionId).jsonl",
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
