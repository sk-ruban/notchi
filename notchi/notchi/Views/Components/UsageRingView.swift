import SwiftUI

struct UsageRingView: View {
    let content: NotchContentView.CollapsedRingContent
    var diameter: CGFloat = 15
    var lineWidth: CGFloat = 3
    var isStale: Bool = false

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

    private var ringColor: Color {
        let base: Color
        switch clampedPercentage {
        case ..<50: base = TerminalColors.green
        case ..<80: base = TerminalColors.amber
        default: base = TerminalColors.red
        }
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
        UsageRingView(content: .unlimited)
        UsageRingView(content: .unlimited, isStale: true)
    }
    .padding()
    .background(Color.black)
}
