import SwiftUI

struct ContextUsage: Equatable {
    let usedTokens: Int
    let windowTokens: Int

    // Claude auto-compacts near the end of the window, so warn a little before that.
    private static let nearlyFullFraction = 0.8

    var fraction: Double {
        min(1, Double(usedTokens) / Double(max(windowTokens, 1)))
    }

    var isNearlyFull: Bool {
        fraction >= Self.nearlyFullFraction
    }

    var tint: Color {
        isNearlyFull ? TerminalColors.amber : TerminalColors.secondaryText
    }

    var usedLabel: String {
        CostStatFormatter.tokens(usedTokens)
    }

    var usedOfWindowLabel: String {
        String(
            localized: "\(usedLabel) / \(CostStatFormatter.tokens(windowTokens)) context",
            comment: "Tooltip on a session's context bar: tokens in the session's context, then the context window size."
        )
    }
}

/// Session-list form: a short bar and the token count.
struct ContextUsageBar: View {
    let usage: ContextUsage

    @Environment(\.panelScale) private var panelScale

    private static let barWidth: CGFloat = 34
    private static let barHeight: CGFloat = 3

    var body: some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(Color.white.opacity(0.15))
                .frame(width: Self.barWidth * panelScale, height: Self.barHeight * panelScale)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(usage.tint)
                        .frame(width: Self.barWidth * panelScale * usage.fraction)
                }
            Text(usage.usedLabel)
                .panelFont(size: 10)
                .monospacedDigit()
                .foregroundColor(usage.tint)
        }
        .help(usage.usedOfWindowLabel)
    }
}

/// Session-header form: a ring that reveals the numbers while hovered.
struct ContextUsageRing: View {
    let usage: ContextUsage

    @Environment(\.panelScale) private var panelScale
    @State private var isHovered = false

    private static let diameter: CGFloat = 12
    private static let lineWidth: CGFloat = 2

    var body: some View {
        HStack(spacing: 5) {
            if isHovered {
                Text(usage.usedOfWindowLabel)
                    .panelFont(size: 10)
                    .monospacedDigit()
                    .foregroundColor(usage.tint)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: Self.lineWidth * panelScale)
                Circle()
                    .trim(from: 0, to: usage.fraction)
                    .stroke(usage.tint, style: StrokeStyle(lineWidth: Self.lineWidth * panelScale, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: Self.diameter * panelScale, height: Self.diameter * panelScale)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(usage.usedOfWindowLabel)
    }
}
