import Foundation

enum ClaudeUsageRecoveryAction: Equatable {
    case none
    case retry
    case reconnect
    case waitForClaudeCode
}

enum ClaudeUsageResumeTrigger: String, Sendable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
}

struct ClaudeUsageRecoverySnapshot: Codable, Equatable {
    let oauthBackoffUntil: Date?
    let oauthHeadersFallbackProbeUntil: Date?
    let isHeadersFallbackActive: Bool
    let lastGoodUsage: QuotaPeriod?
    let lastGoodWeeklyUsage: QuotaPeriod?
    let lastGoodModelUsage: QuotaPeriod?
    let lastGoodModelUsageName: String?
    let lastGoodExtraUsage: ExtraUsage?
    let lastObservedExtraUsageCredits: Double?
    let extraUsageResetMarker: String?
    let isUsingExtraUsage: Bool?
}

struct ClaudeExtraUsageObservation: Codable, Equatable {
    let extraUsage: ExtraUsage?
    let lastObservedExtraUsageCredits: Double?
    let extraUsageResetMarker: String?
    let isUsingExtraUsage: Bool
}
