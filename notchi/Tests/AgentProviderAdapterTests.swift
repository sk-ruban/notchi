import Foundation
import XCTest
@testable import notchi

final class AgentProviderAdapterTests: XCTestCase {
    private struct TestProviderAdapter: AgentProviderAdapter {
        nonisolated let provider: AgentProvider
        nonisolated let available: Bool
        nonisolated let installed: Bool
        nonisolated let installSucceeds: Bool
        nonisolated let onUninstall: @Sendable () -> Void

        nonisolated init(
            provider: AgentProvider,
            available: Bool,
            installed: Bool,
            installSucceeds: Bool = true,
            onUninstall: @escaping @Sendable () -> Void = {}
        ) {
            self.provider = provider
            self.available = available
            self.installed = installed
            self.installSucceeds = installSucceeds
            self.onUninstall = onUninstall
        }

        nonisolated func installIfNeeded() -> Bool { installSucceeds }
        nonisolated func uninstall() { onUninstall() }
        nonisolated func isProviderAvailable() -> Bool { available }
        nonisolated func isInstalled() -> Bool { installed }
        nonisolated func configureForLaunch() {}
        nonisolated func normalize(_ envelope: AgentHookEnvelope) -> HookEvent? { nil }
    }

    private nonisolated final class HooksPreferenceRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var enabledByProvider: [AgentProvider: Bool] = [:]

        func set(_ enabled: Bool, for provider: AgentProvider) {
            lock.lock()
            defer { lock.unlock() }
            enabledByProvider[provider] = enabled
        }

