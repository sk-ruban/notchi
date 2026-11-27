import SwiftUI

struct ModeBadgeView: View {
    let mode: String
    let rawMode: String

    var color: Color {
        switch rawMode {
        case "plan": TerminalColors.planMode
        case "acceptEdits", CodexPermissionMode.standard: TerminalColors.acceptEdits
        case "auto": TerminalColors.autoMode
        case "bypassPermissions", "dontAsk", CodexPermissionMode.fullAccess: TerminalColors.bypassPermissions
        default: TerminalColors.secondaryText
        }
    }

    var body: some View {
        // The mode is never squeezed; the session title and branch give up width instead.
        Text(mode)
            .panelFont(size: 11, weight: .medium)
            .foregroundColor(color)
            .fixedSize()
    }
}
