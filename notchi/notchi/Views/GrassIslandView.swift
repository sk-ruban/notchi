import SwiftUI

private enum SpriteLayout {
    static let size: CGFloat = 64
    static let usableWidthFraction: CGFloat = 0.8
    static let leftMarginFraction: CGFloat = 0.1

    static func xOffset(xPosition: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let usableWidth = totalWidth * usableWidthFraction
        let leftMargin = totalWidth * leftMarginFraction
        return leftMargin + (xPosition * usableWidth) - (totalWidth / 2)
    }

    static func depthSorted(_ sessions: [SessionData]) -> [SessionData] {
        sessions.sorted { $0.spriteYOffset < $1.spriteYOffset }
    }
}

private enum SpriteMotion {
    static func displayedXPosition(for session: SessionData, among sessions: [SessionData], at date: Date) -> CGFloat {
        let base = session.spriteXPosition
        guard session.state.canWalk else { return clamped(base) }

        let t = date.timeIntervalSinceReferenceDate
        let phase = phaseOffset(for: session.id)
        let cadence = session.task == .working ? 1.35 : 0.75

        switch session.provider {
        case .claude:
            guard let target = nearestCodexSession(to: session, in: sessions) else {
                return clamped(base + CGFloat(sin(t * 0.45 + phase) * 0.012))
            }

            let delta = target.spriteXPosition - base
            guard abs(delta) > 0.01 else {
                return clamped(base + CGFloat(sin(t * 0.55 + phase) * 0.006))
            }

            let direction: CGFloat = delta >= 0 ? 1 : -1
            let stride = 0.5 + 0.5 * sin(t * cadence + phase)
            let pursuit = min(max(abs(delta) * 0.45, 0.02), 0.08)
            let idleSway = CGFloat(sin(t * 0.55 + phase) * 0.006)
            return clamped(base + direction * pursuit * CGFloat(stride) + idleSway)

        case .codex:
            let drift = CGFloat(cos(t * 0.5 + phase) * 0.015)
            let nudge = CGFloat((0.5 + 0.5 * sin(t * 0.9 + phase * 0.7)) * 0.01)
            return clamped(base + drift + nudge)
        }
    }

    private static func nearestCodexSession(to session: SessionData, in sessions: [SessionData]) -> SessionData? {
        sessions
            .filter { $0.provider == .codex }
            .min(by: { abs($0.spriteXPosition - session.spriteXPosition) < abs($1.spriteXPosition - session.spriteXPosition) })
    }

    private static func phaseOffset(for sessionID: String) -> Double {
        let seed = Int(UInt(bitPattern: sessionID.hashValue) % 2_048)
        return Double(seed) / 2_048.0 * .pi * 2
    }

    private static func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.02), 0.98)
    }
}

// MARK: - Visual layer (placed in .background, no interaction)

struct GrassIslandView: View {
    let sessions: [SessionData]
    var selectedSessionId: String?
    var hoveredSessionId: String?

    private let patchWidth: CGFloat = 80

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: sessions.isEmpty)) { timeline in
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    HStack(spacing: 0) {
                        ForEach(0..<patchCount(for: geometry.size.width), id: \.self) { _ in
                            Image("GrassIsland")
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: patchWidth, height: geometry.size.height)
                                .clipped()
                        }
                    }
                    .frame(width: geometry.size.width, alignment: .leading)
                    .drawingGroup()

                    if sessions.isEmpty {
                        GrassSpriteView(state: .idle, xPosition: 0.5, yOffset: -15, totalWidth: geometry.size.width, glowOpacity: 0)
                    } else {
                        ForEach(SpriteLayout.depthSorted(sessions)) { session in
                            GrassSpriteView(
                                state: session.state,
                                xPosition: SpriteMotion.displayedXPosition(for: session, among: sessions, at: timeline.date),
                                yOffset: session.spriteYOffset,
                                totalWidth: geometry.size.width,
                                glowOpacity: glowOpacity(for: session.id)
                            )
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private func glowOpacity(for sessionId: String) -> Double {
        if sessionId == selectedSessionId { return 0.7 }
        if sessionId == hoveredSessionId { return 0.3 }
        return 0
    }

    private func patchCount(for width: CGFloat) -> Int {
        Int(ceil(width / patchWidth)) + 1
    }
}

// MARK: - Interaction layer (placed in .overlay for reliable hit testing)

struct GrassTapOverlay: View {
    let sessions: [SessionData]
    var selectedSessionId: String?
    @Binding var hoveredSessionId: String?
    var onSelectSession: ((String) -> Void)?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: sessions.isEmpty)) { timeline in
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    Color.clear

                    if !sessions.isEmpty {
                        ForEach(SpriteLayout.depthSorted(sessions)) { session in
                            SpriteTapTarget(
                                sessionId: session.id,
                                xPosition: SpriteMotion.displayedXPosition(for: session, among: sessions, at: timeline.date),
                                yOffset: session.spriteYOffset,
                                totalWidth: geometry.size.width,
                                hoveredSessionId: $hoveredSessionId,
                                onTap: { onSelectSession?(session.id) }
                            )
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
            }
        }
    }
}

