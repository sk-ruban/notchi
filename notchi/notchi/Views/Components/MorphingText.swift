import SwiftUI

struct MorphingText: View {
    let text: String
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let color: Color
    var alignment: TextAlignment = .leading
    var lineLimit: Int? = 1

    @Environment(\.panelScale) private var panelScale
    @State private var displayedText: String
    @State private var blurProgress: CGFloat = 0
    @State private var morphGeneration = 0

    init(
        text: String,
        fontSize: CGFloat,
        fontWeight: Font.Weight = .regular,
        color: Color,
        alignment: TextAlignment = .leading,
        lineLimit: Int? = 1
    ) {
        self.text = text
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.color = color
        self.alignment = alignment
        self.lineLimit = lineLimit
        _displayedText = State(initialValue: text)
    }

    var body: some View {
        let baseText: Text = Text(displayedText)
            .font(.system(size: fontSize * PanelTypography.fontScale(panelScale: panelScale), weight: fontWeight))

        return baseText
            .foregroundColor(color)
            .lineLimit(lineLimit)
            .multilineTextAlignment(alignment)
            // Blur out briefly so the hard string swap reads like a morph.
            .blur(radius: blurProgress * 6)
            .opacity(1 - (blurProgress * 0.18))
            .compositingGroup()
            .onChange(of: text) { _, newText in
                guard newText != displayedText else { return }

                morphGeneration += 1
                let generation = morphGeneration

                withAnimation(.easeOut(duration: 0.11)) {
                    blurProgress = 1
                }

                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(70))
                    guard generation == morphGeneration else { return }

                    displayedText = newText

                    withAnimation(.easeOut(duration: 0.18)) {
                        blurProgress = 0
                    }
                }
            }
    }
}
