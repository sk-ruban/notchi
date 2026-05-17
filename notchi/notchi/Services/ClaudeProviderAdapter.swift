import Foundation

struct ClaudeProviderAdapter: AgentProviderAdapter {
    nonisolated let provider: AgentProvider = .claude
    nonisolated init() {}

    @discardableResult
    nonisolated func installIfNeeded() -> Bool {
        HookInstaller.installIfNeeded()
    }

    nonisolated func isProviderAvailable() -> Bool {
        HookInstaller.claudeConfigDirectoryExists()
    }

    nonisolated func isInstalled() -> Bool {
        HookInstaller.isInstalled()
    }

    nonisolated func configureForLaunch() {
        let claudeConfig = ClaudeConfigDirectoryResolver.resolve()
        ConversationParser.configureClaudeProjectsRootPath(using: claudeConfig)
    }

    nonisolated func normalize(_ envelope: AgentHookEnvelope) -> HookEvent? {
        guard let event = NormalizedAgentEvent.claudeEvent(named: envelope.event) else {
            return nil
        }

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
            userPrompt: envelope.userPrompt,
            permissionMode: envelope.permissionMode,
            interactive: envelope.interactive,
            claudeProcessId: envelope.claudeProcessId
        )
    }
}
