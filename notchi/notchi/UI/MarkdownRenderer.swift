import SwiftUI

// MARK: - Markdown Text View

struct MarkdownText: View {
    let text: String
    let baseColor: Color
    let fontSize: CGFloat

    @Environment(\.panelScale) private var panelScale

    init(_ text: String, color: Color = .white, fontSize: CGFloat = 13) {
        self.text = text
        self.baseColor = color
        self.fontSize = fontSize
    }

    var body: some View {
        let blocks = parseBlocks(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let content):
            inlineMarkdownText(content)
                .fixedSize(horizontal: false, vertical: true)

        case .unorderedListItem(let content):
            HStack(alignment: .top, spacing: 6) {
                SwiftUI.Text("\u{2022}")
                    .panelFont(size: fontSize)
                    .foregroundColor(baseColor.opacity(0.6))
                    .frame(width: 12, alignment: .center)
                inlineMarkdownText(content)
            }

        case .orderedListItem(let number, let content):
            HStack(alignment: .top, spacing: 6) {
                SwiftUI.Text("\(number).")
                    .panelFont(size: fontSize)
                    .foregroundColor(baseColor.opacity(0.6))
                    .frame(width: 20, alignment: .trailing)
                inlineMarkdownText(content)
            }

        case .blockquote(let content):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(baseColor.opacity(0.4))
                    .frame(width: 2)
                inlineMarkdownText(content)
                    .opacity(0.7)
                    .italic()
            }
            .padding(.vertical, 2)

        case .codeBlock(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                SwiftUI.Text(code)
                    .panelFont(size: 11, design: .monospaced)
                    .foregroundColor(.white.opacity(0.85))
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.08))
            .cornerRadius(6)
        }
    }

    private func inlineMarkdownText(_ content: String) -> SwiftUI.Text {
        FileChipText.render(
            markdown: content,
            surface: .panel,
            baseColor: baseColor,
            fontSize: fontSize,
            fontScale: PanelTypography.fontScale(panelScale: panelScale)
        )
        .font(.system(size: fontSize * PanelTypography.fontScale(panelScale: panelScale)))
    }
}

// MARK: - Block Parsing

private enum MarkdownBlock {
    case paragraph(String)
    case unorderedListItem(String)
    case orderedListItem(Int, String)
    case blockquote(String)
    case codeBlock(String)
}

private func isBlockLevelLine(_ line: String) -> Bool {
    line.hasPrefix("```") || line.hasPrefix("> ") ||
    line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") ||
    line.firstMatch(of: /^(\d+)\.\s+/) != nil ||
    line.trimmingCharacters(in: .whitespaces).isEmpty
}

private func parseBlocks(_ text: String) -> [MarkdownBlock] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var blocks: [MarkdownBlock] = []
    var i = 0

    while i < lines.count {
        let line = lines[i]

        if line.hasPrefix("```") {
            var codeLines: [String] = []
            i += 1
            while i < lines.count && !lines[i].hasPrefix("```") {
                codeLines.append(lines[i])
                i += 1
            }
            if i < lines.count { i += 1 }
            blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
            continue
        }

        if line.hasPrefix("> ") {
            blocks.append(.blockquote(String(line.dropFirst(2))))
            i += 1
            continue
        }

        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            blocks.append(.unorderedListItem(String(line.dropFirst(2))))
            i += 1
            continue
        }

        if let match = line.firstMatch(of: /^(\d+)\.\s+(.+)$/) {
            blocks.append(.orderedListItem(Int(match.1) ?? 1, String(match.2)))
            i += 1
            continue
        }

        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            i += 1
            continue
        }

        // Paragraph: collect consecutive non-block-level lines
        var paraLines: [String] = [line]
        i += 1
        while i < lines.count && !isBlockLevelLine(lines[i]) {
            paraLines.append(lines[i])
            i += 1
        }
        blocks.append(.paragraph(paraLines.joined(separator: " ")))
    }

    return blocks
}
