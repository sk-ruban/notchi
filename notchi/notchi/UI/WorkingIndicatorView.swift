import Combine
import SwiftUI

struct WorkingIndicatorView: View {
    let state: NotchiState
    let workingVerb: String
    var workingSince: Date?
    let color: Color
    @State private var dotCount = 1
    @State private var symbolPhase = 0

    private let dotsTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    private let symbolTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    private var dots: String {
        String(repeating: ".", count: dotCount)
    }

    private var displaySymbol: String {
        WorkingIndicatorPresentation.symbol(for: state.task, phase: symbolPhase)
    }

    private var displayText: String {
        WorkingIndicatorPresentation.text(
            for: state.task,
            workingVerb: workingVerb,
            dots: dots,
            elapsed: workingSince.flatMap { WorkingIndicatorPresentation.elapsedDisplay(since: $0, now: Date()) }
        )
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(displaySymbol)
                .panelFont(size: 14, weight: .bold)
                .foregroundColor(color)
                .frame(width: 14, alignment: .center)
            ShimmeringText(
                text: displayText,
                fontSize: 12,
                color: color,
                isEnabled: state.task != .waiting
            )
        }
        .padding(.leading, -1)
        .onReceive(dotsTimer) { _ in
            dotCount = (dotCount % 3) + 1
        }
        .onReceive(symbolTimer) { _ in
            guard state.task != .waiting else { return }
            symbolPhase = (symbolPhase + 1) % WorkingIndicatorPresentation.animatedSymbols.count
        }
    }
}

private struct ShimmeringText: View {
    let text: String
    let fontSize: CGFloat
    let color: Color
    let isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSweeping = false

    private let duration: TimeInterval = 2.5
    private let pauseBetweenSweepsNanoseconds: UInt64 = 1_000_000_000
    private let frameDelayNanoseconds: UInt64 = 16_000_000

    private var shimmerActive: Bool { isEnabled && !reduceMotion }

    private struct ShimmerStateKey: Hashable {
        let isEnabled: Bool
        let reduceMotion: Bool
    }

    var body: some View {
        Text(text)
            .panelFont(size: fontSize, weight: .medium) { $0.italic() }
            .foregroundColor(color)
            .overlay(alignment: .leading) {
                if shimmerActive {
                    shimmerSweep
                        .mask(
                            Text(text)
                                .panelFont(size: fontSize, weight: .medium) { $0.italic() }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        )
                }
            }
            .task(id: ShimmerStateKey(isEnabled: isEnabled, reduceMotion: reduceMotion)) {
                isSweeping = false
                guard shimmerActive else { return }
                await runShimmerLoop()
            }
    }

    private func runShimmerLoop() async {
        let sweepDurationNanoseconds = UInt64(duration * 1_000_000_000)

        while !Task.isCancelled {
            isSweeping = false

            // WHY: Yield one frame so the reset to false commits before the
            // animated true flip; otherwise SwiftUI coalesces them and the
            // sweep starts mid-screen.
            do {
                try await Task.sleep(nanoseconds: frameDelayNanoseconds)
            } catch {
                return
            }

            withAnimation(.linear(duration: duration)) {
                isSweeping = true
            }

            do {
                try await Task.sleep(nanoseconds: sweepDurationNanoseconds + pauseBetweenSweepsNanoseconds)
            } catch {
                return
            }
        }
    }

    private var shimmerSweep: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let sweepWidth = max(width * 0.7, 64)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color.white.opacity(0.03), location: 0.3),
                    .init(color: Color.white.opacity(0.42), location: 0.5),
                    .init(color: Color.white.opacity(0.03), location: 0.7),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: sweepWidth, height: proxy.size.height)
            .offset(x: isSweeping ? width + sweepWidth : -sweepWidth)
        }
        .allowsHitTesting(false)
    }
}

enum WorkingIndicatorPresentation {
    static let animatedSymbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    static let waitingSymbol = "✳"

    static func symbol(for task: NotchiTask, phase: Int) -> String {
        if task == .waiting {
            return waitingSymbol
        }
        return animatedSymbols[phase % animatedSymbols.count]
    }

    static func text(for task: NotchiTask, workingVerb: String, dots: String, elapsed: String? = nil) -> String {
        switch task {
        case .compacting:
            return String(localized: "Compacting") + dots
        case .waiting:
            return String(localized: "Waiting") + dots
        default:
            guard let elapsed else { return "\(workingVerb)\(dots)" }
            return String(localized: "\(workingVerb) for \(elapsed)") + dots
        }
    }

    static func elapsedDisplay(since start: Date, now: Date, locale: Locale = .autoupdatingCurrent) -> String? {
        let seconds = Int(now.timeIntervalSince(start))
        guard seconds >= 1 else { return nil }
        return Duration.seconds(seconds).formatted(
            .units(
                allowed: [.hours, .minutes, .seconds],
                width: .narrow,
                maximumUnitCount: 2,
                fractionalPart: .hide(rounded: .down)
            )
            .locale(locale)
        )
    }
}
