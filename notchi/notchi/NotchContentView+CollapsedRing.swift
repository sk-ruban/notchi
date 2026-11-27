extension NotchContentView {
    static func collapsedRingProvider(
        spriteSession: SessionData?,
        effectiveSession: SessionData?,
        lastUsedProvider: AgentProvider
    ) -> AgentProvider {
        (spriteSession ?? effectiveSession)?.provider ?? lastUsedProvider
    }

    static func collapsedRingUsage(
        provider: AgentProvider,
        claudeUsage: QuotaPeriod?,
        codexSessionUsage: QuotaPeriod?,
        codexWeeklyUsage: QuotaPeriod?,
        devinDailyUsage: QuotaPeriod? = nil,
        devinWeeklyUsage: QuotaPeriod? = nil
    ) -> QuotaPeriod? {
        switch provider {
        case .claude: claudeUsage
        case .codex: codexSessionUsage ?? codexWeeklyUsage
        case .devin: devinDailyUsage ?? devinWeeklyUsage
        }
    }

    static func collapsedRingPercentage(
        isUsageEnabled: Bool,
        provider: AgentProvider,
        claudeUsage: QuotaPeriod?,
        codexSessionUsage: QuotaPeriod?,
        codexWeeklyUsage: QuotaPeriod?,
        devinDailyUsage: QuotaPeriod? = nil,
        devinWeeklyUsage: QuotaPeriod? = nil
    ) -> Int? {
        guard isUsageEnabled else { return nil }
        return collapsedRingUsage(
            provider: provider,
            claudeUsage: claudeUsage,
            codexSessionUsage: codexSessionUsage,
            codexWeeklyUsage: codexWeeklyUsage,
            devinDailyUsage: devinDailyUsage,
            devinWeeklyUsage: devinWeeklyUsage
        )?.usagePercentage
    }

    enum CollapsedRingContent: Equatable {
        case percentage(Int)
        case unlimited
    }

    static func collapsedRingContent(
        isUsageEnabled: Bool,
        provider: AgentProvider,
        claudeUsage: QuotaPeriod?,
        codexSessionUsage: QuotaPeriod?,
        codexWeeklyUsage: QuotaPeriod?,
        codexHasUnlimitedCredits: Bool,
        devinDailyUsage: QuotaPeriod? = nil,
        devinWeeklyUsage: QuotaPeriod? = nil,
        devinHasNoQuota: Bool = false
    ) -> CollapsedRingContent? {
        guard isUsageEnabled else { return nil }
        if let percentage = collapsedRingPercentage(
            isUsageEnabled: isUsageEnabled,
            provider: provider,
            claudeUsage: claudeUsage,
            codexSessionUsage: codexSessionUsage,
            codexWeeklyUsage: codexWeeklyUsage,
            devinDailyUsage: devinDailyUsage,
            devinWeeklyUsage: devinWeeklyUsage
        ) {
            return .percentage(percentage)
        }
        let hasCodexQuota = codexSessionUsage != nil || codexWeeklyUsage != nil
        switch provider {
        case .codex: return codexHasUnlimitedCredits && !hasCodexQuota ? .unlimited : nil
        case .devin: return devinHasNoQuota ? .unlimited : nil
        case .claude: return nil
        }
    }
}
