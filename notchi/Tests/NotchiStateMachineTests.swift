import Foundation
import os
import XCTest
@testable import notchi

@MainActor
final class NotchiStateMachineTests: XCTestCase {
    override func tearDown() async throws {
        let sessionKeys = Array(SessionStore.shared.sessions.keys)
        sessionKeys.forEach { SessionStore.shared.dismissSession($0) }
        NotchiStateMachine.shared.resetTestingHooks()
        SessionStore.shared.resetTestingHooks()
        CodexUsageService.shared.clear()
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

            stateMachine.reconcileFileSyncResult(result, for: session.sessionKey, hasActiveWatcher: true)

            XCTAssertEqual(session.task, .working)
            XCTAssertTrue(session.isProcessing)

            SessionStore.shared.dismissSession(session.sessionKey)
        }
    }

    func testAssistantMessagesDoNotWakeIdleSessionAfterStopWithoutWatcher() {
        let stateMachine = NotchiStateMachine.shared
        let sessionId = "stop-\(UUID().uuidString)"
        let session = makeInteractiveSession(sessionId: sessionId)

        _ = SessionStore.shared.process(makeEvent(sessionId: sessionId, event: .stop, status: "waiting_for_input"))
        XCTAssertEqual(session.task, .idle)
        XCTAssertFalse(session.isProcessing)

        let result = ParseResult(messages: [makeAssistantMessage()], interrupted: false)
        SessionStore.shared.recordAssistantMessages(result.messages, for: session.sessionKey)
        stateMachine.reconcileFileSyncResult(result, for: session.sessionKey, hasActiveWatcher: false)

        XCTAssertEqual(session.task, .idle)
        XCTAssertFalse(session.isProcessing)
    }

    func testPendingPermissionRequestSurvivesFileSyncReconcile() async throws {
        let stateMachine = NotchiStateMachine.shared
        let sessionId = "permission-wait-\(UUID().uuidString)"
        let session = makeInteractiveSession(sessionId: sessionId)

        _ = SessionStore.shared.process(makeEvent(
            sessionId: sessionId,
            event: .permissionRequest,
            status: "waiting_for_input"
        ))

        XCTAssertEqual(session.task, .waiting)
        XCTAssertFalse(session.pendingQuestions.isEmpty)

        try await Task.sleep(nanoseconds: 2_200_000_000)

        let result = ParseResult(messages: [], interrupted: false)
        stateMachine.reconcileFileSyncResult(result, for: session.sessionKey, hasActiveWatcher: true)

        XCTAssertEqual(session.task, .waiting)
        XCTAssertFalse(session.pendingQuestions.isEmpty)
    }

    func testSessionStartForwardsToClaudeUsageHandler() {
        let stateMachine = NotchiStateMachine.shared
        var receivedTriggers: [ClaudeUsageResumeTrigger] = []
        stateMachine.handleClaudeUsageResumeTrigger = { trigger in
            receivedTriggers.append(trigger)
        }

        stateMachine.handleEvent(makeEvent(
            sessionId: "session-start-\(UUID().uuidString)",
            event: .sessionStarted,
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
            event: .userPromptSubmitted,
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
            event: .userPromptSubmitted,
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
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello",
            interactive: false
        ))

        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    func testAgentHookEnvelopeAllowsMissingTranscriptPathForStaleHooks() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "session_id": "stale-hook",
            "cwd": "/tmp",
            "event": "SessionStart",
            "status": "waiting_for_input",
        ])

        let event = try JSONDecoder().decode(AgentHookEnvelope.self, from: data)

        XCTAssertNil(event.transcriptPath)
        XCTAssertEqual(event.sessionId, "stale-hook")
        XCTAssertEqual(event.provider, .claude)
    }

    func testCodexPromptSubmitDoesNotForwardToClaudeUsageHandler() {
        let stateMachine = NotchiStateMachine.shared
        var receivedTriggers: [ClaudeUsageResumeTrigger] = []
        stateMachine.handleClaudeUsageResumeTrigger = { trigger in
            receivedTriggers.append(trigger)
        }

        stateMachine.handleEvent(makeEvent(
            sessionId: "codex-prompt-\(UUID().uuidString)",
            provider: .codex,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))

        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    func testCodexSessionStartDoesNotCreateVisibleSession() {
        let stateMachine = NotchiStateMachine.shared
        let sessionId = "codex-start-\(UUID().uuidString)"

        // Intentionally omit transcriptPath so this covers the blank-session
        // case without starting a watcher as a side effect.
        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            event: .sessionStarted,
            status: "processing"
        ))

        let sessionKey = ProviderSessionKey(provider: .codex, rawSessionId: sessionId)
        XCTAssertNil(SessionStore.shared.session(for: sessionKey))
        XCTAssertEqual(SessionStore.shared.activeSessionCount, 0)
    }

    func testCodexVisibleSessionPreservesOriginalSessionStartTime() async throws {
        let stateMachine = NotchiStateMachine.shared
        let sessionId = "codex-visible-start-\(UUID().uuidString)"
        let sessionKey = ProviderSessionKey(provider: .codex, rawSessionId: sessionId)

        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            event: .sessionStarted,
            status: "processing"
        ))

        try await Task.sleep(nanoseconds: 200_000_000)

        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))

        guard let session = SessionStore.shared.session(for: sessionKey),
              let promptSubmitTime = session.promptSubmitTime else {
            return XCTFail("Expected visible Codex session after first real event")
        }

        XCTAssertGreaterThanOrEqual(promptSubmitTime.timeIntervalSince(session.sessionStartTime), 0.15)
    }

    func testClaudeSessionStartDoesNotCreateVisibleSession() {
        let stateMachine = NotchiStateMachine.shared
        let sessionId = "claude-start-\(UUID().uuidString)"

        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            event: .sessionStarted,
            status: "processing"
        ))

        let sessionKey = ProviderSessionKey(provider: .claude, rawSessionId: sessionId)
        XCTAssertNil(SessionStore.shared.session(for: sessionKey))
        XCTAssertEqual(SessionStore.shared.activeSessionCount, 0)
    }

    func testClaudeVisibleSessionPreservesOriginalSessionStartTime() async throws {
        let stateMachine = NotchiStateMachine.shared
        let sessionId = "claude-visible-start-\(UUID().uuidString)"
        let sessionKey = ProviderSessionKey(provider: .claude, rawSessionId: sessionId)

        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            event: .sessionStarted,
            status: "processing"
        ))

        try await Task.sleep(nanoseconds: 200_000_000)

        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))

        guard let session = SessionStore.shared.session(for: sessionKey),
              let promptSubmitTime = session.promptSubmitTime else {
            return XCTFail("Expected visible Claude session after first real event")
        }

        XCTAssertGreaterThanOrEqual(promptSubmitTime.timeIntervalSince(session.sessionStartTime), 0.15)
    }

    func testStaleCodexSessionStartTimesAreTrimmedOnNextEvent() {
        let stateMachine = NotchiStateMachine.shared
        let staleKey = ProviderSessionKey(provider: .codex, rawSessionId: "stale-\(UUID().uuidString)")

        stateMachine.setPendingSessionStartTimeForTesting(
            Date(timeIntervalSinceNow: -11 * 60),
            sessionKey: staleKey
        )

        stateMachine.handleEvent(makeEvent(
            sessionId: "claude-event-\(UUID().uuidString)",
            event: .sessionStarted,
            status: "processing"
        ))

        XCTAssertNil(stateMachine.pendingSessionStartTimeForTesting(sessionKey: staleKey))
    }

    func testApplyingParsedCodexSessionEventsRecordsBashActivity() {
        let stateMachine = NotchiStateMachine.shared
        let session = SessionStore.shared.process(makeEvent(
            sessionId: "codex-events-\(UUID().uuidString)",
            provider: .codex,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))

        stateMachine.applyParsedSessionEvents([
            ParsedSessionEvent(
                id: "tool-start",
                event: .preToolUse,
                status: "running_tool",
                tool: "Bash",
                toolInput: ["command": AnyCodable("pwd")],
                toolUseId: "call-123"
            ),
            ParsedSessionEvent(
                id: "tool-end",
                event: .postToolUse,
                status: "processing",
                tool: "Bash",
                toolInput: nil,
                toolUseId: "call-123"
            ),
        ], for: session.sessionKey)

        XCTAssertEqual(session.recentEvents.count, 1)
        XCTAssertEqual(session.recentEvents.first?.tool, "Bash")
        XCTAssertEqual(session.recentEvents.first?.description, "pwd")
        XCTAssertEqual(session.recentEvents.first?.status, .success)
    }

    func testCodexCLISessionEndsAfterProcessMisses() {
        let stateMachine = NotchiStateMachine.shared
        stateMachine.isCodexProcessAlive = { _ in false }
        let sessionId = "codex-cli-exit-\(UUID().uuidString)"
        let sessionKey = ProviderSessionKey(provider: .codex, rawSessionId: sessionId)

        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello",
            codexProcessId: 12345,
            codexOrigin: .cli
        ))

        XCTAssertNotNil(SessionStore.shared.session(for: sessionKey))

        stateMachine.reconcileCodexProcessLivenessForTesting()
        XCTAssertNotNil(SessionStore.shared.session(for: sessionKey))

        stateMachine.reconcileCodexProcessLivenessForTesting()
        XCTAssertNil(SessionStore.shared.session(for: sessionKey))
    }

    func testCodexDesktopSessionIsNotRemovedByProcessMonitor() {
        let stateMachine = NotchiStateMachine.shared
        stateMachine.isCodexProcessAlive = { _ in false }
        let sessionId = "codex-desktop-\(UUID().uuidString)"
        let sessionKey = ProviderSessionKey(provider: .codex, rawSessionId: sessionId)

        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello",
            codexProcessId: 12345,
            codexOrigin: .desktop
        ))

        stateMachine.reconcileCodexProcessLivenessForTesting()
        stateMachine.reconcileCodexProcessLivenessForTesting()

        XCTAssertNotNil(SessionStore.shared.session(for: sessionKey))
    }

    func testArchivedCodexThreadRemovesSessionOnMetadataReconcile() {
        let stateMachine = NotchiStateMachine.shared
        stateMachine.setCodexThreadMetadataAutoRefreshEnabledForTesting(false)
        let sessionId = "codex-archived-\(UUID().uuidString)"
        let sessionKey = ProviderSessionKey(provider: .codex, rawSessionId: sessionId)
        SessionStore.shared.setCodexMetadataResolverForTesting { _ in
            CodexThreadMetadata(title: "Archived chat", archived: true)
        }

        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            transcriptPath: "/tmp/archived-rollout.jsonl",
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))

        XCTAssertNotNil(SessionStore.shared.session(for: sessionKey))

        stateMachine.reconcileCodexThreadMetadataForTesting()

        XCTAssertNil(SessionStore.shared.session(for: sessionKey))
        XCTAssertEqual(SessionStore.shared.activeSessionCount, 0)
    }

    func testCodexThreadMetadataReconcileRefreshesTitleAndRemovesArchivedSession() {
        let stateMachine = NotchiStateMachine.shared
        stateMachine.setCodexThreadMetadataAutoRefreshEnabledForTesting(false)
        let sessionId = "codex-archive-refresh-\(UUID().uuidString)"
        let sessionKey = ProviderSessionKey(provider: .codex, rawSessionId: sessionId)
        let transcriptPath = "/tmp/archive-refresh-rollout.jsonl"
        SessionStore.shared.setCodexMetadataResolverForTesting { _ in
            CodexThreadMetadata(title: "Initial title", archived: false)
        }

        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            transcriptPath: transcriptPath,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))

        XCTAssertNil(SessionStore.shared.session(for: sessionKey)?.codexTitle)

        stateMachine.reconcileCodexThreadMetadataForTesting()

        XCTAssertEqual(SessionStore.shared.session(for: sessionKey)?.codexTitle, "Initial title")

        SessionStore.shared.setCodexMetadataResolverForTesting { path in
            path == transcriptPath
                ? CodexThreadMetadata(title: "Archived title", archived: true)
                : nil
        }

        stateMachine.reconcileCodexThreadMetadataForTesting()

        XCTAssertNil(SessionStore.shared.session(for: sessionKey))
    }

    func testLastCodexSessionEndTriggersCodexUsageRefresh() {
        let stateMachine = NotchiStateMachine.shared
        stateMachine.setCodexThreadMetadataAutoRefreshEnabledForTesting(false)
        var endedHookCalls = 0
        stateMachine.onCodexSessionsEnded = { endedHookCalls += 1 }
        defer {
            stateMachine.resetTestingHooks()
            CodexUsageService.shared.clear()
        }
        let sessionId = "codex-end-refresh-usage-\(UUID().uuidString)"
        let transcriptPath = "/tmp/codex-end-refresh-usage.jsonl"

        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            transcriptPath: transcriptPath,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))

        CodexUsageService.shared.currentUsage = QuotaPeriod(
            utilization: 15,
            resetDate: Date(timeIntervalSinceNow: 300)
        )

        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            transcriptPath: transcriptPath,
            event: .sessionEnded,
            status: "ended"
        ))

        XCTAssertGreaterThan(endedHookCalls, 0)
        XCTAssertEqual(CodexUsageService.shared.currentUsage?.usagePercentage, 15)
    }

    func testCodexCompactionRefreshDelayUsesDebounceWhenNoRecentRefresh() {
        XCTAssertEqual(
            NotchiStateMachine.codexCompactionRefreshDelay(sinceLastRefresh: nil),
            .milliseconds(150)
        )
        XCTAssertEqual(
            NotchiStateMachine.codexCompactionRefreshDelay(sinceLastRefresh: .seconds(3)),
            .milliseconds(150)
        )
    }

    func testCodexCompactionRefreshDelayEnforcesMinimumIntervalAfterRecentRefresh() {
        XCTAssertEqual(
            NotchiStateMachine.codexCompactionRefreshDelay(sinceLastRefresh: .zero),
            .seconds(2)
        )
        XCTAssertEqual(
            NotchiStateMachine.codexCompactionRefreshDelay(sinceLastRefresh: .milliseconds(500)),
            .milliseconds(1500)
        )
        XCTAssertEqual(
            NotchiStateMachine.codexCompactionRefreshDelay(sinceLastRefresh: .milliseconds(1900)),
            .milliseconds(150)
        )
    }

    func testTranscriptWriteBurstCoalescesIntoSingleCompactionRefresh() async throws {
        let stateMachine = NotchiStateMachine.shared
        stateMachine.setCodexThreadMetadataAutoRefreshEnabledForTesting(false)
        let resolverCalls = OSAllocatedUnfairLock(initialState: 0)
        SessionStore.shared.setCodexCompactionSignalResolverForTesting { _ in
            resolverCalls.withLock { $0 += 1 }
            return [:]
        }
        let sessionId = "codex-write-burst-\(UUID().uuidString)"
        _ = SessionStore.shared.process(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            transcriptPath: "/tmp/write-burst-rollout.jsonl",
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))

        for _ in 0..<8 {
            stateMachine.requestCodexCompactionSignalRefreshForTesting()
            try await Task.sleep(for: .milliseconds(60))
        }

        XCTAssertEqual(resolverCalls.withLock { $0 }, 1)
    }

    func testCompactionRefreshCanRunAgainAfterPreviousCycleCompletes() async throws {
        let stateMachine = NotchiStateMachine.shared
        stateMachine.setCodexThreadMetadataAutoRefreshEnabledForTesting(false)
        let resolverCalls = OSAllocatedUnfairLock(initialState: 0)
        SessionStore.shared.setCodexCompactionSignalResolverForTesting { _ in
            resolverCalls.withLock { $0 += 1 }
            return [:]
        }
        let sessionId = "codex-second-cycle-\(UUID().uuidString)"
        _ = SessionStore.shared.process(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            transcriptPath: "/tmp/second-cycle-rollout.jsonl",
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))

        stateMachine.requestCodexCompactionSignalRefreshForTesting()
        let firstCycleRan = await waitUntil(timeout: 1.0) { resolverCalls.withLock { $0 } == 1 }
        XCTAssertTrue(firstCycleRan)

        stateMachine.requestCodexCompactionSignalRefreshForTesting()
        let secondCycleRan = await waitUntil(timeout: 3.0) { resolverCalls.withLock { $0 } == 2 }

        XCTAssertTrue(secondCycleRan)
        XCTAssertEqual(resolverCalls.withLock { $0 }, 2)
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func makeInteractiveSession(sessionId: String) -> SessionData {
        SessionStore.shared.process(makeEvent(
            sessionId: sessionId,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))
    }

    private func makeAssistantMessage() -> AssistantMessage {
        AssistantMessage(id: UUID().uuidString, text: "Still working", timestamp: Date())
    }

    private func makeEvent(
        sessionId: String,
        provider: AgentProvider = .claude,
        transcriptPath: String? = nil,
        event: NormalizedAgentEvent,
        status: String,
        userPrompt: String? = nil,
        interactive: Bool = true,
        codexProcessId: Int? = nil,
        codexOrigin: CodexOrigin? = nil
    ) -> HookEvent {
        HookEvent(
            provider: provider,
            rawSessionId: sessionId,
            transcriptPath: transcriptPath,
            cwd: "/tmp",
            event: event,
            status: status,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            userPrompt: userPrompt,
            permissionMode: nil,
            interactive: interactive,
            codexProcessId: codexProcessId,
            codexOrigin: codexOrigin
        )
    }
}
