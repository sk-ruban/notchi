import SwiftUI

struct SessionRowView: View {
    let session: SessionData
    let title: String
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var isRowHovered = false
    @State private var isTrashHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                stateIndicator
                    .frame(width: 5, height: 5)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(TerminalColors.primaryText)
                        .lineLimit(1)

                    if let preview = session.activityPreview {
                        Text(preview)
                            .font(.system(size: 10))
                            .foregroundColor(TerminalColors.dimmedText)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
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
            .background(isSelected || isRowHovered ? TerminalColors.hoverBackground : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .onHover { isRowHovered = $0 }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        if session.isProcessing {
            ProcessingSpinner()
        } else {
            Circle()
                .fill(stateColor)
        }
    }

    private var stateColor: Color {
        providerAccentColor
    }

    private var providerAccentColor: Color {
        TerminalColors.claudeOrange
    }
}
