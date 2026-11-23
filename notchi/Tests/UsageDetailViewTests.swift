import SwiftUI
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
            codexCostStore: codexCosts, devinCostStore: CostHistoryStore(provider: .devin) { _ in [:] },
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
            devinCostStore: CostHistoryStore(provider: .devin) { _ in [:] },
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
            devinCostStore: CostHistoryStore(provider: .devin) { _ in [:] },
            defaultProvider: .codex
        )

        XCTAssertTrue(view.showsUnlimitedCredits)
        XCTAssertFalse(view.showsStaleUnlimitedCredits)

        codex.isUsageStale = true

        XCTAssertTrue(view.showsStaleUnlimitedCredits)
    }

    func testDevinPlanWithoutQuotaShowsPlanRowInsteadOfQuotaBars() async {
        let devin = DevinUsageService(
            readUsage: { _ in DevinUsage(daily: nil, weekly: nil, planName: "Teams", hasNoQuota: true) }
        )
        await devin.refresh()
        let view = UsageDetailView(
            claudeUsage: ClaudeUsageService(), codexUsage: CodexUsageService(), devinUsage: devin,
            costStore: CostHistoryStore { _ in [:] },
            codexCostStore: CostHistoryStore(provider: .codex) { _ in [:] },
            devinCostStore: CostHistoryStore(provider: .devin) { _ in [:] },
            defaultProvider: .devin
        )

        XCTAssertTrue(view.showsDevinNoQuotaPlan)
        XCTAssertTrue(view.periods.isEmpty)
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
            devinCostStore: CostHistoryStore(provider: .devin) { _ in [:] },
            defaultProvider: .devin
        )

        XCTAssertTrue(view.showsToggle)
        XCTAssertEqual(view.tabs, [.provider(.claude), .provider(.devin)])
    }

    func testAllTabCombinesDevinCostsWithClaude() async {
        let claudeCosts = CostHistoryStore { _ in
            ["2026-09-27": ["claude-fable-5": ModelTokenTotals(input: 100, requestCount: 1)]]
        }
        let devinCosts = CostHistoryStore(provider: .devin) { _ in
            ["2026-09-27": ["swe-1-7": ModelTokenTotals(input: 100, requestCount: 1)]]
        }
        await claudeCosts.refresh()
        await devinCosts.refresh()
        let view = UsageDetailView(
            claudeUsage: ClaudeUsageService(), codexUsage: CodexUsageService(),
            devinUsage: DevinUsageService(readUsage: { _ in nil }),
            costStore: claudeCosts,
            codexCostStore: CostHistoryStore(provider: .codex) { _ in [:] },
            devinCostStore: devinCosts,
            defaultProvider: .devin
        )

        XCTAssertEqual(view.tabs, [.provider(.claude), .provider(.devin), .all])
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

    // MARK: - Claude accounts

    private func usageView(
        claude: ClaudeUsageService,
        accounts: [UsageDetailView.ClaudeAccountUsage],
        initialAccountId: String? = nil
    ) -> UsageDetailView {
        UsageDetailView(
            claudeUsage: claude, codexUsage: CodexUsageService(), devinUsage: DevinUsageService(readUsage: { _ in nil }),
            costStore: CostHistoryStore { _ in [:] },
            codexCostStore: CostHistoryStore(provider: .codex) { _ in [:] },
            devinCostStore: CostHistoryStore(provider: .devin) { _ in [:] },
            defaultProvider: .claude,
            claudeAccounts: accounts,
            initialClaudeAccountId: initialAccountId
        )
    }

    private func account(_ name: String, sessionPercent: Double?, cost: CostHistoryStore? = nil) -> UsageDetailView.ClaudeAccountUsage {
        let usage = ClaudeUsageService()
        usage.currentUsage = sessionPercent.map { QuotaPeriod(utilization: $0, resetDate: nil) }
        return UsageDetailView.ClaudeAccountUsage(id: name, name: name, color: .orange, usage: usage, cost: cost)
    }

    private static let workSpendNanos = 2_000_000_000
    private static let personalSpendNanos = 5_000_000_000
    private static let workSpendUSD = 2.0
    private static let personalSpendUSD = 5.0
    private static let bothAccountsSpendUSD = 7.0

    /// A cost history that spent `nanos` today.
    private func costStore(spendingTodayNanos nanos: Int) async -> CostHistoryStore {
        let today = DailyCostReport.dayKey(Date(), calendar: .autoupdatingCurrent)
        let store = CostHistoryStore { _ in
            [today: ["claude-opus-4": ModelTokenTotals(input: 10, costNanos: nanos, requestCount: 1, pricedCount: 1)]]
        }
        await store.refresh()
        return store
    }

    private func workAndPersonalWithSpend(initialAccountId: String?) async -> UsageDetailView {
        usageView(
            claude: ClaudeUsageService(),
            accounts: [
                account("Work", sessionPercent: 3, cost: await costStore(spendingTodayNanos: Self.workSpendNanos)),
                account("Personal", sessionPercent: 50, cost: await costStore(spendingTodayNanos: Self.personalSpendNanos)),
            ],
            initialAccountId: initialAccountId
        )
    }

    func testClaudeChartShowsThePickedAccountsSpend() async throws {
        let view = await workAndPersonalWithSpend(initialAccountId: "Personal")

        XCTAssertEqual(try XCTUnwrap(view.claudeCostReport).windowCostUSD, Self.personalSpendUSD, accuracy: 1e-9)
    }

    func testAllAccountsChartAddsUpEveryAccountsSpend() async throws {
        let view = await workAndPersonalWithSpend(initialAccountId: UsageDetailView.allClaudeAccountsId)

        XCTAssertEqual(try XCTUnwrap(view.claudeCostReport).windowCostUSD, Self.bothAccountsSpendUSD, accuracy: 1e-9)
    }

    func testAllAccountsChartStacksOneSegmentPerAccount() async throws {
        let view = await workAndPersonalWithSpend(initialAccountId: UsageDetailView.allClaudeAccountsId)

        XCTAssertEqual(try XCTUnwrap(view.claudeCostReport?.entries.last).segments.map(\.models), [["Work"], ["Personal"]])
    }

    func testAllAccountsIsShownWhenPicked() async {
        let view = await workAndPersonalWithSpend(initialAccountId: UsageDetailView.allClaudeAccountsId)

        XCTAssertTrue(view.isShowingAllClaudeAccounts)
    }

    func testAllAccountsIsIgnoredWithOneAccount() async {
        let view = usageView(
            claude: ClaudeUsageService(),
            accounts: [account("Work", sessionPercent: 3, cost: await costStore(spendingTodayNanos: Self.workSpendNanos))],
            initialAccountId: UsageDetailView.allClaudeAccountsId
        )

        XCTAssertFalse(view.isShowingAllClaudeAccounts)
    }

    func testOneAccountsChartShowsItsOwnSpendOnly() async throws {
        let view = await workAndPersonalWithSpend(initialAccountId: "Work")

        XCTAssertEqual(try XCTUnwrap(view.claudeCostReport).windowCostUSD, Self.workSpendUSD, accuracy: 1e-9)
    }

    func testAllTabCanExpandClaudeWithTwoAccountsWithSpend() async {
        let view = await workAndPersonalWithSpend(initialAccountId: nil)

        XCTAssertTrue(view.canExpandClaudeAccounts)
    }

    func testAllTabCannotExpandClaudeWhenOnlyOneAccountHasSpend() async {
        let view = usageView(
            claude: ClaudeUsageService(),
            accounts: [
                account("Work", sessionPercent: nil, cost: CostHistoryStore { _ in [:] }),
                account("Personal", sessionPercent: nil, cost: await costStore(spendingTodayNanos: Self.personalSpendNanos)),
            ]
        )

        XCTAssertFalse(view.canExpandClaudeAccounts)
    }

    func testAllTabExpandedClaudeListsEveryAccountWithSpendInOrder() async {
        let view = await workAndPersonalWithSpend(initialAccountId: nil)

        XCTAssertEqual(view.claudeAccountsWithSpend.map(\.name), ["Work", "Personal"])
    }

    func testAllTabChartStacksOneClaudeSegmentWhileCollapsed() async throws {
        let view = await workAndPersonalWithSpend(initialAccountId: nil)

        let today = try XCTUnwrap(view.allTabCostReport(splittingClaudeAccounts: false)?.entries.last)
        XCTAssertEqual(today.segments.map(\.models), [[CostProvider.claude.rawValue]])
    }

    func testAllTabChartStacksOneSegmentPerClaudeAccountWhileExpanded() async throws {
        let view = await workAndPersonalWithSpend(initialAccountId: nil)

        let today = try XCTUnwrap(view.allTabCostReport(splittingClaudeAccounts: true)?.entries.last)
        XCTAssertEqual(today.segments.map(\.models), [["Work"], ["Personal"]])
    }

    func testAllTabChartKeepsTheSameTotalWhileExpanded() async throws {
        let view = await workAndPersonalWithSpend(initialAccountId: nil)

        let report = try XCTUnwrap(view.allTabCostReport(splittingClaudeAccounts: true))
        XCTAssertEqual(report.windowCostUSD, Self.bothAccountsSpendUSD, accuracy: 1e-9)
    }

    func testAllTabExpandedClaudeLeavesOutAccountsWithoutSpend() async {
        let view = usageView(
            claude: ClaudeUsageService(),
            accounts: [
                account("Work", sessionPercent: nil, cost: CostHistoryStore { _ in [:] }),
                account("Personal", sessionPercent: nil, cost: await costStore(spendingTodayNanos: Self.personalSpendNanos)),
                account("Side", sessionPercent: nil, cost: nil),
            ]
        )

        XCTAssertEqual(view.claudeAccountsWithSpend.map(\.name), ["Personal"])
    }

    func testClaudeHasDataWhenOnlyAnotherAccountHasSpend() async {
        let view = usageView(
            claude: ClaudeUsageService(),
            accounts: [
                account("Work", sessionPercent: nil, cost: CostHistoryStore { _ in [:] }),
                account("Personal", sessionPercent: nil, cost: await costStore(spendingTodayNanos: Self.personalSpendNanos)),
            ]
        )

        XCTAssertTrue(view.claudeHasData)
    }

    func testClaudeTabStartsOnTheGivenAccount() {
        let view = usageView(
            claude: ClaudeUsageService(),
            accounts: [account("Work", sessionPercent: 3), account("Personal", sessionPercent: 50)],
            initialAccountId: "Personal"
        )

        XCTAssertEqual(view.periods.first?.percentUsed, 50)
    }

    func testClaudeTabWithoutAStartingAccountShowsTheAccountThePickerHighlights() {
        let claude = ClaudeUsageService()
        claude.currentUsage = QuotaPeriod(utilization: 12, resetDate: nil)
        let view = usageView(claude: claude, accounts: [account("Work", sessionPercent: 3), account("Personal", sessionPercent: 50)])

        XCTAssertEqual(view.periods.first?.percentUsed, 3)
    }

    func testClaudeTabWithoutAccountsShowsTheGivenService() {
        let claude = ClaudeUsageService()
        claude.currentUsage = QuotaPeriod(utilization: 12, resetDate: nil)
        let view = usageView(claude: claude, accounts: [])

        XCTAssertEqual(view.periods.first?.percentUsed, 12)
    }

    func testAccountPickerShowsWithTwoClaudeAccounts() {
        let view = usageView(
            claude: ClaudeUsageService(),
            accounts: [account("Work", sessionPercent: 3), account("Personal", sessionPercent: 50)]
        )

        XCTAssertTrue(view.showsClaudeAccountPicker)
    }

    func testAccountPickerIsHiddenWithOneClaudeAccount() {
        let view = usageView(claude: ClaudeUsageService(), accounts: [account("Work", sessionPercent: 3)])

        XCTAssertFalse(view.showsClaudeAccountPicker)
    }

    func testClaudeHasDataWhenOnlyAnotherAccountHasUsage() {
        let view = usageView(
            claude: ClaudeUsageService(),
            accounts: [account("Work", sessionPercent: nil), account("Personal", sessionPercent: 50)]
        )

        XCTAssertTrue(view.claudeHasData)
    }
}
