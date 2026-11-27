import Foundation

enum NotchSlotContent: String, CaseIterable, Identifiable {
    case latest
    case ring
    case claude
    case codex
    case devin
    case nothing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .latest: String(localized: "Latest Session Mascot")
        case .ring: String(localized: "Usage Ring")
        case .claude: String(localized: "Claude Mascot")
        case .codex: String(localized: "Codex Mascot")
        case .devin: String(localized: "Devin Mascot")
        case .nothing: String(localized: "Nothing")
        }
    }

    var spriteProvider: AgentProvider? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .devin: .devin
        case .nothing, .ring, .latest: nil
        }
    }

    var isSprite: Bool {
        switch self {
        case .latest, .claude, .codex, .devin: true
        case .nothing, .ring: false
        }
    }

    static func conflict(_ a: NotchSlotContent, _ b: NotchSlotContent) -> Bool {
        guard a != .nothing, b != .nothing else { return false }
        return a == b || (a.isSprite && b.isSprite && (a == .latest || b == .latest))
    }
}
