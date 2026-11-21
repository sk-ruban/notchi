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
                    Text(title)
                        .panelFont(size: 12, weight: .medium)
                        .foregroundColor(TerminalColors.primaryText)
                        .lineLimit(1)
                        .layoutPriority(1)

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
}
