import Foundation

struct ClaudeProviderAdapter: AgentProviderAdapter {
    nonisolated let provider: AgentProvider = .claude
    nonisolated init() {}

    @discardableResult
    nonisolated func installIfNeeded() -> Bool {
        HookInstaller.installIfNeeded()
    }

    nonisolated func uninstall() {
        HookInstaller.uninstall()
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
        let prompt = UserPromptContentParser.parse(
            envelope.userPrompt,
            reportedHasAttachments: envelope.hasAttachments == true
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
            permissionSuggestions: envelope.permissionSuggestions,
            interactive: envelope.interactive,
            claudeProcessId: envelope.claudeProcessId,
            interactionRequestId: HookInteractionRequest.id(for: envelope)
        )
    }
}
