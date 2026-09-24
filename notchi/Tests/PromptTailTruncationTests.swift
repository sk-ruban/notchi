import AppKit
import XCTest
@testable import notchi

final class PromptTailTruncationTests: XCTestCase {
    private static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let charactersPerLine = 11
    private static let lineLimit = 3

    // Monospaced glyphs make line capacity a plain character count, so expectations stay hand-computed.
    private static let lineWidth: CGFloat = {
        let advance = ("a" as NSString).size(withAttributes: [.font: font]).width
        return advance * CGFloat(charactersPerLine) + 0.5
    }()

    private func collapsed(_ text: String) -> String? {
        let result = PromptTailTruncation.collapsed(
            AttributedString(text),
            width: Self.lineWidth,
            lineLimit: Self.lineLimit
        ) { NSAttributedString(string: String($0.characters), attributes: [.font: Self.font]) }
        return result.map { String($0.characters) }
    }

    func testTextFittingWithinLineLimitIsNotTruncated() {
        XCTAssertNil(collapsed("aaaa bbbb cccc dddd eeee ffff"))
    }

    func testTruncatesAfterLastWholeWordOnFinalLine() {
        // Lines: "aaaa bbbb" / "cccc dddd" / "eeee ffff" / "gggg hhhh"
        XCTAssertEqual(collapsed("aaaa bbbb cccc dddd eeee ffff gggg hhhh"), "aaaa bbbb cccc dddd eeee ffff…")
    }

    func testDropsWholeWordWhenEllipsisWouldNotFitBesideIt() {
        // "eeee ffffff" fills the third line exactly, so the ellipsis needs "ffffff" gone.
        XCTAssertEqual(collapsed("aaaa bbbb cccc dddd eeee ffffff gggg"), "aaaa bbbb cccc dddd eeee…")
    }

    func testExplicitNewlinesCountAsLines() {
        XCTAssertEqual(collapsed("aaaa\nbbbb\ncccc\ndddd"), "aaaa\nbbbb\ncccc…")
    }

    func testSingleOversizedWordFallsBackToCharacterCut() {
        let word = String(repeating: "a", count: 40)
        XCTAssertEqual(collapsed(word), String(repeating: "a", count: 32) + "…")
    }

    func testKeepsAttributesOnRetainedPrefix() throws {
        var text = AttributedString("aaaa bbbb cccc dddd eeee ffff gggg hhhh")
        let boldRange = try XCTUnwrap(text.range(of: "bbbb"))
        text[boldRange].inlinePresentationIntent = .stronglyEmphasized

        let result = try XCTUnwrap(PromptTailTruncation.collapsed(text, width: Self.lineWidth, lineLimit: Self.lineLimit) {
            NSAttributedString(string: String($0.characters), attributes: [.font: Self.font])
        })

        let retainedBold = try XCTUnwrap(result.range(of: "bbbb"))
        XCTAssertEqual(result[retainedBold].inlinePresentationIntent, .stronglyEmphasized)
    }
}
