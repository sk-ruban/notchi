import SwiftUI

struct PanelSwapTransitionModifier: ViewModifier {
    let blur: CGFloat
    let opacity: Double
    let xOffset: CGFloat

    static let identity = PanelSwapTransitionModifier(blur: 0, opacity: 1, xOffset: 0)

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .opacity(opacity)
            .offset(x: xOffset)
            .compositingGroup()
    }
}
