import XCTest
@testable import notchi

@MainActor
final class UsageDetailViewTests: XCTestCase {
    func testResolvedProviderKeepsSelectionWhenItHasData() {
        XCTAssertEqual(
            UsageDetailView.resolvedProvider(selected: .claude, claudeHasData: true, codexHasData: true),
            .claude
        )
        XCTAssertEqual(
            UsageDetailView.resolvedProvider(selected: .codex, claudeHasData: true, codexHasData: true),
            .codex
        )
        XCTAssertEqual(
            UsageDetailView.resolvedProvider(selected: .codex, claudeHasData: false, codexHasData: true),
            .codex
        )
    }

    func testResolvedProviderReroutesDatalessClaudeToCodexWithData() {
        XCTAssertEqual(
            UsageDetailView.resolvedProvider(selected: .claude, claudeHasData: false, codexHasData: true),
            .codex
        )
    }

    func testResolvedProviderReroutesDatalessCodexToClaudeWithData() {
        XCTAssertEqual(
            UsageDetailView.resolvedProvider(selected: .codex, claudeHasData: true, codexHasData: false),
            .claude
        )
    }

    func testResolvedProviderKeepsSelectionWhenNoProviderHasData() {
        XCTAssertEqual(
            UsageDetailView.resolvedProvider(selected: .claude, claudeHasData: false, codexHasData: false),
            .claude
        )
        XCTAssertEqual(
            UsageDetailView.resolvedProvider(selected: .codex, claudeHasData: false, codexHasData: false),
            .codex
        )
    }
}
