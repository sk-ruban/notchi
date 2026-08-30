import SwiftUI

struct TerminalColors {
    static let green = Color(red: 0.4, green: 0.75, blue: 0.45)
    static let amber = Color(red: 1.0, green: 0.7, blue: 0.0)
    static let red = Color(red: 1.0, green: 0.3, blue: 0.3)
    static let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let claudeOrangeDeep = Color(red: 0.78, green: 0.36, blue: 0.19)
    static let codexAccent = Color(red: 0.4, green: 0.435, blue: 0.945)
    static let codexAccentDeep = Color(red: 0.25, green: 0.28, blue: 0.72)

    static let claudeChartShades = [
        claudeOrangeDeep,
        Color(red: 0.86, green: 0.52, blue: 0.37),
        Color(red: 0.95, green: 0.70, blue: 0.52),
    ]
    static let codexChartShades = [
        codexAccentDeep,
        codexAccent,
        Color(red: 0.62, green: 0.66, blue: 0.98),
    ]
    static let iMessageBlue = Color(red: 0, green: 0.478, blue: 1)
    static let planMode = Color(red: 72.0 / 255.0, green: 150.0 / 255.0, blue: 140.0 / 255.0)
    static let acceptEdits = Color(red: 175.0 / 255.0, green: 135.0 / 255.0, blue: 255.0 / 255.0)
    static let autoMode = Color(red: 255.0 / 255.0, green: 193.0 / 255.0, blue: 7.0 / 255.0)
    static let bypassPermissions = Color(red: 255.0 / 255.0, green: 107.0 / 255.0, blue: 128.0 / 255.0)
    static let gitBranch = Color(red: 137.0 / 255.0, green: 220.0 / 255.0, blue: 235.0 / 255.0)

    static let primaryText = Color.white.opacity(0.9)
    static let secondaryText = Color.white.opacity(0.5)
    static let dimmedText = Color.white.opacity(0.3)
    static let subtleBackground = Color.white.opacity(0.04)
    static let hoverBackground = Color.white.opacity(0.08)

    static func usageColor(forPercentUsed percentUsed: Int) -> Color {
        switch percentUsed {
        case ..<50: return green
        case ..<80: return amber
        default: return red
        }
    }
}

extension AgentProvider {
    var accentColor: Color {
        switch self {
        case .claude:
            TerminalColors.claudeOrange
        case .codex:
            TerminalColors.codexAccent
        }
    }

    var deepAccentColor: Color {
        switch self {
        case .claude:
            TerminalColors.claudeOrangeDeep
        case .codex:
            TerminalColors.codexAccentDeep
        }
    }
}