// MARK: - Private views

private struct NoHighlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct SpriteTapTarget: View {
    let sessionId: String
    let xPosition: CGFloat
    let yOffset: CGFloat
    let totalWidth: CGFloat
    @Binding var hoveredSessionId: String?
    var onTap: (() -> Void)?

    @State private var tapScale: CGFloat = 1.0

    var body: some View {
        Button(action: handleTap) {
            Color.clear
                .frame(width: SpriteLayout.size, height: SpriteLayout.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(NoHighlightButtonStyle())
        .onHover { hovering in
            hoveredSessionId = hovering ? sessionId : nil
        }
        .scaleEffect(tapScale)
        .offset(x: SpriteLayout.xOffset(xPosition: xPosition, totalWidth: totalWidth), y: yOffset)
    }

    private func handleTap() {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { tapScale = 1.15 }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { tapScale = 1.0 }
        }
        onTap?()
    }
}

private struct GrassSpriteView: View {
    let state: NotchiState
    let xPosition: CGFloat
    let yOffset: CGFloat
    let totalWidth: CGFloat
    var glowOpacity: Double = 0

    private let swayDuration: Double = 2.0
    private var bobAmplitude: CGFloat {
        guard state.bobAmplitude > 0 else { return 0 }
        return state.task == .working ? 1.5 : 1
    }
    private let glowColor = Color(red: 0.4, green: 0.7, blue: 1.0)

    private var swayAmplitude: Double {
        (state.task == .sleeping || state.task == .compacting) ? 0 : state.swayAmplitude
    }

    private var isAnimatingMotion: Bool {
        bobAmplitude > 0 || swayAmplitude > 0 || state.emotion == .sob
    }

    private var bobDuration: Double {
        state.task == .working ? 1.0 : state.bobDuration
    }

    private func swayDegrees(at date: Date) -> Double {
        guard swayAmplitude > 0 else { return 0 }
        let t = date.timeIntervalSinceReferenceDate
        let phase = (t / swayDuration).truncatingRemainder(dividingBy: 1.0)
        return sin(phase * .pi * 2) * swayAmplitude
    }

    private static let sobTrembleAmplitude: CGFloat = 0.3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimatingMotion)) { timeline in
            SpriteSheetView(
                spriteSheet: state.spriteSheetSource,
                frameCount: state.frameCount,
                columns: state.columns,
                fps: state.animationFPS,
                isAnimating: true
            )
            .frame(width: SpriteLayout.size, height: SpriteLayout.size)
            .background(alignment: .bottom) {
                if glowOpacity > 0 {
                    Ellipse()
                        .fill(glowColor.opacity(glowOpacity))
                        .frame(width: SpriteLayout.size * 0.85, height: SpriteLayout.size * 0.25)
                        .blur(radius: 8)
                        .offset(y: 4)
                }
            }
            .rotationEffect(.degrees(swayDegrees(at: timeline.date)), anchor: .bottom)
            .offset(
                x: SpriteLayout.xOffset(xPosition: xPosition, totalWidth: totalWidth) + trembleOffset(at: timeline.date, amplitude: state.emotion == .sob ? Self.sobTrembleAmplitude : 0),
                y: yOffset + bobOffset(at: timeline.date, duration: bobDuration, amplitude: bobAmplitude)
            )
        }
    }
}
