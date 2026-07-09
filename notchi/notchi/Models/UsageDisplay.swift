import Foundation

nonisolated struct UsagePeriodDisplay: Equatable {
    let title: String
    let percentUsed: Int
    let resetText: String?
    var isStale: Bool = false
}

nonisolated struct ExtraUsageDisplay: Equatable {
    let usedCredits: Double
    let monthlyLimit: Double

    var percentUsed: Int {
        guard monthlyLimit > 0 else { return 0 }
        return min(max(Int((usedCredits / monthlyLimit * 100).rounded()), 0), 100)
    }
}

nonisolated enum UsageMetrics {
    static func periodDisplay(title: String, usage: QuotaPeriod?, isStale: Bool = false) -> UsagePeriodDisplay? {
        guard let usage else { return nil }
        let resetText = usage.formattedResetTime.map { String(localized: "resets in \($0)") }
        return UsagePeriodDisplay(
            title: title,
            percentUsed: min(max(usage.usagePercentage, 0), 100),
            resetText: resetText,
            isStale: isStale
        )
    }

    static func claudeHasData(usage: QuotaPeriod?, weeklyUsage: QuotaPeriod?, modelUsage: QuotaPeriod?, extraUsage: ExtraUsage?) -> Bool {
        usage != nil || weeklyUsage != nil || modelUsage != nil || extraUsageDisplay(extraUsage) != nil
    }

    static func codexHasData(usage: QuotaPeriod?, weeklyUsage: QuotaPeriod?) -> Bool {
        usage != nil || weeklyUsage != nil
    }

    static func extraUsageDisplay(_ extraUsage: ExtraUsage?) -> ExtraUsageDisplay? {
        guard let extraUsage,
              extraUsage.isEnabled,
              let monthlyLimit = extraUsage.monthlyLimit, monthlyLimit > 0,
              let usedCredits = extraUsage.usedCredits else {
            return nil
        }
        return ExtraUsageDisplay(usedCredits: usedCredits, monthlyLimit: monthlyLimit)
    }
}
