import SwiftUI

struct UsageRingView: View {
    let content: NotchContentView.CollapsedRingContent
    var isStale: Bool = false

    private static let standardDiameter: CGFloat = 15
    private static let standardLineWidth: CGFloat = 3
    private static let criticalDiameter: CGFloat = 20
    private static let criticalLineWidth: CGFloat = 2
    private static let criticalPercentage = 90
    private static let fullPercentage = 100
    private static let valueLabelFontSize: CGFloat = 10

    @State private var drawProgress: CGFloat = 0

    private var clampedPercentage: Int {
        switch content {
        case .percentage(let percentage): min(max(percentage, 0), 100)
        case .unlimited: 0
        }
    }

    private var isUnlimited: Bool {
        content == .unlimited
    }

    /// The number inside the ring once it is too full to tell apart by its arc; three digits don't fit.
    var valueLabel: String? {
        guard case .percentage = content, clampedPercentage >= Self.criticalPercentage else { return nil }
        return clampedPercentage >= Self.fullPercentage ? "!" : String(clampedPercentage)
    }

    var diameter: CGFloat {
        valueLabel == nil ? Self.standardDiameter : Self.criticalDiameter
    }

    var lineWidth: CGFloat {
        valueLabel == nil ? Self.standardLineWidth : Self.criticalLineWidth
    }

    private var ringColor: Color {
        let base = TerminalColors.usageColor(forPercentUsed: clampedPercentage)
        return isStale ? base.opacity(0.5) : base
    }

    var body: some View {
        ZStack {
            if isUnlimited {
                Image(systemName: "infinity")
                    .font(.system(size: diameter * 0.85, weight: .bold))
                    .foregroundStyle(ringColor)
                    .opacity(Double(drawProgress))
                    .accessibilityLabel(String(localized: "No spending cap"))
            } else {
                UsageRingArc(fraction: Double(drawProgress))
                    .stroke(
                        ringColor.opacity(0.28),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                    )
                UsageRingArc(fraction: Double(clampedPercentage) / 100 * Double(drawProgress))
                    .stroke(
                        ringColor,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                if let valueLabel {
                    Text(valueLabel)
                        .font(.system(size: Self.valueLabelFontSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(ringColor)
                        .opacity(Double(drawProgress))
                        .contentTransition(.numericText())
                }
            }
        }
        .frame(width: isUnlimited ? nil : diameter, height: diameter)
        .fixedSize()
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.65)) { drawProgress = 1 }
        }
        .animation(.easeInOut(duration: 0.3), value: clampedPercentage)
    }
}

private struct UsageRingArc: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * fraction),
            clockwise: false
        )
        return path
    }
}

#Preview {
    HStack(spacing: 12) {
        UsageRingView(content: .percentage(25))
        UsageRingView(content: .percentage(65))
        UsageRingView(content: .percentage(95))
        UsageRingView(content: .percentage(100))
        UsageRingView(content: .unlimited)
        UsageRingView(content: .unlimited, isStale: true)
    }
    .padding()
    .background(Color.black)
}
