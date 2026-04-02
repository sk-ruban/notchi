import SwiftUI

struct SessionSpriteView: View {
    let state: NotchiState
    let isSelected: Bool

    private var bobAmplitude: CGFloat {
        guard state.bobAmplitude > 0 else { return 0 }
        return isSelected ? state.bobAmplitude : state.bobAmplitude * 0.67
    }

    private static let sobTrembleAmplitude: CGFloat = 0.2

    private var tintColor: Color {
        switch AppSettings.spriteColor {
        case .orange:
            return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .purple:
            return Color(red: 0.6, green: 0.4, blue: 0.85)
        case .blue:
            return Color(red: 0.3, green: 0.55, blue: 0.95)
        case .green:
            return Color(red: 0.4, green: 0.75, blue: 0.45)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: bobAmplitude == 0 && state.emotion != .sob)) { timeline in
            SpriteSheetView(
                spriteSheet: state.spriteSheetName,
                frameCount: state.frameCount,
                columns: state.columns,
                fps: state.animationFPS,
                isAnimating: true
            )
            .frame(width: 32, height: 32)
            .colorMultiply(tintColor)
            .offset(
                x: trembleOffset(at: timeline.date, amplitude: state.emotion == .sob ? Self.sobTrembleAmplitude : 0),
                y: bobOffset(at: timeline.date, duration: state.bobDuration, amplitude: bobAmplitude)
            )
        }
    }
}
