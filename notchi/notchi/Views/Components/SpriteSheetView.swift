import SwiftUI

enum SpriteAnimationPhase {
    // Anchor legacy looping callers to an absolute phase unless a one-shot animation provides its own start date.
    static let sharedLoopAnchor = Date(timeIntervalSinceReferenceDate: 0)
    private static let variedLoopPhaseSpreadSeconds: UInt64 = 120

    static func variedLoopAnchor(for seed: String, spriteSheet: String) -> Date {
        let offset = TimeInterval(SpriteMirrorPolicy.hash("\(seed)|\(spriteSheet)|phase") % variedLoopPhaseSpreadSeconds)
        return Date(timeIntervalSinceReferenceDate: -offset)
    }
}

enum SpriteMirrorPolicy {
    enum Mode: Equatable {
        // Mirror timing is expressed in whole-second windows for predictable seeded variation.
        case timed(ClosedRange<UInt64>)
        case stateEntry
        case never
    }

    static func isMirrored(
        state: NotchiState,
        seed: String,
        date: Date,
        stateMirrored: Bool
    ) -> Bool {
        switch state.mirrorPolicy {
        case .timed(let range):
            let interval = timedInterval(seed: "\(seed)|\(state.spriteSheetName)|interval", range: range)
            let window = Int(date.timeIntervalSinceReferenceDate / interval)
            return initialMirroring(seed: "\(seed)|\(state.spriteSheetName)|\(window)")
        case .stateEntry:
            return stateMirrored
        case .never:
            return false
        }
    }

    static func initialMirroring(seed: String) -> Bool {
        hash(seed) & 1 == 0
    }

    static func timedInterval(seed: String, range: ClosedRange<UInt64>) -> TimeInterval {
        guard range.lowerBound < range.upperBound else {
            return TimeInterval(range.lowerBound)
        }

        let spread = range.upperBound - range.lowerBound
        let divisor = spread == UInt64.max ? UInt64.max : spread + 1
        return TimeInterval(range.lowerBound + (hash(seed) % divisor))
    }

    static func hash(_ value: String) -> UInt64 {
        let offsetBasis: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211
        var hash = offsetBasis

        for scalar in value.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash = hash &* prime
        }

        return hash
    }
}

struct SpriteSheetView: View {
    let spriteSheet: String
    var frameCount: Int = 6
    var columns: Int = 6
    var fps: Double = 10
    var isAnimating: Bool = true
    var animationStartDate: Date = SpriteAnimationPhase.sharedLoopAnchor
    var repeatsAnimation: Bool = true
    var isMirrored: Bool = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / fps, paused: !isAnimating)) { timeline in
            SpriteFrameView(
                spriteSheet: spriteSheet,
                frameCount: frameCount,
                columns: columns,
                currentFrame: currentFrame(at: timeline.date),
                isMirrored: isMirrored
            )
        }
    }

    private func currentFrame(at date: Date) -> Int {
        guard isAnimating else { return 0 }
        let elapsed = max(0, date.timeIntervalSince(animationStartDate))
        let frame = Int(elapsed * fps)

        if repeatsAnimation {
            return frame % frameCount
        }

        return min(frame, frameCount - 1)
    }
}

private struct SpriteFrameView: View {
    let spriteSheet: String
    let frameCount: Int
    let columns: Int
    let currentFrame: Int
    let isMirrored: Bool

    var body: some View {
        GeometryReader { geometry in
            let frameWidth = geometry.size.width
            let frameHeight = geometry.size.height
            let rows = (frameCount + columns - 1) / columns

            let col = currentFrame % columns
            let row = currentFrame / columns

            Image(spriteSheet)
                .interpolation(.none)
                .resizable()
                .frame(width: frameWidth * CGFloat(columns),
                       height: frameHeight * CGFloat(rows))
                .offset(x: -frameWidth * CGFloat(col),
                        y: -frameHeight * CGFloat(row))
        }
        .clipped()
        .scaleEffect(x: isMirrored ? -1 : 1, y: 1, anchor: .center)
    }
}