        func value(for provider: AgentProvider) -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            return enabledByProvider[provider]
        }
    }

    func testCodexProviderCapabilitiesIncludePermissionPrompts() {
        XCTAssertTrue(AgentProvider.codex.capabilities.supportsPermissionPrompts)
    }

    func testCodexProviderCapabilitiesIncludePromptEmotionAnalysis() {
        XCTAssertTrue(AgentProvider.codex.capabilities.supportsPromptEmotionAnalysis)
    }

    @MainActor
    func testIntegrationCoordinatorDeliversCodexEventsInReceivedOrder() async throws {
        CodexProviderAdapter.resetTranscriptBackedSessionTrackingForTests()
        defer { CodexProviderAdapter.resetTranscriptBackedSessionTrackingForTests() }

        let eventSource = TestAgentHookEventSource()
        let coordinator = IntegrationCoordinator(
            eventSource: eventSource,
            adapters: [CodexProviderAdapter()]
        )
        defer { coordinator.stop() }

        var deliveredPrompts: [String] = []
        let deliveredAllEvents = expectation(description: "Delivered all Codex events")
        deliveredAllEvents.expectedFulfillmentCount = 3

        coordinator.start { event in
            deliveredPrompts.append(event.userPrompt ?? "")
            deliveredAllEvents.fulfill()
        }

        try eventSource.emit(codexEnvelope(prompt: "one"))
        try eventSource.emit(codexEnvelope(prompt: "two"))
        try eventSource.emit(codexEnvelope(prompt: "three"))

        await fulfillment(of: [deliveredAllEvents], timeout: 1)

        XCTAssertEqual(deliveredPrompts, ["one", "two", "three"])
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

    func testClaudeAdapterLeavesCodexStylePreambleIntact() throws {
        let prompt = """
        # Files mentioned by the user:

        ## notes.md: /tmp/notes.md
        """
        let data = try JSONSerialization.data(withJSONObject: [
            "session_id": "claude-session",
            "cwd": "/tmp",
            "event": "UserPromptSubmit",
            "status": "processing",
            "user_prompt": prompt,
        ])
        let envelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: data)

        let event = ClaudeProviderAdapter().normalize(envelope)

        XCTAssertEqual(event?.userPrompt, prompt)
        XCTAssertEqual(event?.userPromptHasAttachments, false)
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

    func testCodexAdapterExtractsT3ImageDescriptor() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "provider": "codex",
            "session_id": "codex-session",
            "cwd": "/tmp",
            "event": "UserPromptSubmit",
            "status": "processing",
            "transcript_path": "/tmp/codex-rollout.jsonl",
            "user_prompt": """
            can you check this?

            [Attached image "screenshot.png" is saved at: /Users/test/.t3/userdata/attachments/screenshot.png]
            """,
        ])
        let envelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: data)

        let event = CodexProviderAdapter().normalize(envelope)

        XCTAssertEqual(event?.userPrompt, "can you check this?")
        XCTAssertEqual(event?.userPromptHasAttachments, true)
        XCTAssertEqual(event?.userPromptImageAttachments, [
            UserPromptImageAttachment(
                displayName: "screenshot.png",
                path: "/Users/test/.t3/userdata/attachments/screenshot.png"
            ),
        ])
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
            eventSource: SocketServer(socketPath: "/tmp/notchi-test-\(UUID().uuidString).sock"),
            adapters: [
                TestProviderAdapter(provider: .claude, available: false, installed: false),
                TestProviderAdapter(provider: .codex, available: true, installed: false),
            ],
            hooksEnabledPreference: { _ in true },
            setHooksEnabledPreference: { _, _ in }
        )

        XCTAssertFalse(coordinator.isProviderAvailable(for: .claude))
        XCTAssertTrue(coordinator.isProviderAvailable(for: .codex))
    }

    func testIntegrationCoordinatorDistinguishesProviderUnavailableFromInstallFailure() {
        let coordinator = IntegrationCoordinator(
            eventSource: SocketServer(socketPath: "/tmp/notchi-test-\(UUID().uuidString).sock"),
            adapters: [
                TestProviderAdapter(
                    provider: .claude,
                    available: false,
                    installed: false
                ),
                TestProviderAdapter(
                    provider: .codex,
                    available: true,
                    installed: false,
                    installSucceeds: false
                ),
            ],
            hooksEnabledPreference: { _ in true },
            setHooksEnabledPreference: { _, _ in }
        )

        XCTAssertEqual(coordinator.installStatus(for: .claude), .providerUnavailable)
        XCTAssertEqual(coordinator.installHooksIfNeededStatus(for: .claude), .providerUnavailable)
        XCTAssertEqual(coordinator.installStatus(for: .codex), .notInstalled)
        XCTAssertEqual(coordinator.installHooksIfNeededStatus(for: .codex), .failed)
    }

    func testIntegrationCoordinatorReportsDisabledStatusWhenHooksPreferenceIsOff() {
        let coordinator = IntegrationCoordinator(
            eventSource: SocketServer(socketPath: "/tmp/notchi-test-\(UUID().uuidString).sock"),
            adapters: [
                TestProviderAdapter(provider: .claude, available: true, installed: true),
            ],
            hooksEnabledPreference: { _ in false },
            setHooksEnabledPreference: { _, _ in }
        )

        XCTAssertEqual(coordinator.installStatus(for: .claude), .disabled)
    }

    func testIntegrationCoordinatorReportsProviderUnavailableOverDisabledPreference() {
        let coordinator = IntegrationCoordinator(
            eventSource: SocketServer(socketPath: "/tmp/notchi-test-\(UUID().uuidString).sock"),
            adapters: [
                TestProviderAdapter(provider: .claude, available: false, installed: false),
            ],
            hooksEnabledPreference: { _ in false },
            setHooksEnabledPreference: { _, _ in }
        )

        XCTAssertEqual(coordinator.installStatus(for: .claude), .providerUnavailable)
    }

    func testIntegrationCoordinatorPersistsEnabledPreferenceOnlyWhenInstallSucceeds() {
        let recorder = HooksPreferenceRecorder()
        let coordinator = IntegrationCoordinator(
            eventSource: SocketServer(socketPath: "/tmp/notchi-test-\(UUID().uuidString).sock"),
            adapters: [
                TestProviderAdapter(provider: .claude, available: true, installed: true),
                TestProviderAdapter(provider: .codex, available: true, installed: false, installSucceeds: false),
            ],
            hooksEnabledPreference: { recorder.value(for: $0) ?? true },
            setHooksEnabledPreference: { recorder.set($0, for: $1) }
        )

        XCTAssertEqual(coordinator.setHooksEnabled(true, for: .claude), .installed)
        XCTAssertEqual(recorder.value(for: .claude), true)

        XCTAssertEqual(coordinator.setHooksEnabled(true, for: .codex), .failed)
        XCTAssertEqual(recorder.value(for: .codex), false)
    }

    func testIntegrationCoordinatorSetHooksDisabledUninstallsAndPersistsPreference() {
        let recorder = HooksPreferenceRecorder()
        let uninstallExpectation = expectation(description: "uninstall called")
        let coordinator = IntegrationCoordinator(
            eventSource: SocketServer(socketPath: "/tmp/notchi-test-\(UUID().uuidString).sock"),
            adapters: [
                TestProviderAdapter(
                    provider: .claude,
                    available: true,
                    installed: true,
                    onUninstall: { uninstallExpectation.fulfill() }
                ),
            ],
            hooksEnabledPreference: { recorder.value(for: $0) ?? true },
            setHooksEnabledPreference: { recorder.set($0, for: $1) }
        )

        XCTAssertEqual(coordinator.setHooksEnabled(false, for: .claude), .disabled)
        XCTAssertEqual(recorder.value(for: .claude), false)
        wait(for: [uninstallExpectation], timeout: 1)
    }

    private func codexEnvelope(prompt: String) throws -> AgentHookEnvelope {
        let data = try JSONSerialization.data(withJSONObject: [
            "provider": "codex",
            "session_id": "ordered-codex-session",
            "cwd": "/tmp",
            "event": "UserPromptSubmit",
            "status": "processing",
            "transcript_path": "/tmp/ordered-codex-rollout.jsonl",
            "user_prompt": prompt,
        ])
        return try JSONDecoder().decode(AgentHookEnvelope.self, from: data)
    }
}

private enum TestAgentHookEventSourceError: Error {
    case missingHandler
}

private final class TestAgentHookEventSource: AgentHookEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: AgentHookEnvelopeHandler?

    nonisolated func start(onEvent: @escaping AgentHookEnvelopeHandler) {
        lock.lock()
        handler = onEvent
        lock.unlock()
    }

    nonisolated func stop() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    nonisolated func emit(_ envelope: AgentHookEnvelope) throws {
        lock.lock()
        let currentHandler = handler
        lock.unlock()

        guard let currentHandler else {
            throw TestAgentHookEventSourceError.missingHandler
        }

        // Keep this helper for non-interactive events; interaction requests block
        // the handler while waiting for a response.
        _ = currentHandler(envelope)
    }
}
