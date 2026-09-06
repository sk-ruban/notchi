import SwiftUI

enum SpriteLayout {
    static let size: CGFloat = 64
    static let enlargedSpriteScale: CGFloat = 1.125

    static func spriteScale(panelScale: CGFloat) -> CGFloat {
        panelScale > 1 ? enlargedSpriteScale : 1
    }
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

struct IslandBackgroundView: View {
    let background: IslandBackground
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if background == .automatic {
                AutomaticIslandBackgroundView()
            } else if background == .water {
                TimelineView(.animation(minimumInterval: 1 / WaterAnimation.framesPerSecond, paused: reduceMotion)) { timeline in
                    let frame = WaterAnimation.frameIndex(at: timeline.date, reduceMotion: reduceMotion)
                    Rectangle().fill(tilePaint(assetName: WaterAnimation.assetName(frame: frame)))
                }
            } else if background == .ground {
                ground(for: geometry.size)
            } else {
                Rectangle().fill(grassPaint(for: geometry.size))
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private func ground(for size: CGSize) -> some View {
        let craterSize = floor(min(64, size.width * 0.24, size.height * 0.55) / 2) * 2
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(tilePaint(assetName: background.assetName))
            // Place two landmarks independently of the repeating terrain.
            ForEach(0..<2) { index in
                Image("IslandCrater")
                    .resizable()
                    .interpolation(.none)
                    .frame(width: craterSize, height: craterSize)
                    .position(
                        x: (size.width * (index == 0 ? 0.25 : 0.75)).rounded(),
                        y: (size.height * (index == 0 ? 0.4 : 0.65)).rounded()
                    )
            }
        }
        // Apply the panel fade once to the complete surface, not to each overlapping layer.
        .compositingGroup()
    }

    private func tilePaint(assetName: String) -> ImagePaint {
        ImagePaint(image: Image(assetName).interpolation(.none), scale: 2)
    }

    private func grassPaint(for size: CGSize) -> ImagePaint {
        let scale = max(80 / 512.0, size.height / 512)
        let drawnSize = 512 * scale
        let width = min(1, 80 / drawnSize)
        let height = min(1, size.height / drawnSize)
        // Preserve the original grassland's 80pt aspect-fill crop.
        return ImagePaint(
            image: Image("GrassIsland"),
            sourceRect: CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height),
            scale: scale
        )
    }
}

private struct AutomaticIslandBackgroundView: View {
    private let rotation = IslandBackgroundRotation.shared

    var body: some View {
        let cycle = rotation.cycle
        TimelineView(.periodic(from: cycle.startedAt, by: IslandBackgroundCycle.interval)) { timeline in
            IslandBackgroundView(background: cycle.background(at: timeline.date))
        }
    }
}

// MARK: - Visual layer (placed in .background, no interaction)

struct GrassIslandView: View {
    @AppStorage(AppSettings.islandBackgroundKey) private var backgroundRaw = IslandBackground.grassland.rawValue

    let sessions: [SessionData]
    var selectedSessionId: String?
    var hoveredSessionId: String?
    var handoffSessionId: String?
    var handoffProgress: CGFloat = 1
    var isHandoffCollapsing = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                IslandBackgroundView(background: IslandBackground.resolve(backgroundRaw))
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

private struct SpriteTapTarget: View {
    let sessionId: String
    let xPosition: CGFloat
    let yOffset: CGFloat
    let totalWidth: CGFloat
    @Binding var hoveredSessionId: String?
    var onTap: (() -> Void)?

    @Environment(\.panelScale) private var panelScale
    @State private var tapScale: CGFloat = 1.0

    var body: some View {
        let spriteSize = SpriteLayout.size * SpriteLayout.spriteScale(panelScale: panelScale)
        return Button(action: handleTap) {
            Color.clear
                .frame(width: spriteSize, height: spriteSize)
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
    @Environment(\.panelScale) private var panelScale
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
        let spriteSize = SpriteLayout.size * SpriteLayout.spriteScale(panelScale: panelScale)
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
            .frame(width: spriteSize, height: spriteSize)
            .background(alignment: .bottom) {
                if glowOpacity > 0 {
                    Ellipse()
                        .fill(glowColor.opacity(glowOpacity))
                        .frame(
                            width: spriteSize * 0.85,
                            height: spriteSize * 0.25
                        )
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
