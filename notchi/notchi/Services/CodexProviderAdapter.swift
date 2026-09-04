import Foundation

struct CodexProviderAdapter: AgentProviderAdapter {
    nonisolated let provider: AgentProvider = .codex
    nonisolated init() {}

    // WHY: Adapter normalization can happen from multiple queues, and the
    // struct itself has no identity we can synchronize on. Track transcript-backed
    // Codex sessions behind a static lock instead.
    private static let transcriptBackedSessionLock = NSLock()
    private nonisolated(unsafe) static var transcriptBackedSessionIDs: Set<String> = []

    @discardableResult
    nonisolated func installIfNeeded() -> Bool {
        CodexHookInstaller.installIfNeeded()
    }

    nonisolated func uninstall() {
        CodexHookInstaller.uninstall()
    }

    nonisolated func isProviderAvailable() -> Bool {
        CodexHookInstaller.codexDirectoryExists()
    }

    nonisolated func isInstalled() -> Bool {
        CodexHookInstaller.isInstalled()
    }

    nonisolated func configureForLaunch() {}

    nonisolated func normalize(_ envelope: AgentHookEnvelope) -> HookEvent? {
        guard let event = NormalizedAgentEvent.codexEvent(named: envelope.event) else {
            return nil
        }

        if Self.shouldIgnoreUntrackableSessionEvent(envelope, event: event) {
            return nil
        }

        let prompt = UserPromptContentParser.parse(
            envelope.userPrompt,
            reportedHasAttachments: envelope.hasAttachments == true,
            supportsFilesPreamble: true
        )

        return HookEvent(
            provider: provider,
            rawSessionId: envelope.sessionId,
            transcriptPath: envelope.transcriptPath,
            cwd: envelope.cwd,
            event: event,
            status: envelope.status,
            tool: envelope.tool,
            toolInput: envelope.toolInput,
            toolUseId: envelope.toolUseId,
            userPrompt: prompt.text,
            userPromptHasAttachments: prompt.hasAttachments,
            userPromptImageAttachments: prompt.imageAttachments,
            userPromptHasOtherAttachments: prompt.hasOtherAttachments,
            permissionMode: envelope.permissionMode,
            interactive: envelope.interactive ?? true,
            codexProcessId: envelope.codexProcessId,
            codexOrigin: envelope.codexOrigin
        )
    }

    private nonisolated static func shouldIgnoreUntrackableSessionEvent(
        _ envelope: AgentHookEnvelope,
        event: NormalizedAgentEvent
    ) -> Bool {
        transcriptBackedSessionLock.lock()
        defer { transcriptBackedSessionLock.unlock() }

        if hasTranscriptPath(envelope) {
            if event == .stop || event == .sessionEnded {
                transcriptBackedSessionIDs.remove(envelope.sessionId)
            } else {
                transcriptBackedSessionIDs.insert(envelope.sessionId)
            }
            return false
        }

        if transcriptBackedSessionIDs.contains(envelope.sessionId) {
            if event == .stop || event == .sessionEnded {
                transcriptBackedSessionIDs.remove(envelope.sessionId)
            }
            return false
        }

        return true
    }

    private nonisolated static func hasTranscriptPath(_ envelope: AgentHookEnvelope) -> Bool {
        !(envelope.transcriptPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    nonisolated static func resetTranscriptBackedSessionTrackingForTests() {
        transcriptBackedSessionLock.lock()
        defer { transcriptBackedSessionLock.unlock() }
        transcriptBackedSessionIDs.removeAll()
    }
}
