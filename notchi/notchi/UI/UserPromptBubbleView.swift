import SwiftUI

struct UserPromptBubbleView: View {
    let text: String?
    let hasAttachment: Bool

    @State private var isExpanded = false

    private static let collapsedLineLimit = 3

    var body: some View {
        promptText
            .panelFont(size: 13)
            .foregroundColor(.white)
            .lineLimit(isExpanded ? nil : Self.collapsedLineLimit)
            .truncationMode(.tail)
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
            return Text(Self.inlineAttributed(prompt))
        }

        guard !prompt.isEmpty else {
            return Text("Attached file").bold()
        }

        return Text("Attached file").bold() + Text("\n") + Text(Self.inlineAttributed(prompt))
    }

    static func inlineAttributed(_ prompt: String) -> AttributedString {
        (try? AttributedString(
            markdown: prompt,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(prompt)
    }
}
