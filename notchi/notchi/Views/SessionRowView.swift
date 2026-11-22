import SwiftUI

struct SessionRowView: View {
    let session: SessionData
    let title: String
    let isSelected: Bool
    let isHovered: Bool
    let onTap: () -> Void
    let onHover: (Bool) -> Void
    let onDelete: () -> Void

    @State private var isTrashHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                stateIndicator
                    .frame(width: 5, height: 5)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .panelFont(size: 12, weight: .medium)
                            .foregroundColor(TerminalColors.primaryText)
                            .lineLimit(1)
                            .layoutPriority(1)

                        if let account = badgeAccount {
                            ClaudeAccountBadge(account: account)
                        }
                    }

                    if let preview = session.activityPreview {
                        Text(preview)
                            .panelFont(size: 10)
                            .foregroundColor(TerminalColors.dimmedText)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if let contextTokens = session.contextTokens {
                    ContextUsageBar(usage: ContextUsage(usedTokens: contextTokens, windowTokens: session.contextWindowTokens))
                }

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .panelFont(size: 11)
                        .foregroundColor(TerminalColors.dimmedText.opacity(isTrashHovered ? 1 : 0.9))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isTrashHovered = $0 }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(isSelected || isHovered ? TerminalColors.hoverBackground : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
    }

    @ViewBuilder
    private var stateIndicator: some View {
        if session.isProcessing {
            ProcessingSpinner(color: providerAccentColor)
        } else {
            Circle()
                .fill(stateColor)
        }
    }

    private var stateColor: Color {
        providerAccentColor
    }

    private var providerAccentColor: Color {
        session.provider.accentColor
    }

    private var badgeAccount: ClaudeAccount? {
        let accounts = ClaudeAccountStore.shared
        guard session.provider == .claude, accounts.showsAccountBadges else { return nil }
        return accounts.account(forSessionDirectory: session.claudeConfigDirectory)
    }
}

private struct ClaudeAccountBadge: View {
    let account: ClaudeAccount

    @Environment(\.panelScale) private var panelScale

    private static let horizontalPadding: CGFloat = 5
    private static let verticalPadding: CGFloat = 1
    private static let backgroundOpacity = 0.18

    var body: some View {
        Text(account.name)
            .panelFont(size: 9, weight: .semibold)
            .foregroundColor(account.color.color)
            .lineLimit(1)
            .padding(.horizontal, Self.horizontalPadding * panelScale)
            .padding(.vertical, Self.verticalPadding * panelScale)
            .background(account.color.color.opacity(Self.backgroundOpacity), in: Capsule())
            .fixedSize()
    }
}
