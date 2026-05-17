import XCTest
@testable import notchi

final class AgentProviderAdapterTests: XCTestCase {
    private struct TestProviderAdapter: AgentProviderAdapter {
        nonisolated let provider: AgentProvider
        nonisolated let available: Bool
        nonisolated let installed: Bool

        nonisolated func installIfNeeded() -> Bool { installed }
        nonisolated func isProviderAvailable() -> Bool { available }
        nonisolated func isInstalled() -> Bool { installed }
        nonisolated func configureForLaunch() {}
        nonisolated func normalize(_ envelope: AgentHookEnvelope) -> HookEvent? { nil }
    }

    func testCodexProviderCapabilitiesIncludePermissionPrompts() {
        XCTAssertTrue(AgentProvider.codex.capabilities.supportsPermissionPrompts)
    }

    func testCodexProviderCapabilitiesIncludePromptEmotionAnalysis() {
        XCTAssertTrue(AgentProvider.codex.capabilities.supportsPromptEmotionAnalysis)
    }

    func testClaudeAdapterNormalizesEnvelopeIntoHookEvent() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "session_id": "claude-session",
            "cwd": "/tmp",
            "event": "SessionStart",
            "status": "waiting_for_input",
            "claude_process_id": 12345,
        ])
        let envelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: data)

        let event = ClaudeProviderAdapter().normalize(envelope)

        XCTAssertEqual(event?.provider, .claude)
        XCTAssertEqual(event?.event, .sessionStarted)
        XCTAssertEqual(event?.sessionId, "claude:claude-session")
        XCTAssertEqual(event?.claudeProcessId, 12345)
    }

    func testCodexAdapterNormalizesSupportedEnvelopeIntoHookEvent() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "provider": "codex",
            "session_id": "codex-session",
            "cwd": "/tmp",
            "event": "UserPromptSubmit",
            "status": "processing",
            "transcript_path": "/tmp/codex-rollout.jsonl",
            "user_prompt": "hello",
            "codex_process_id": 12345,
            "codex_origin": "cli",
        ])
        let envelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: data)

        let event = CodexProviderAdapter().normalize(envelope)

        XCTAssertEqual(event?.provider, .codex)
        XCTAssertEqual(event?.event, .userPromptSubmitted)
        XCTAssertEqual(event?.userPrompt, "hello")
        XCTAssertEqual(event?.sessionId, "codex:codex-session")
        XCTAssertEqual(event?.codexProcessId, 12345)
        XCTAssertEqual(event?.codexOrigin, .cli)
    }

    func testCodexAdapterStripsFilesMentionedPreambleFromPrompt() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "provider": "codex",
            "session_id": "codex-session",
            "cwd": "/tmp",
            "event": "UserPromptSubmit",
            "status": "processing",
            "transcript_path": "/tmp/codex-rollout.jsonl",
            "user_prompt": """
            # Files mentioned by the user:

            ## CleanShot.png: /Users/ruban/Library/Application Support/CleanShot/media/CleanShot.png

            ## My request for Codex:
            testing
            """,
        ])
        let envelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: data)

        let event = CodexProviderAdapter().normalize(envelope)

        XCTAssertEqual(event?.userPrompt, "testing")
        XCTAssertEqual(event?.userPromptHasAttachments, true)
    }

    func testCodexAdapterUsesAttachedFilePromptWhenFilesPreambleHasNoRequestText() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "provider": "codex",
            "session_id": "codex-session",
            "cwd": "/tmp",
            "event": "UserPromptSubmit",
            "status": "processing",
            "transcript_path": "/tmp/codex-rollout.jsonl",
            "user_prompt": """
            # Files mentioned by the user:

            ## CleanShot.png: /Users/ruban/Library/Application Support/CleanShot/media/CleanShot.png
            """,
        ])
        let envelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: data)

        let event = CodexProviderAdapter().normalize(envelope)

        XCTAssertNil(event?.userPrompt)
        XCTAssertEqual(event?.userPromptHasAttachments, true)
    }

    func testCodexAdapterPrependsAttachedFileWhenHookMarksAttachments() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "provider": "codex",
            "session_id": "codex-session",
            "cwd": "/tmp",
            "event": "UserPromptSubmit",
            "status": "processing",
            "transcript_path": "/tmp/codex-rollout.jsonl",
            "user_prompt": "testing\n",
            "has_attachments": true,
        ])
        let envelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: data)

        let event = CodexProviderAdapter().normalize(envelope)

        XCTAssertEqual(event?.userPrompt, "testing")
        XCTAssertEqual(event?.userPromptHasAttachments, true)
    }

    func testCodexAdapterUsesAttachedFileWhenHookMarksAttachmentsWithoutPrompt() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "provider": "codex",
            "session_id": "codex-session",
            "cwd": "/tmp",
            "event": "UserPromptSubmit",
            "status": "processing",
            "transcript_path": "/tmp/codex-rollout.jsonl",
            "has_attachments": true,
        ])
        let envelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: data)

        let event = CodexProviderAdapter().normalize(envelope)

        XCTAssertNil(event?.userPrompt)
        XCTAssertEqual(event?.userPromptHasAttachments, true)
    }

    func testCodexAdapterDropsUnsupportedEnvelope() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "provider": "codex",
            "session_id": "codex-session",
            "cwd": "/tmp",
            "event": "PermissionRequest",
            "status": "waiting_for_input",
        ])
        let envelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: data)

        XCTAssertNil(CodexProviderAdapter().normalize(envelope))
    }

    func testCodexAdapterDropsCodexSessionWithoutTranscriptPath() throws {
        let sessionId = "codex-untrackable-\(UUID().uuidString)"
        let adapter = CodexProviderAdapter()
        addTeardownBlock {
            CodexProviderAdapter.resetTranscriptBackedSessionTrackingForTests()
        }

        let promptData = try JSONSerialization.data(withJSONObject: [
            "provider": "codex",
            "session_id": sessionId,
            "cwd": "/tmp",
            "event": "UserPromptSubmit",
            "status": "processing",
            "transcript_path": NSNull(),
            "permission_mode": "bypassPermissions",
            "user_prompt": "internal prompt text should not matter",
        ])
        let promptEnvelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: promptData)
        XCTAssertNil(adapter.normalize(promptEnvelope))

        let stopData = try JSONSerialization.data(withJSONObject: [
            "provider": "codex",
            "session_id": sessionId,
            "cwd": "/tmp",
            "event": "Stop",
            "status": "waiting_for_input",
            "transcript_path": NSNull(),
            "permission_mode": "bypassPermissions",
        ])
        let stopEnvelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: stopData)
        XCTAssertNil(adapter.normalize(stopEnvelope))
    }

    func testCodexAdapterAllowsTranscriptBackedSessionAndLaterStopWithoutTranscriptPath() throws {
        let sessionId = "codex-trackable-\(UUID().uuidString)"
        let adapter = CodexProviderAdapter()
        addTeardownBlock {
            CodexProviderAdapter.resetTranscriptBackedSessionTrackingForTests()
        }

        let promptData = try JSONSerialization.data(withJSONObject: [
            "provider": "codex",
            "session_id": sessionId,
            "cwd": "/tmp",
            "event": "UserPromptSubmit",
            "status": "processing",
            "transcript_path": "/tmp/codex-rollout.jsonl",
            "user_prompt": "hello",
        ])
        let promptEnvelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: promptData)
        XCTAssertEqual(adapter.normalize(promptEnvelope)?.event, .userPromptSubmitted)

        let stopData = try JSONSerialization.data(withJSONObject: [
            "provider": "codex",
            "session_id": sessionId,
            "cwd": "/tmp",
            "event": "Stop",
            "status": "waiting_for_input",
            "transcript_path": NSNull(),
        ])
        let stopEnvelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: stopData)
        XCTAssertEqual(adapter.normalize(stopEnvelope)?.event, .stop)
    }

    func testCodexAdapterClearsTrackingOnStopWithTranscriptPath() throws {
        let sessionId = "codex-trackable-\(UUID().uuidString)"
        let adapter = CodexProviderAdapter()
        addTeardownBlock {
            CodexProviderAdapter.resetTranscriptBackedSessionTrackingForTests()
        }

        let promptData = try JSONSerialization.data(withJSONObject: [
            "provider": "codex",
            "session_id": sessionId,
            "cwd": "/tmp",
            "event": "UserPromptSubmit",
            "status": "processing",
            "transcript_path": "/tmp/codex-rollout.jsonl",
            "user_prompt": "hello",
        ])
        let promptEnvelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: promptData)
        XCTAssertEqual(adapter.normalize(promptEnvelope)?.event, .userPromptSubmitted)

        let stopData = try JSONSerialization.data(withJSONObject: [
            "provider": "codex",
            "session_id": sessionId,
            "cwd": "/tmp",
            "event": "Stop",
            "status": "waiting_for_input",
            "transcript_path": "/tmp/codex-rollout.jsonl",
        ])
        let stopEnvelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: stopData)
        XCTAssertEqual(adapter.normalize(stopEnvelope)?.event, .stop)

        let strayData = try JSONSerialization.data(withJSONObject: [
            "provider": "codex",
            "session_id": sessionId,
            "cwd": "/tmp",
            "event": "UserPromptSubmit",
            "status": "processing",
            "transcript_path": NSNull(),
            "user_prompt": "stray",
        ])
        let strayEnvelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: strayData)
        XCTAssertNil(adapter.normalize(strayEnvelope))
    }

    func testClaudeAdapterDropsUnknownEnvelope() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "session_id": "claude-session",
            "cwd": "/tmp",
            "event": "NotARealClaudeEvent",
            "status": "waiting_for_input",
        ])
        let envelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: data)

        XCTAssertNil(ClaudeProviderAdapter().normalize(envelope))
    }

    func testIntegrationCoordinatorReportsProviderAvailabilityFromAdapters() {
        let coordinator = IntegrationCoordinator(
            socketServer: SocketServer(socketPath: "/tmp/notchi-test-\(UUID().uuidString).sock"),
            adapters: [
                TestProviderAdapter(provider: .claude, available: false, installed: false),
                TestProviderAdapter(provider: .codex, available: true, installed: false),
            ]
        )

        XCTAssertFalse(coordinator.isProviderAvailable(for: .claude))
        XCTAssertTrue(coordinator.isProviderAvailable(for: .codex))
    }
}
