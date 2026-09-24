import AppKit
import Foundation

// SwiftUI's tail truncation cuts mid-word ("outp…"); this pre-truncates at a word boundary instead.
enum PromptTailTruncation {
    static let ellipsis = "…"

    /// Returns the prefix that fits within `lineLimit` lines at `width` followed by an ellipsis,
    /// or nil when the whole text already fits. `measure` mirrors the rendered fonts for layout.
    static func collapsed(
        _ text: AttributedString,
        width: CGFloat,
        lineLimit: Int,
        measure: (AttributedString) -> NSAttributedString
    ) -> AttributedString? {
        guard width > 0,
              let overflow = visibleUTF16Length(measure(text), width: width, lineLimit: lineLimit)
        else { return nil }

        let characters = String(text.characters)
        var cutoff = String.Index(utf16Offset: overflow, in: characters)
        while true {
            cutoff = wordBoundary(before: cutoff, in: characters)
            var candidate = prefix(of: text, upTo: cutoff, in: characters)
            candidate.append(AttributedString(ellipsis))
            if visibleUTF16Length(measure(candidate), width: width, lineLimit: lineLimit) == nil
                || cutoff == characters.startIndex {
                return candidate
            }
            cutoff = characters.index(before: cutoff)
        }
    }

    /// UTF-16 offset just past the last character on the visible lines, or nil when everything fits.
    static func visibleUTF16Length(_ text: NSAttributedString, width: CGFloat, lineLimit: Int) -> Int? {
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        let glyphCount = layoutManager.numberOfGlyphs
        var glyphIndex = 0
        var lines = 0
        while glyphIndex < glyphCount {
            var lineRange = NSRange()
            layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
            glyphIndex = NSMaxRange(lineRange)
            lines += 1
            if lines == lineLimit {
                return glyphIndex >= glyphCount ? nil : layoutManager.characterIndexForGlyph(at: glyphIndex)
            }
        }
        return nil
    }

    // A cut inside a word moves back to the end of the previous word; a lone oversized word keeps the cut.
    private static func wordBoundary(before index: String.Index, in text: String) -> String.Index {
        let head = text[..<index]
        let cut: String.Index
        if index == text.endIndex || text[index].isWhitespace {
            cut = index
        } else if let lastSpace = head.lastIndex(where: \.isWhitespace) {
            cut = lastSpace
        } else {
            return index
        }
        guard let lastVisible = text[..<cut].lastIndex(where: { !$0.isWhitespace }) else { return text.startIndex }
        return text.index(after: lastVisible)
    }

    private static func prefix(of text: AttributedString, upTo cutoff: String.Index, in characters: String) -> AttributedString {
        let count = characters.distance(from: characters.startIndex, to: cutoff)
        let end = text.characters.index(text.startIndex, offsetBy: count)
        return AttributedString(text[text.startIndex..<end])
    }
}
