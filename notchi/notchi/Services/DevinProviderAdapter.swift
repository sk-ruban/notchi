import Foundation

struct DevinProviderAdapter: AgentProviderAdapter {
    nonisolated let provider: AgentProvider = .devin
    nonisolated init() {}

    nonisolated private static let notchiToolNamesByDevinToolName = [
        "exec": "Bash",
        "read": "Read",
        "write": "Write",
        "edit": "Edit",
        "apply_patch": "Edit",
        "grep": "Grep",
        "glob": "Glob",
        "run_subagent": "Task",
        "webfetch": "WebFetch",
        "todo_write": "TodoWrite",
    ]

    @discardableResult
    nonisolated func installIfNeeded() -> Bool {
        DevinHookInstaller.installIfNeeded()
    }

    nonisolated func uninstall() {
        DevinHookInstaller.uninstall()
    }

    nonisolated func isProviderAvailable() -> Bool {
        DevinHookInstaller.devinDirectoryExists()
    }

    nonisolated func isInstalled() -> Bool {
        DevinHookInstaller.isInstalled()
    }

    nonisolated func configureForLaunch() {}

    nonisolated func normalize(_ envelope: AgentHookEnvelope) -> HookEvent? {
        guard let event = NormalizedAgentEvent.devinEvent(named: envelope.event) else {
            return nil
        }

        let prompt = UserPromptContentParser.parse(
            envelope.userPrompt,
            reportedHasAttachments: envelope.hasAttachments == true
        )

        return HookEvent(
            provider: provider,
            rawSessionId: envelope.sessionId,
            transcriptPath: nil,
            cwd: envelope.cwd,
            event: event,
            status: envelope.status,
            tool: envelope.tool.map { Self.notchiToolNamesByDevinToolName[$0] ?? $0 },
            toolInput: envelope.toolInput,
            toolUseId: envelope.toolUseId,
            userPrompt: prompt.text,
            userPromptHasAttachments: prompt.hasAttachments,
            userPromptImageAttachments: prompt.imageAttachments,
            userPromptHasOtherAttachments: prompt.hasOtherAttachments,
            interactive: envelope.interactive,
            devinProcessId: envelope.devinProcessId,
            lastAssistantMessage: envelope.lastAssistantMessage
        )
    }
}
