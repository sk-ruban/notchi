import SwiftUI

/// A sprite's state-entry mirroring, seeded once per seed and sprite sheet.
struct SpriteMirroring {
    private var stateMirrorKey: String?
    private var stateMirrored = false

    static func mirrorKey(seed: String, state: NotchiState) -> String {
        "\(seed)|\(state.spriteSheetName)"
    }

    mutating func update(seed: String, state: NotchiState) {
        let mirrorKey = Self.mirrorKey(seed: seed, state: state)
        guard stateMirrorKey != mirrorKey else { return }
        stateMirrorKey = mirrorKey
        stateMirrored = SpriteMirrorPolicy.initialMirroring(seed: mirrorKey)
    }

    func spriteSheetPresentation(state: NotchiState, seed: String, at date: Date) -> SpriteSheetPresentation {
        state.spriteSheetPresentation(isMirrored: SpriteMirrorPolicy.isMirrored(
            state: state,
            seed: seed,
            date: date,
            stateMirrored: stateMirrored
        ))
    }
}

extension View {
    /// Seeds the mirroring on appear and again whenever the seed or sprite sheet changes.
    func spriteMirroring(_ mirroring: Binding<SpriteMirroring>, seed: String, state: NotchiState) -> some View {
        onAppear { mirroring.wrappedValue.update(seed: seed, state: state) }
            .onChange(of: SpriteMirroring.mirrorKey(seed: seed, state: state)) { _, _ in
                mirroring.wrappedValue.update(seed: seed, state: state)
            }
    }
}
