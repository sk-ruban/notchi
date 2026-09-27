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
            claudeUsage: claude, codexUsage: codex, devinUsage: DevinUsageService(readUsage: { _ in nil }),
            costStore: claudeCosts,
            codexCostStore: codexCosts,
            defaultProvider: .codex
        )

        XCTAssertFalse(codex.hasUsageData)
        XCTAssertTrue(view.codexHasData)
        XCTAssertTrue(view.showsToggle)
        XCTAssertEqual(UsageDetailView.resolvedProvider(
            selected: .codex, claudeHasData: view.claudeHasData, codexHasData: view.codexHasData
        ), .codex)
    }

    func testUnlimitedCreditsKeepCodexSelectableBeforeCostHistoryLoads() async {
        let claude = ClaudeUsageService()
        claude.currentUsage = QuotaPeriod(utilization: 3, resetDate: nil)
        let codex = CodexUsageService()
        codex.hasUnlimitedCredits = true
        let view = UsageDetailView(
            claudeUsage: claude, codexUsage: codex, devinUsage: DevinUsageService(readUsage: { _ in nil }),
            costStore: CostHistoryStore { _ in [:] },
            codexCostStore: CostHistoryStore(provider: .codex) { _ in [:] },
            defaultProvider: .codex
        )

        XCTAssertTrue(view.showsToggle)
        XCTAssertTrue(view.codexHasData)
    }

    func testUnlimitedCreditsRowMarksStaleDataOnlyAfterFailedRefresh() async {
        let codex = CodexUsageService()
        codex.hasUnlimitedCredits = true
        let view = UsageDetailView(
            claudeUsage: ClaudeUsageService(), codexUsage: codex, devinUsage: DevinUsageService(readUsage: { _ in nil }),
            costStore: CostHistoryStore { _ in [:] },
            codexCostStore: CostHistoryStore(provider: .codex) { _ in [:] },
            defaultProvider: .codex
        )

        XCTAssertTrue(view.showsUnlimitedCredits)
        XCTAssertFalse(view.showsStaleUnlimitedCredits)

        codex.isUsageStale = true

        XCTAssertTrue(view.showsStaleUnlimitedCredits)
    }

    func testDevinGetsATabWithoutAllTabWhenNoProviderHasCosts() async {
        let claude = ClaudeUsageService()
        claude.currentUsage = QuotaPeriod(utilization: 3, resetDate: nil)
        let devin = DevinUsageService(
            readUsage: { _ in DevinUsage(daily: QuotaPeriod(utilization: 7, resetDate: nil), weekly: nil) }
        )
        await devin.refresh()
        let view = UsageDetailView(
            claudeUsage: claude, codexUsage: CodexUsageService(), devinUsage: devin,
            costStore: CostHistoryStore { _ in [:] },
            codexCostStore: CostHistoryStore(provider: .codex) { _ in [:] },
            defaultProvider: .devin
        )

        XCTAssertTrue(view.showsToggle)
        XCTAssertEqual(view.tabs, [.provider(.claude), .provider(.devin)])
    }

    func testResolvedProviderReroutesDatalessSelectionToDevinWithData() {
        XCTAssertEqual(
            UsageDetailView.resolvedProvider(
                selected: .codex, claudeHasData: false, codexHasData: false, devinHasData: true
            ),
            .devin
        )
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
