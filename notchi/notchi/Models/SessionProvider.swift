import Foundation

enum SessionProvider: String, Codable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        }
    }

    var integrationName: String {
        switch self {
        case .claude:
            return "Claude Code"
        case .codex:
            return "Codex"
        }
    }

    var spriteCreature: SpriteCreature {
        switch self {
        case .claude:
            return .claude
        case .codex:
            return .codex
        }
    }
}
