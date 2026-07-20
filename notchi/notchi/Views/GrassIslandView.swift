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

private enum GrassTexture {
    static let image = Image("GrassIsland")
    static let pixelSize = CGSize(width: 512, height: 512)
    static let tileWidth: CGFloat = 80
}

// MARK: - Visual layer (placed in .background, no interaction)

struct GrassIslandView: View {
    let sessions: [SessionData]
    var selectedSessionId: String?
    var hoveredSessionId: String?
    var handoffSessionId: String?
    var handoffProgress: CGFloat = 1
    var isHandoffCollapsing = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(grassPaint(for: geometry.size))
                    .frame(width: geometry.size.width, height: geometry.size.height)

                if !sessions.isEmpty {
                    ForEach(SpriteLayout.depthSorted(sessions)) { session in
                        GrassSpriteView(
                            state: session.state,
                            sessionId: session.id,
                            xPosition: session.spriteXPosition,
                            yOffset: session.spriteYOffset,
                            totalWidth: geometry.size.width,
                            glowOpacity: glowOpacity(for: session.id)
                        )
                        .opacity(spriteOpacity(for: session.id))
                        .blur(radius: spriteBlur(for: session.id))
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private func glowOpacity(for sessionId: String) -> Double {
        if sessionId == selectedSessionId { return 0.7 }
        if sessionId == hoveredSessionId { return 0.3 }
        return 0
    }

    private func spriteOpacity(for sessionId: String) -> Double {
        guard sessionId == handoffSessionId else { return 1 }
        return SpriteHandoffVisuals.opacity(
            for: handoffProgress,
            isSource: isHandoffCollapsing
        )
    }

    private func spriteBlur(for sessionId: String) -> CGFloat {
        guard sessionId == handoffSessionId else { return 0 }
        return SpriteHandoffVisuals.blur(
            for: handoffProgress,
            isSource: isHandoffCollapsing
        )
    }

    private func grassPaint(for size: CGSize) -> ImagePaint {
        let scale = max(GrassTexture.tileWidth / GrassTexture.pixelSize.width, size.height / GrassTexture.pixelSize.height)
        let drawnSize = CGSize(
            width: GrassTexture.pixelSize.width * scale,
            height: GrassTexture.pixelSize.height * scale
        )
        let visibleWidthFraction = min(1, GrassTexture.tileWidth / drawnSize.width)
        let visibleHeightFraction = min(1, size.height / drawnSize.height)

        // Match the old 80pt aspect-fill tile crop while drawing as a single paint.
        let sourceRect = CGRect(
            x: (1 - visibleWidthFraction) / 2,
            y: (1 - visibleHeightFraction) / 2,
            width: visibleWidthFraction,
            height: visibleHeightFraction
        )

        return ImagePaint(
            image: GrassTexture.image,
            sourceRect: sourceRect,
            scale: scale
        )
    }
}

// MARK: - Interaction layer (placed in .overlay for reliable hit testing)

struct GrassTapOverlay: View {
    let sessions: [SessionData]
    var selectedSessionId: String?
    @Binding var hoveredSessionId: String?
    var handoffSessionId: String?
    var handoffProgress: CGFloat = 1
    var isHandoffCollapsing = false
    var onSelectSession: ((String) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color.clear

                if !sessions.isEmpty {
                    ForEach(SpriteLayout.depthSorted(sessions)) { session in
                        if shouldAllowInteraction(for: session.id) {
                            SpriteTapTarget(
                                sessionId: session.id,
                                xPosition: session.spriteXPosition,
                                yOffset: session.spriteYOffset,
                                totalWidth: geometry.size.width,
                                hoveredSessionId: $hoveredSessionId,
                                onTap: { onSelectSession?(session.id) }
                            )
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
        }
    }

    private func shouldAllowInteraction(for sessionId: String) -> Bool {
        guard sessionId == handoffSessionId else { return true }
        return SpriteHandoffVisuals.isInteractive(
            for: handoffProgress,
            isCollapsing: isHandoffCollapsing
        )
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
            if hovering {
                hoveredSessionId = sessionId
            } else if hoveredSessionId == sessionId {
                hoveredSessionId = nil
            }
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

struct GrassSpriteMotion {
    let state: NotchiState
    let reduceMotion: Bool

    static let sobTrembleAmplitude: CGFloat = 0.3

    var bobAmplitude: CGFloat {
        guard !reduceMotion, state.bobAmplitude > 0 else { return 0 }
        return state.task == .working ? 1.5 : 1
    }

    var swayAmplitude: Double {
        guard !reduceMotion else { return 0 }
        return (state.task == .sleeping || state.task == .compacting) ? 0 : state.swayAmplitude
    }

    var trembleAmplitude: CGFloat {
        guard !reduceMotion, state.emotion == .sob else { return 0 }
        return Self.sobTrembleAmplitude
    }

    var isAnimating: Bool {
        bobAmplitude > 0 || swayAmplitude > 0 || trembleAmplitude > 0
    }

    var frameInterval: Double { 1.0 / 30 }

    var bobDuration: Double {
        state.task == .working ? 1.0 : state.bobDuration
    }
}

private struct GrassSpriteView: View {
    let state: NotchiState
    let sessionId: String
    let xPosition: CGFloat
    let yOffset: CGFloat
    let totalWidth: CGFloat
    var glowOpacity: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stateMirrorKey: String?
    @State private var stateMirrored = false

    private let swayDuration: Double = 2.0
    private let glowColor = Color(red: 0.4, green: 0.7, blue: 1.0)

    private func swayDegrees(at date: Date, amplitude: Double) -> Double {
        guard amplitude > 0 else { return 0 }
        let t = date.timeIntervalSinceReferenceDate
        let phase = (t / swayDuration).truncatingRemainder(dividingBy: 1.0)
        return sin(phase * .pi * 2) * amplitude
    }

    var body: some View {
        let motion = GrassSpriteMotion(state: state, reduceMotion: reduceMotion)
        return TimelineView(.animation(minimumInterval: motion.frameInterval, paused: !motion.isAnimating)) { timeline in
            let presentation = spriteSheetPresentation(at: timeline.date)
            SpriteSheetView(
                spriteSheet: presentation.spriteSheetName,
                frameCount: state.frameCount,
                columns: state.columns,
                fps: state.animationFPS,
                isAnimating: true,
                animationStartDate: SpriteAnimationPhase.variedLoopAnchor(for: sessionId, spriteSheet: state.spriteSheetName),
                isMirrored: presentation.renderMirrored
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
            .rotationEffect(.degrees(swayDegrees(at: timeline.date, amplitude: motion.swayAmplitude)), anchor: .bottom)
            .offset(
                x: SpriteLayout.xOffset(xPosition: xPosition, totalWidth: totalWidth)
                    + trembleOffset(at: timeline.date, amplitude: motion.trembleAmplitude),
                y: yOffset + bobOffset(at: timeline.date, duration: motion.bobDuration, amplitude: motion.bobAmplitude)
            )
        }
        .onAppear(perform: updateStateMirroring)
        .onChange(of: mirrorKey) { _, _ in updateStateMirroring() }
    }

    private func spriteSheetPresentation(at date: Date) -> SpriteSheetPresentation {
        state.spriteSheetPresentation(isMirrored: isMirrored(at: date))
    }

    private var mirrorKey: String {
        "\(sessionId)|\(state.spriteSheetName)"
    }

    private func isMirrored(at date: Date) -> Bool {
        SpriteMirrorPolicy.isMirrored(
            state: state,
            seed: sessionId,
            date: date,
            stateMirrored: stateMirrored
        )
    }

    private func updateStateMirroring() {
        guard stateMirrorKey != mirrorKey else { return }
        stateMirrorKey = mirrorKey
        stateMirrored = SpriteMirrorPolicy.initialMirroring(seed: mirrorKey)
    }
}
