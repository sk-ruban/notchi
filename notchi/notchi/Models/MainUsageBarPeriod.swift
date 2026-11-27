import Foundation

enum MainUsageBarPeriod: String, CaseIterable, Identifiable {
    case session
    case weekly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .session: String(localized: "Session")
        case .weekly: String(localized: "Weekly")
        }
    }

    func displayName(for provider: AgentProvider) -> String {
        switch (self, provider) {
        case (.session, .devin): String(localized: "Daily")
        default: displayName
        }
    }
}
