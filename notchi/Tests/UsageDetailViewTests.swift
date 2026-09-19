import XCTest
@testable import notchi

@MainActor
final class UsageDetailViewTests: XCTestCase {
    func testCostHistoryKeepsCodexSelectableWithoutQuotaData() async {
        let claude = ClaudeUsageService()
        claude.currentUsage = QuotaPeriod(utilization: 3, resetDate: nil)
        let codex = CodexUsageService()
        let claudeCosts = CostHistoryStore { _ in [:] }
        let codexCosts = CostHistoryStore(provider: .codex) { _ in
            ["2026-09-19": ["gpt-5": ModelTokenTotals(input: 100, requestCount: 1)]]
        }
        await codexCosts.refresh()
        let view = UsageDetailView(
            claudeUsage: claude, codexUsage: codex, costStore: claudeCosts,
            codexCostStore: codexCosts, defaultProvider: .codex
        )

        XCTAssertFalse(codex.hasUsageData)
        XCTAssertTrue(view.codexHasData)
        XCTAssertTrue(view.showsToggle)
        XCTAssertEqual(UsageDetailView.resolvedProvider(
            selected: .codex, claudeHasData: view.claudeHasData, codexHasData: view.codexHasData
        ), .codex)
    }

    func testUnlimitedCreditsKeepCodexSelectableBeforeCostHistoryLoads() {
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
