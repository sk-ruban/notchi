import XCTest
@testable import notchi

final class UserPromptBubbleViewTests: XCTestCase {
    func testInlineMarkdownRendersBoldWithoutLiteralAsterisks() {
        let rendered = UserPromptBubbleView.inlineAttributed("fix the **P2** issue")
        XCTAssertEqual(String(rendered.characters), "fix the P2 issue")

        let boldRun = rendered.runs.first { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        XCTAssertEqual(boldRun.map { String(rendered.characters[$0.range]) }, "P2")
    }

    func testInlineMarkdownPreservesNewlinesAndIgnoresBlockSyntax() {
        let rendered = UserPromptBubbleView.inlineAttributed("- first line\nsecond line")
        XCTAssertEqual(String(rendered.characters), "- first line\nsecond line")
    }
}
