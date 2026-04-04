import SwiftUI

struct SpriteSheetView: View {
    let spriteSheet: SpriteSheetSource
    var frameCount: Int = 6
    var columns: Int = 6
    var fps: Double = 10
    var isAnimating: Bool = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / fps, paused: !isAnimating)) { timeline in
            SpriteFrameView(
                spriteSheet: spriteSheet,
                frameCount: frameCount,
                columns: columns,
                currentFrame: currentFrame(at: timeline.date)
            )
        }
    }

    private func currentFrame(at date: Date) -> Int {
        guard isAnimating else { return 0 }
        let elapsed = date.timeIntervalSinceReferenceDate
        return Int(elapsed * fps) % frameCount
    }
}

private struct SpriteFrameView: View {
    let spriteSheet: SpriteSheetSource
    let frameCount: Int
    let columns: Int
    let currentFrame: Int

    var body: some View {
        GeometryReader { geometry in
            let frameWidth = geometry.size.width
            let frameHeight = geometry.size.height
            let rows = (frameCount + columns - 1) / columns

            let col = currentFrame % columns
            let row = currentFrame / columns

            if let image = SpriteImageRegistry.shared.image(for: spriteSheet) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: frameWidth * CGFloat(columns),
                           height: frameHeight * CGFloat(rows))
                    .offset(x: -frameWidth * CGFloat(col),
                            y: -frameHeight * CGFloat(row))
            } else {
                Color.clear
            }
        }
        .clipped()
    }
}
