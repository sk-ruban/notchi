import SwiftUI

struct PanelHeaderButton: View {
    static let baseSize: CGFloat = 32

    let sfSymbol: String
    let label: String
    var showsIndicator: Bool = false
    let action: () -> Void
    @Environment(\.panelScale) private var panelScale
    @State private var isHovered = false

    var body: some View {
        let buttonScale: CGFloat = panelScale > 1 ? 17 / 16 : 1
        Button(action: action) {
            Image(systemName: sfSymbol)
                .font(.system(size: 16 * buttonScale, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: Self.baseSize * buttonScale, height: Self.baseSize * buttonScale)
                .background(isHovered ? TerminalColors.hoverBackground : TerminalColors.subtleBackground)
                .clipShape(Circle())
                .overlay(alignment: .topTrailing) {
                    if showsIndicator {
                        Circle()
                            .fill(TerminalColors.red)
                            .frame(width: 6 * buttonScale, height: 6 * buttonScale)
                            .offset(x: -6 * buttonScale, y: 6 * buttonScale)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
