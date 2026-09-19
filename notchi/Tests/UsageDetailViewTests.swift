import XCTest
@testable import notchi

@MainActor
final class UsageDetailViewTests: XCTestCase {
    func testUnlimitedCreditsKeepCodexSelectableBeforeCostHistoryLoads() async {
        let claude = ClaudeUsageService()
        claude.currentUsage = QuotaPeriod(utilization: 3, resetDate: nil)
        let codex = CodexUsageService()
        codex.hasUnlimitedCredits = true
        let view = UsageDetailView(
            claudeUsage: claude, codexUsage: codex,
            costStore: CostHistoryStore { _ in [:] },
            codexCostStore: CostHistoryStore(provider: .codex) { _ in [:] },
            defaultProvider: .codex
        )

        XCTAssertTrue(view.showsToggle)
        XCTAssertTrue(view.codexHasData)
    }

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
