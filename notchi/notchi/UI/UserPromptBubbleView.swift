import SwiftUI

struct UserPromptBubbleView: View {
    let text: String?
    let hasAttachment: Bool

    @Environment(\.panelScale) private var panelScale
    @State private var isExpanded = false
    @State private var collapsedTextWidth: CGFloat?

    private static let collapsedLineLimit = 3

    var body: some View {
        promptText
            .panelFont(size: 13)
            .foregroundColor(.white)
            .lineLimit(isExpanded ? nil : Self.collapsedLineLimit)
            .truncationMode(.tail)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                if !isExpanded { collapsedTextWidth = width }
            }
            .frame(width: isExpanded ? collapsedTextWidth : nil, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(TerminalColors.iMessageBlue)
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded = hovering
                }
            }
    }

    private var promptText: Text {
        let prompt = text ?? ""
        guard hasAttachment else {
            return chippedText(prompt)
        }

        guard !prompt.isEmpty else {
            return Text("Attached file").bold()
        }

        return Text("Attached file").bold() + Text("\n") + chippedText(prompt)
    }

    private func chippedText(_ prompt: String) -> Text {
        FileChipText.render(
            markdown: prompt,
            surface: .userBubble,
            baseColor: .white,
            fontSize: 13,
            fontScale: PanelTypography.fontScale(panelScale: panelScale)
        )
    }

    static func inlineAttributed(_ prompt: String) -> AttributedString {
        (try? AttributedString(
            markdown: prompt,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(prompt)
    }
}
