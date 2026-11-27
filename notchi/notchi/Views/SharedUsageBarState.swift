import Foundation

nonisolated struct SharedUsageBarState {
    let provider: AgentProvider
    let usage: QuotaPeriod?
    let isUsingExtraUsage: Bool
    let isFastMode: Bool
    let isLoading: Bool
    let error: String?
    let statusMessage: String?
    let isStale: Bool
    let recoveryAction: ClaudeUsageRecoveryAction
    let labelOverride: String?
    /// Which Claude account the usage is for, when there's more than one.
    let accountName: String?
    let isProviderSpecific: Bool
    let period: MainUsageBarPeriod

    init(
        provider: AgentProvider,
        usage: QuotaPeriod?,
        isUsingExtraUsage: Bool,
        isFastMode: Bool = false,
        isLoading: Bool,
        error: String?,
        statusMessage: String?,
        isStale: Bool,
        recoveryAction: ClaudeUsageRecoveryAction,
        labelOverride: String? = nil,
        accountName: String? = nil,
        isProviderSpecific: Bool = true,
        period: MainUsageBarPeriod = .session
    ) {
        self.provider = provider
        self.usage = usage
        self.isUsingExtraUsage = isUsingExtraUsage
        self.isFastMode = isFastMode
        self.isLoading = isLoading
        self.error = error
        self.statusMessage = statusMessage
        self.isStale = isStale
        self.recoveryAction = recoveryAction
        self.labelOverride = labelOverride
        self.accountName = accountName
        self.isProviderSpecific = isProviderSpecific
        self.period = period
    }

    var label: String {
        if let labelOverride {
            return labelOverride
        }
        return String(localized: "\(provider.displayName) Usage")
    }

    static let noActiveSession = SharedUsageBarState(
        // Provider is a placeholder; isProviderSpecific=false suppresses provider-keyed UI.
        provider: .claude,
        usage: nil,
        isUsingExtraUsage: false,
        isLoading: false,
        error: nil,
        statusMessage: nil,
        isStale: false,
        recoveryAction: .none,
        labelOverride: String(localized: "Start a session to track usage"),
        isProviderSpecific: false
    )
}

extension ExpandedPanelView {
    static func shouldShowSharedUsageBar(contextSession: SessionData?, activeSessions: [SessionData]) -> Bool {
        !activeSessions.isEmpty || contextSession == nil
    }

    static func includesClaudeUsage(activeSessions: [SessionData]) -> Bool {
        activeSessions.contains { $0.provider == .claude }
    }

    static func claudeIsFastMode(activeSessions: [SessionData]) -> Bool {
        activeSessions.contains { $0.provider == .claude && $0.isFastMode }
    }

    static func includesCodexUsage(activeSessions: [SessionData]) -> Bool {
        activeSessions.contains { $0.provider == .codex }
    }

    static func includesDevinUsage(activeSessions: [SessionData]) -> Bool {
        activeSessions.contains { $0.provider == .devin }
    }

    static func hasMixedProviderSessions(_ activeSessions: [SessionData]) -> Bool {
        Set(activeSessions.map(\.provider)).count > 1
    }

    static func sharedUsageResetLabelPrefix(
        state: SharedUsageBarState?,
        activeSessions: [SessionData],
        requestedPeriod: MainUsageBarPeriod
    ) -> String? {
        guard let state else { return nil }

        var parts: [String] = []
        if hasMixedProviderSessions(activeSessions) {
            parts.append(state.provider.displayName)
        }
        if let accountName = state.accountName {
            parts.append(accountName)
        }
        if state.period == .weekly || state.period != requestedPeriod {
            let periodName = state.period.displayName(for: state.provider)
            parts.append(parts.isEmpty ? periodName : periodName.lowercased(with: .autoupdatingCurrent))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // The selected period falls back to the provider's other quota when its own is missing, so the
    // bar shows live data instead of staying empty. The label follows via SharedUsageBarState.period.
    static func effectiveMainUsagePeriod(
        for period: MainUsageBarPeriod,
        sessionUsage: QuotaPeriod?,
        weeklyUsage: QuotaPeriod?
    ) -> MainUsageBarPeriod {
        switch period {
        case .session: sessionUsage == nil && weeklyUsage != nil ? .weekly : .session
        case .weekly: weeklyUsage == nil && sessionUsage != nil ? .session : .weekly
        }
    }

    static func mainUsage(
        for period: MainUsageBarPeriod,
        sessionUsage: QuotaPeriod?,
        weeklyUsage: QuotaPeriod?
    ) -> QuotaPeriod? {
        switch period {
        case .session: sessionUsage
        case .weekly: weeklyUsage
        }
    }

    // Extra usage means session quota overflow, so the badge is misleading next to a weekly percentage.
    static func mainUsageIsUsingExtraUsage(for period: MainUsageBarPeriod, isUsingExtraUsage: Bool) -> Bool {
        period == .session && isUsingExtraUsage
    }

    static func mainUsageIsStale(
        for period: MainUsageBarPeriod,
        isUsageStale: Bool,
        isWeeklyUsageHeldOver: Bool
    ) -> Bool {
        switch period {
        case .session: isUsageStale
        case .weekly: isWeeklyUsageHeldOver
        }
    }

    static func sharedUsageBarIsEnabled(
        provider: AgentProvider,
        appUsageEnabled: Bool = AppSettings.isUsageEnabled
    ) -> Bool {
        provider != .claude || appUsageEnabled
    }

    static func sharedUsageBarState(
        contextSession: SessionData?,
        claude: SharedUsageBarState?,
        codex: SharedUsageBarState?,
        devin: SharedUsageBarState? = nil,
        lastUsedProvider: AgentProvider = .claude,
        claudeUsageEnabled: Bool = AppSettings.isUsageEnabled
    ) -> SharedUsageBarState? {
        let candidates = [claude, codex, devin].compactMap { $0 }
        guard candidates.count > 1 else {
            return candidates.first
        }

        if let contextProvider = contextSession?.provider,
           let contextState = candidates.first(where: { $0.provider == contextProvider }) {
            return contextState
        }

        let preferred = candidates.first { $0.provider == lastUsedProvider } ?? candidates[0]
        let fallback = candidates.first { $0.provider != preferred.provider && $0.usage != nil }
        guard let fallback else { return preferred }
        return preferredOrFallback(preferred, fallback, claudeUsageEnabled: claudeUsageEnabled)
    }

    // Only a bar with nothing at all to show swaps to the provider that has data. Loading, error,
    // status, and recovery states stay visible, and a disabled Claude keeps its connect placeholder.
    private static func preferredOrFallback(
        _ preferred: SharedUsageBarState,
        _ fallback: SharedUsageBarState,
        claudeUsageEnabled: Bool
    ) -> SharedUsageBarState {
        let preferredIsEnabled = sharedUsageBarIsEnabled(provider: preferred.provider, appUsageEnabled: claudeUsageEnabled)
        let preferredIsSilentlyEmpty = preferred.usage == nil
            && !preferred.isLoading
            && preferred.error == nil
            && preferred.statusMessage == nil
            && preferred.recoveryAction == .none
        return preferredIsEnabled && preferredIsSilentlyEmpty && fallback.usage != nil ? fallback : preferred
    }
}
