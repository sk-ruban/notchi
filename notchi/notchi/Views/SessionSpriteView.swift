import SwiftUI

struct SessionSpriteView: View {
    let state: NotchiState
    let isSelected: Bool
    var mirrorSeed: String = "session-sprite"
    var animationStartDate: Date = SpriteAnimationPhase.sharedLoopAnchor
    var repeatsAnimation = true

    @State private var stateMirrorKey: String?
    @State private var stateMirrored = false

    private var bobAmplitude: CGFloat {
        guard state.bobAmplitude > 0 else { return 0 }
        return isSelected ? state.bobAmplitude : state.bobAmplitude * 0.67
    }

    private static let sobTrembleAmplitude: CGFloat = 0.2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: bobAmplitude == 0 && state.emotion != .sob)) { timeline in
            let presentation = spriteSheetPresentation(at: timeline.date)
            SpriteSheetView(
                spriteSheet: presentation.spriteSheetName,
                frameCount: state.frameCount,
                columns: state.columns,
                fps: state.animationFPS,
                isAnimating: true,
                animationStartDate: effectiveAnimationStartDate,
                repeatsAnimation: repeatsAnimation,
                isMirrored: presentation.renderMirrored
            )
            .frame(width: 32, height: 32)
            .offset(
                x: trembleOffset(at: timeline.date, amplitude: state.emotion == .sob ? Self.sobTrembleAmplitude : 0),
                y: bobOffset(at: timeline.date, duration: state.bobDuration, amplitude: bobAmplitude)
            )
        }
        .onAppear(perform: updateStateMirroring)
        .onChange(of: mirrorKey) { _, _ in updateStateMirroring() }
    }

    private func spriteSheetPresentation(at date: Date) -> SpriteSheetPresentation {
        state.spriteSheetPresentation(isMirrored: isMirrored(at: date))
    }

    private var mirrorKey: String {
        "\(mirrorSeed)|\(state.spriteSheetName)"
    }

    private var effectiveAnimationStartDate: Date {
        guard repeatsAnimation, animationStartDate == SpriteAnimationPhase.sharedLoopAnchor else {
            return animationStartDate
        }

        return SpriteAnimationPhase.variedLoopAnchor(for: mirrorSeed, spriteSheet: state.spriteSheetName)
    }

    private func isMirrored(at date: Date) -> Bool {
        SpriteMirrorPolicy.isMirrored(
            state: state,
            seed: mirrorSeed,
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
