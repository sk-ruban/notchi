import SwiftUI

enum ClaudeAccountColor: String, CaseIterable, Codable, Sendable {
    case orange, blue, green, purple, pink, teal

    var color: Color {
        switch self {
        case .orange: TerminalColors.claudeOrange
        case .blue: TerminalColors.iMessageBlue
        case .green: TerminalColors.green
        case .purple: TerminalColors.acceptEdits
        case .pink: TerminalColors.bypassPermissions
        case .teal: TerminalColors.gitBranch
        }
    }
}

/// One Claude Code config directory (`~/.claude`, `~/.claude-personal`, …), each a separate login.
struct ClaudeAccount: Identifiable, Equatable {
    /// The directory with symlinks resolved, so `/var` and `/private/var` spellings match.
    let key: String
    let directory: URL
    let isDefault: Bool
    let name: String
    let color: ClaudeAccountColor
    let isNotchiEnabled: Bool

    var id: String { key }

    /// `.claude-personal` → "Personal", `.claude_my-team` → "My Team".
    static func folderName(for directory: URL, isDefault: Bool) -> String {
        guard !isDefault else { return String(localized: "Default") }
        let folder = directory.lastPathComponent
        let trimmed = folder.hasPrefix(".claude") ? String(folder.dropFirst(".claude".count)) : folder
        let words = trimmed.split { "-_. ".contains($0) }
        guard !words.isEmpty else { return folder }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

struct ClaudeAccountPreference: Codable, Equatable {
    var name: String?
    var color: ClaudeAccountColor?
}
