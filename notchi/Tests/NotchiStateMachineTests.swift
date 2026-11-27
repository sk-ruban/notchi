import Foundation
import os
import XCTest
@testable import notchi

@MainActor
final class NotchiStateMachineTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        // Keep session tests away from the real Claude config folders.
        SessionStore.shared.setClaudeAccountObserverForTesting { _, _ in }
    }

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

    func testDevinStopRecordsHookProvidedReply() {
        let sessionId = "devin-reply-\(UUID().uuidString)"
        let reply = "The directory contains:\n- `hooks.log`"

        NotchiStateMachine.shared.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .devin,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "run ls"
        ))
        NotchiStateMachine.shared.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .devin,
            event: .stop,
            status: "waiting_for_input",
            lastAssistantMessage: reply
        ))

        let session = SessionStore.shared.session(for: ProviderSessionKey(provider: .devin, rawSessionId: sessionId))
        XCTAssertEqual(session?.recentAssistantMessages.map(\.text), [reply])
    }

    func testDevinStopWithBlankReplyRecordsNoAssistantMessage() {
        let sessionId = "devin-blank-reply-\(UUID().uuidString)"

        NotchiStateMachine.shared.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .devin,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "run ls"
        ))
        NotchiStateMachine.shared.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .devin,
            event: .stop,
            status: "waiting_for_input",
            lastAssistantMessage: "  \n "
        ))

        let session = SessionStore.shared.session(for: ProviderSessionKey(provider: .devin, rawSessionId: sessionId))
        XCTAssertEqual(session?.recentAssistantMessages.count, 0)
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
        stateMachine.isProcessAlive = { _ in false }
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

        stateMachine.reconcileProcessLivenessForTesting()
        XCTAssertNotNil(SessionStore.shared.session(for: sessionKey))

        stateMachine.reconcileProcessLivenessForTesting()
        XCTAssertNil(SessionStore.shared.session(for: sessionKey))
    }

    func testClaudeSessionEndsAfterProcessMisses() {
        let stateMachine = NotchiStateMachine.shared
        stateMachine.isProcessAlive = { _ in false }
        let sessionId = "claude-exit-\(UUID().uuidString)"
        let sessionKey = ProviderSessionKey(provider: .claude, rawSessionId: sessionId)

        stateMachine.handleEvent(HookEvent(
            rawSessionId: sessionId,
            transcriptPath: nil,
            cwd: "/tmp",
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello",
            interactive: true,
            claudeProcessId: 12345
        ))

        stateMachine.reconcileProcessLivenessForTesting()
        XCTAssertNotNil(SessionStore.shared.session(for: sessionKey))

        stateMachine.reconcileProcessLivenessForTesting()
        XCTAssertNil(SessionStore.shared.session(for: sessionKey))
    }

    func testDevinSessionEndsAfterProcessMisses() {
        let stateMachine = NotchiStateMachine.shared
        stateMachine.isProcessAlive = { _ in false }
        let sessionId = "devin-exit-\(UUID().uuidString)"
        let sessionKey = ProviderSessionKey(provider: .devin, rawSessionId: sessionId)

        stateMachine.handleEvent(HookEvent(
            provider: .devin,
            rawSessionId: sessionId,
            transcriptPath: nil,
            cwd: "/tmp",
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello",
            interactive: true,
            devinProcessId: 12345
        ))

        stateMachine.reconcileProcessLivenessForTesting()
        XCTAssertNotNil(SessionStore.shared.session(for: sessionKey))

        stateMachine.reconcileProcessLivenessForTesting()
        XCTAssertNil(SessionStore.shared.session(for: sessionKey))
    }

    func testClaudeSessionWithoutProcessIdIsNotRemovedByProcessMonitor() {
        let stateMachine = NotchiStateMachine.shared
        stateMachine.isProcessAlive = { _ in false }
        let sessionId = "claude-no-pid-\(UUID().uuidString)"
        let sessionKey = ProviderSessionKey(provider: .claude, rawSessionId: sessionId)

        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))
        stateMachine.reconcileProcessLivenessForTesting()
        stateMachine.reconcileProcessLivenessForTesting()

        XCTAssertNotNil(SessionStore.shared.session(for: sessionKey))
    }

    func testCodexDesktopSessionIsNotRemovedByProcessMonitor() {
        let stateMachine = NotchiStateMachine.shared
        stateMachine.isProcessAlive = { _ in false }
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

        stateMachine.reconcileProcessLivenessForTesting()
        stateMachine.reconcileProcessLivenessForTesting()

        XCTAssertNotNil(SessionStore.shared.session(for: sessionKey))
    }

    func testCodexDesktopSessionHostedByKnownAppEndsAfterProcessMisses() {
        let stateMachine = NotchiStateMachine.shared
        stateMachine.isProcessAlive = { _ in false }
        SessionStore.shared.setHostBundleIdentifierResolverForTesting { _ in "com.t3tools.t3code" }
        defer { SessionStore.shared.resetHostBundleIdentifierResolverForTesting() }
        let sessionId = "codex-hosted-exit-\(UUID().uuidString)"
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

        XCTAssertEqual(SessionStore.shared.session(for: sessionKey)?.hostBundleIdentifier, "com.t3tools.t3code")

        stateMachine.reconcileProcessLivenessForTesting()
        XCTAssertNotNil(SessionStore.shared.session(for: sessionKey))

        stateMachine.reconcileProcessLivenessForTesting()
        XCTAssertNil(SessionStore.shared.session(for: sessionKey))
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

    func testDeletedCodexThreadRemovesSessionOnMetadataReconcile() {
        let stateMachine = NotchiStateMachine.shared
        stateMachine.setCodexThreadMetadataAutoRefreshEnabledForTesting(false)
        let sessionId = "codex-deleted-\(UUID().uuidString)"
        let sessionKey = ProviderSessionKey(provider: .codex, rawSessionId: sessionId)
        SessionStore.shared.setCodexTranscriptExistsForTesting { _ in true }
        SessionStore.shared.setCodexMetadataResolverForTesting { _ in
            CodexThreadMetadata(title: "Deleted chat", archived: false)
        }

        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            transcriptPath: "/tmp/deleted-rollout.jsonl",
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))
        stateMachine.reconcileCodexThreadMetadataForTesting()
        XCTAssertNotNil(SessionStore.shared.session(for: sessionKey))

        SessionStore.shared.setCodexMetadataResolverForTesting { _ in nil }
        SessionStore.shared.setCodexTranscriptExistsForTesting { _ in false }
        stateMachine.reconcileCodexThreadMetadataForTesting()

        XCTAssertNil(SessionStore.shared.session(for: sessionKey))
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

        XCTAssertEqual(endedHookCalls, 1)
        XCTAssertEqual(CodexUsageService.shared.currentUsage?.usagePercentage, 15)
    }

    func testDismissingASessionStopsItsTranscriptWatcher() throws {
        let stateMachine = NotchiStateMachine.shared
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dismiss-\(UUID().uuidString).jsonl")
        try Data().write(to: transcriptURL)
        defer { try? FileManager.default.removeItem(at: transcriptURL) }
        let event = makeEvent(
            sessionId: "dismiss-\(UUID().uuidString)",
            transcriptPath: transcriptURL.path,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        )
        stateMachine.handleEvent(event)
        let session = try XCTUnwrap(SessionStore.shared.session(for: event.sessionKey))
        XCTAssertTrue(stateMachine.hasFileWatcherForTesting(sessionKey: event.sessionKey), "precondition: prompt starts a watcher")

        stateMachine.dismissSession(matchingStableId: session.id)

        XCTAssertFalse(stateMachine.hasFileWatcherForTesting(sessionKey: event.sessionKey))
    }

    func testSessionRevivedAfterDismissalWatchesItsTranscriptAgain() throws {
        let stateMachine = NotchiStateMachine.shared
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dismiss-rewatch-\(UUID().uuidString).jsonl")
        try Data().write(to: transcriptURL)
        defer { try? FileManager.default.removeItem(at: transcriptURL) }
        let prompt = makeEvent(
            sessionId: "dismiss-rewatch-\(UUID().uuidString)",
            transcriptPath: transcriptURL.path,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        )
        stateMachine.handleEvent(prompt)
        let session = try XCTUnwrap(SessionStore.shared.session(for: prompt.sessionKey))
        stateMachine.dismissSession(matchingStableId: session.id)
        XCTAssertFalse(stateMachine.hasFileWatcherForTesting(sessionKey: prompt.sessionKey), "precondition: dismissal stops the watcher")

        stateMachine.handleEvent(makeEvent(
            sessionId: prompt.sessionKey.rawSessionId,
            transcriptPath: transcriptURL.path,
            event: .postToolUse,
            status: "processing"
        ))

        XCTAssertTrue(stateMachine.hasFileWatcherForTesting(sessionKey: prompt.sessionKey))
    }

    func testSessionRevivedAfterDismissalShowsOnlyRepliesWrittenSince() async throws {
        let stateMachine = NotchiStateMachine.shared
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dismiss-revive-\(UUID().uuidString).jsonl")
        func replyLine(_ uuid: String, _ text: String) -> String {
            #"{"type":"assistant","uuid":"\#(uuid)","timestamp":"2026-04-07T09:50:04.954Z","message":{"model":"claude-opus-4-6","role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"# + "\n"
        }
        try Data(replyLine("old", "Old reply").utf8).write(to: transcriptURL)
        defer { try? FileManager.default.removeItem(at: transcriptURL) }
        let prompt = makeEvent(
            sessionId: "dismiss-revive-\(UUID().uuidString)",
            transcriptPath: transcriptURL.path,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        )
        stateMachine.handleEvent(prompt)
        await ConversationParser.shared.markCurrentPosition(sessionKey: prompt.sessionKey, transcriptPath: transcriptURL.path)
        let session = try XCTUnwrap(SessionStore.shared.session(for: prompt.sessionKey))

        // The agent keeps working after the user dismisses its card, so its next event revives the session.
        stateMachine.dismissSession(matchingStableId: session.id)
        try await Task.sleep(for: .milliseconds(100))
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: transcriptURL.path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(replyLine("new", "New reply").utf8))
        try handle.close()
        stateMachine.handleEvent(makeEvent(
            sessionId: prompt.sessionKey.rawSessionId,
            transcriptPath: transcriptURL.path,
            event: .postToolUse,
            status: "processing"
        ))
        let revived = try XCTUnwrap(SessionStore.shared.session(for: prompt.sessionKey))
        _ = await waitUntil(timeout: 2) { !revived.recentAssistantMessages.isEmpty }

        XCTAssertEqual(revived.recentAssistantMessages.map(\.text), ["New reply"])
    }

    func testClaudeEventsWithoutCodexSessionsNeverTriggerCodexUsageRefresh() {
        let stateMachine = NotchiStateMachine.shared
        var endedHookCalls = 0
        stateMachine.onCodexSessionsEnded = { endedHookCalls += 1 }
        let sessionId = "claude-only-\(UUID().uuidString)"

        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))
        stateMachine.handleEvent(makeEvent(sessionId: sessionId, event: .stop, status: "waiting_for_input"))

        XCTAssertEqual(endedHookCalls, 0)
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

    func testCodexThreadMetadataMonitorPollsAtIdleIntervalAfterCodexStop() {
        let stateMachine = NotchiStateMachine.shared
        stateMachine.setCodexThreadMetadataAutoRefreshEnabledForTesting(false)
        let expectedIdleInterval: Duration = .seconds(45)
        let sessionId = "codex-idle-monitor-\(UUID().uuidString)"
        let transcriptPath = "/tmp/codex-idle-monitor.jsonl"

        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            transcriptPath: transcriptPath,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))
        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            transcriptPath: transcriptPath,
            event: .stop,
            status: "waiting_for_input"
        ))

        XCTAssertEqual(stateMachine.codexThreadMetadataMonitorIntervalForTesting, expectedIdleInterval)
    }

    func testCodexThreadMetadataMonitorReturnsToActiveIntervalOnNextCodexPrompt() {
        let stateMachine = NotchiStateMachine.shared
        stateMachine.setCodexThreadMetadataAutoRefreshEnabledForTesting(false)
        let expectedActiveInterval: Duration = .seconds(5)
        let sessionId = "codex-active-monitor-\(UUID().uuidString)"
        let transcriptPath = "/tmp/codex-active-monitor.jsonl"
        let prompt = makeEvent(
            sessionId: sessionId,
            provider: .codex,
            transcriptPath: transcriptPath,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        )

        stateMachine.handleEvent(prompt)
        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            transcriptPath: transcriptPath,
            event: .stop,
            status: "waiting_for_input"
        ))
        stateMachine.handleEvent(prompt)

        XCTAssertEqual(stateMachine.codexThreadMetadataMonitorIntervalForTesting, expectedActiveInterval)
    }

    func testCodexStopRefreshesThreadTitleBeforeTheNextIdlePoll() async {
        let stateMachine = NotchiStateMachine.shared
        let expectedTitle = "Renamed after the reply"
        let sessionId = "codex-stop-title-\(UUID().uuidString)"
        let sessionKey = ProviderSessionKey(provider: .codex, rawSessionId: sessionId)
        let transcriptPath = "/tmp/codex-stop-title.jsonl"
        SessionStore.shared.setCodexMetadataResolverForTesting { _ in
            CodexThreadMetadata(title: "First title", archived: false)
        }

        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            transcriptPath: transcriptPath,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))
        let resolvedFirstTitle = await waitUntil(timeout: 2) {
            SessionStore.shared.session(for: sessionKey)?.codexTitle == "First title"
        }
        XCTAssertTrue(resolvedFirstTitle, "precondition: the first event resolves the thread")

        SessionStore.shared.setCodexMetadataResolverForTesting { _ in
            CodexThreadMetadata(title: expectedTitle, archived: false)
        }
        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            transcriptPath: transcriptPath,
            event: .stop,
            status: "waiting_for_input"
        ))
        _ = await waitUntil(timeout: 2) {
            SessionStore.shared.session(for: sessionKey)?.codexTitle == expectedTitle
        }

        XCTAssertEqual(SessionStore.shared.session(for: sessionKey)?.codexTitle, expectedTitle)
    }

    func testEmotionDecayTimerStopsOnceEveryScoreHasDecayed() async throws {
        let stateMachine = NotchiStateMachine.shared
        stateMachine.setEmotionDecayIntervalForTesting(.milliseconds(5))
        stateMachine.analyzeEmotion = { _ in (emotion: "happy", intensity: 1.0) }
        let session = makeInteractiveSession(sessionId: "decay-idle-\(UUID().uuidString)")
        stateMachine.handleEvent(makeEvent(
            sessionId: session.rawSessionId,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "thanks, great job"
        ))
        let recorded = await waitUntil(timeout: 2) { session.emotionState.scores[.happy, default: 0] > 0 }
        XCTAssertTrue(recorded, "precondition: the prompt records a score")

        _ = await waitUntil(timeout: 5) { !stateMachine.isEmotionDecayTimerRunningForTesting }

        XCTAssertFalse(stateMachine.isEmotionDecayTimerRunningForTesting)
    }

    func testRecordedEmotionStartsTheIdleDecayTimer() async throws {
        let stateMachine = NotchiStateMachine.shared
        stateMachine.analyzeEmotion = { _ in (emotion: "sad", intensity: 1.0) }
        XCTAssertFalse(stateMachine.isEmotionDecayTimerRunningForTesting, "precondition: nothing to decay")
        let session = makeInteractiveSession(sessionId: "decay-restart-\(UUID().uuidString)")

        stateMachine.handleEvent(makeEvent(
            sessionId: session.rawSessionId,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "this is still broken"
        ))
        _ = await waitUntil(timeout: 2) { session.emotionState.scores[.sad, default: 0] > 0 }

        XCTAssertTrue(stateMachine.isEmotionDecayTimerRunningForTesting)
    }

    func testLocalSlashCommandPromptIsNotAnalyzed() async {
        let expectedAnalyzedPrompts = ["hello"]
        let stateMachine = NotchiStateMachine.shared
        var analyzedPrompts: [String] = []
        stateMachine.analyzeEmotion = { prompt in
            analyzedPrompts.append(prompt)
            return nil
        }
        let session = makeInteractiveSession(sessionId: "emotion-slash-\(UUID().uuidString)")

        stateMachine.handleEvent(makeEvent(sessionId: session.rawSessionId, event: .userPromptSubmitted, status: "processing", userPrompt: "/clear"))
        stateMachine.handleEvent(makeEvent(sessionId: session.rawSessionId, event: .userPromptSubmitted, status: "processing", userPrompt: "hello"))
        _ = await waitUntil(timeout: 2) { analyzedPrompts.contains("hello") }

        XCTAssertEqual(analyzedPrompts, expectedAnalyzedPrompts)
    }

    func testBlankPromptIsNotAnalyzed() async {
        let expectedAnalyzedPrompts = ["hello"]
        let stateMachine = NotchiStateMachine.shared
        var analyzedPrompts: [String] = []
        stateMachine.analyzeEmotion = { prompt in
            analyzedPrompts.append(prompt)
            return nil
        }
        let session = makeInteractiveSession(sessionId: "emotion-blank-\(UUID().uuidString)")

        stateMachine.handleEvent(makeEvent(sessionId: session.rawSessionId, event: .userPromptSubmitted, status: "processing", userPrompt: " \n "))
        stateMachine.handleEvent(makeEvent(sessionId: session.rawSessionId, event: .userPromptSubmitted, status: "processing", userPrompt: "hello"))
        _ = await waitUntil(timeout: 2) { analyzedPrompts.contains("hello") }

        XCTAssertEqual(analyzedPrompts, expectedAnalyzedPrompts)
    }

    func testLateAnalysisOfAnEarlierPromptDoesNotRecordItsEmotion() async throws {
        let expectedHappyScore = 0.0
        let stateMachine = NotchiStateMachine.shared
        var releaseFirstAnalysis: CheckedContinuation<Void, Never>?
        stateMachine.analyzeEmotion = { prompt in
            guard prompt == "first" else { return (emotion: "sad", intensity: 1.0) }
            await withCheckedContinuation { releaseFirstAnalysis = $0 }
            return (emotion: "happy", intensity: 1.0)
        }
        let session = makeInteractiveSession(sessionId: "emotion-cancel-\(UUID().uuidString)")

        stateMachine.handleEvent(makeEvent(sessionId: session.rawSessionId, event: .userPromptSubmitted, status: "processing", userPrompt: "first"))
        let firstStarted = await waitUntil(timeout: 2) { releaseFirstAnalysis != nil }
        XCTAssertTrue(firstStarted, "precondition: the first analysis is in flight")
        stateMachine.handleEvent(makeEvent(sessionId: session.rawSessionId, event: .userPromptSubmitted, status: "processing", userPrompt: "second"))
        let secondRecorded = await waitUntil(timeout: 2) { session.emotionState.scores[.sad, default: 0] > 0 }
        XCTAssertTrue(secondRecorded, "precondition: the second prompt's emotion is recorded")
        releaseFirstAnalysis?.resume()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(session.emotionState.scores[.happy], expectedHappyScore)
    }

    func testSkippedPromptStillDropsTheEarlierPromptsLateEmotion() async throws {
        let expectedHappyScore = 0.0
        let stateMachine = NotchiStateMachine.shared
        var releaseFirstAnalysis: CheckedContinuation<Void, Never>?
        stateMachine.analyzeEmotion = { _ in
            await withCheckedContinuation { releaseFirstAnalysis = $0 }
            return (emotion: "happy", intensity: 1.0)
        }
        let session = makeInteractiveSession(sessionId: "emotion-skip-cancel-\(UUID().uuidString)")

        stateMachine.handleEvent(makeEvent(sessionId: session.rawSessionId, event: .userPromptSubmitted, status: "processing", userPrompt: "first"))
        let firstStarted = await waitUntil(timeout: 2) { releaseFirstAnalysis != nil }
        XCTAssertTrue(firstStarted, "precondition: the first analysis is in flight")
        // A newer prompt that isn't analyzed itself still starts a new turn.
        stateMachine.handleEvent(makeEvent(sessionId: session.rawSessionId, event: .userPromptSubmitted, status: "processing", userPrompt: "/clear"))
        releaseFirstAnalysis?.resume()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(session.emotionState.scores[.happy, default: 0], expectedHappyScore)
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
        codexOrigin: CodexOrigin? = nil,
        lastAssistantMessage: String? = nil
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
            codexOrigin: codexOrigin,
            lastAssistantMessage: lastAssistantMessage
        )
    }
}
