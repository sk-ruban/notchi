//
//  AssistantTextRowView.swift
//  notchi
//
//  Displays assistant text messages as bullet-pointed items in the activity panel.
//

import SwiftUI

struct AssistantTextRowView: View {
    let message: AssistantMessage
    var onExpansionChange: ((Bool) -> Void)? = nil

    @State private var isExpanded = false
    private static let maxDisplayLength = 120

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(TerminalColors.iMessageBlue)
                .frame(width: 5, height: 5)
                .padding(.top, 6)

            if isExpanded {
                MarkdownText(cleanedText)
            } else {
                inlineMarkdownText
            }

            Spacer(minLength: 8)

            if isTruncatable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(TerminalColors.secondaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isTruncatable else { return }
            let nextExpandedState = !isExpanded
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded = nextExpandedState
            }
            onExpansionChange?(nextExpandedState)
        }
    }

    private var inlineMarkdownText: some View {
        let attributed = try? AttributedString(
            markdown: truncatedText,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        return Text(attributed ?? AttributedString(truncatedText))
            .font(.system(size: 13))
            .foregroundColor(.white)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
    }

    private var isTruncatable: Bool {
        cleanedText.count > Self.maxDisplayLength || cleanedText.contains("\n")
    }

    private var cleanedText: String {
        message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var truncatedText: String {
        var text = cleanedText

        // Truncate at first newline if present
        if let newlineIndex = text.firstIndex(of: "\n") {
            text = String(text[..<newlineIndex])
        }

        // Truncate at max length if still too long
        if text.count > Self.maxDisplayLength {
            let index = text.index(text.startIndex, offsetBy: Self.maxDisplayLength)
            text = String(text[..<index]) + "..."
        }

        return text
    }
}
