import SwiftUI

struct UsageDetailView: View {
    let claudeUsage: ClaudeUsageService
    let codexUsage: CodexUsageService
    let costStore: CostHistoryStore
    let codexCostStore: CostHistoryStore
    let defaultProvider: AgentProvider

    enum UsageTab: Hashable {
        case provider(AgentProvider)
        case all
    }

    @State private var selectedTab: UsageTab
    @AppStorage(AppSettings.showGrassIslandKey) private var showGrassIsland = true
    @Environment(\.panelScale) private var panelScale

    init(
        claudeUsage: ClaudeUsageService,
        codexUsage: CodexUsageService,
        costStore: CostHistoryStore,
        codexCostStore: CostHistoryStore,
        defaultProvider: AgentProvider
    ) {
        self.claudeUsage = claudeUsage
        self.codexUsage = codexUsage
        self.costStore = costStore
        self.codexCostStore = codexCostStore
        self.defaultProvider = defaultProvider
        _selectedTab = State(initialValue: .provider(defaultProvider))
    }

    private var claudeHasData: Bool {
        claudeUsage.hasUsageData
    }

    private var codexHasData: Bool {
        codexUsage.hasUsageData
    }

    private var showsToggle: Bool {
        claudeHasData && codexHasData
    }

    private var resolvedTab: UsageTab {
        switch selectedTab {
        case .all where showsToggle:
            return .all
        case .all:
            return .provider(Self.resolvedProvider(
                selected: defaultProvider, claudeHasData: claudeHasData, codexHasData: codexHasData))
        case .provider(let provider):
            return .provider(Self.resolvedProvider(
                selected: provider, claudeHasData: claudeHasData, codexHasData: codexHasData))
        }
    }

    private var resolvedProvider: AgentProvider {
        switch resolvedTab {
        case .provider(let provider): provider
        case .all: defaultProvider
        }
    }

    static func resolvedProvider(
        selected: AgentProvider,
        claudeHasData: Bool,
        codexHasData: Bool
    ) -> AgentProvider {
        switch selected {
        case .claude where !claudeHasData && codexHasData: return .codex
        case .codex where !codexHasData && claudeHasData: return .claude
        default: return selected
        }
    }

    private var periods: [UsagePeriodDisplay] {
        switch resolvedProvider {
        case .claude:
            let stale = claudeUsage.isUsageStale
            let heldOver = claudeUsage.isWeeklyUsageHeldOver
            return [
                UsageMetrics.periodDisplay(title: String(localized: "Session"), usage: claudeUsage.currentUsage, isStale: stale),
                UsageMetrics.periodDisplay(title: String(localized: "Weekly"), usage: claudeUsage.currentWeeklyUsage, isStale: heldOver),
                UsageMetrics.periodDisplay(
                    title: claudeUsage.currentModelUsageName ?? String(localized: "Model"),
                    usage: claudeUsage.currentModelUsage,
                    isStale: heldOver
                ),
            ].compactMap { $0 }
        case .codex:
            let stale = codexUsage.isUsageStale
            return [
                UsageMetrics.periodDisplay(title: String(localized: "Session"), usage: codexUsage.currentUsage, isStale: stale),
                UsageMetrics.periodDisplay(title: String(localized: "Weekly"), usage: codexUsage.currentWeeklyUsage, isStale: stale),
                UsageMetrics.periodDisplay(title: String(localized: "Reviews"), usage: codexUsage.currentReviewsUsage, isStale: stale),
            ].compactMap { $0 }
        }
    }

    private var codexCreditsUSD: Double? {
        resolvedProvider == .codex ? codexUsage.currentExtraCreditsUSD : nil
    }

    private var extraUsage: ExtraUsageDisplay? {
        resolvedProvider == .claude
            ? UsageMetrics.extraUsageDisplay(claudeUsage.currentExtraUsage)
            : nil
    }

    private var combinedReport: DailyCostReport? {
        guard showsToggle else { return nil }
        let calendar = costStore.calendar
        let today = Date()
        let windowStart = calendar.date(
            byAdding: .day, value: -(costStore.windowDays - 1),
            to: calendar.startOfDay(for: today))!
        return DailyCostReport.combinedAcrossProviders(
            [(.claude, costStore.buckets), (.codex, codexCostStore.buckets)],
            windowStart: windowStart, today: today, calendar: calendar)
    }

    static func chartHeight(showGrassIsland: Bool) -> CGFloat {
        showGrassIsland ? CostDashboardView.defaultChartHeight : 150
    }

    static func sectionSpacing(showGrassIsland: Bool) -> CGFloat {
        showGrassIsland ? 10 : 15
    }

    @ViewBuilder private var costDashboard: some View {
        let chartHeight = Self.chartHeight(showGrassIsland: showGrassIsland)
        switch resolvedTab {
        case .provider(let provider):
            let stores = provider == .codex
                ? (main: codexCostStore, peer: costStore)
                : (main: costStore, peer: codexCostStore)
            CostDashboardView(
                report: stores.main.report,
                sizingPeerReports: [stores.peer.report, combinedReport].compactMap { $0 },
                chartHeight: chartHeight)
        case .all:
            CostDashboardView(
                report: combinedReport,
                sizingPeerReports: [costStore.report, codexCostStore.report].compactMap { $0 },
                combinesProviders: true,
                chartHeight: chartHeight)
        }
    }

    static func usesTwoColumnLayout(rowCount: Int, showGrassIsland: Bool, panelScale: CGFloat) -> Bool {
        guard panelScale <= 1 else { return false }
        return rowCount >= 3 && showGrassIsland
    }

    private var usageRowCount: Int {
        periods.count + (extraUsage == nil ? 0 : 1) + (codexCreditsUSD == nil ? 0 : 1)
    }

    @ViewBuilder private var usageRows: some View {
        ForEach(periods, id: \.title) { period in
            UsagePeriodRowView(display: period)
        }

        if let extraUsage {
            ExtraUsageRowView(display: extraUsage)
        }

        if let codexCreditsUSD {
            CodexCreditsRowView(remainingUSD: codexCreditsUSD)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing(showGrassIsland: showGrassIsland)) {
            header
                .padding(.bottom, -4)

            costDashboard
                .padding(.bottom, showGrassIsland ? -4 : 2)

            if case .provider = resolvedTab {
                if Self.usesTwoColumnLayout(
                    rowCount: usageRowCount,
                    showGrassIsland: showGrassIsland,
                    panelScale: panelScale
                ) {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 14, alignment: .topLeading),
                            GridItem(.flexible(), alignment: .topLeading),
                        ],
                        spacing: 12
                    ) {
                        usageRows
                    }
                } else {
                    usageRows
                }
            } else {
                providerBreakdown
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if showsToggle {
                providerToggle
            } else {
                Text(resolvedProvider.displayName)
                    .panelFont(size: 16, weight: .bold)
                    .foregroundColor(TerminalColors.primaryText)
            }

            Spacer()
        }
    }

    @ViewBuilder private var providerBreakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            providerBreakdownRow(
                name: AgentProvider.claude.displayName,
                color: TerminalColors.claudeOrangeDeep,
                report: costStore.report)
            providerBreakdownRow(
                name: AgentProvider.codex.displayName,
                color: TerminalColors.codexAccent,
                report: codexCostStore.report)
        }
        .padding(.top, 2)
    }

    @ViewBuilder private func providerBreakdownRow(
        name: String, color: Color, report: DailyCostReport?) -> some View
    {
        if let report {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(name)
                    .panelFont(size: 12, weight: .semibold)
                    .foregroundColor(TerminalColors.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Self.breakdownDetail(report))
                    .panelFont(size: 10)
                    .foregroundColor(TerminalColors.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    private static func breakdownDetail(_ report: DailyCostReport) -> String {
        var parts = [
            CostStatFormatter.usd(report.windowCostUSD),
            String(localized: "\(CostStatFormatter.tokens(report.windowTokens)) toks"),
        ]
        if let topModel = report.topModel {
            parts.append(CostStatFormatter.modelName(topModel))
        }
        return parts.joined(separator: " · ")
    }

    private static func tabTitle(_ tab: UsageTab) -> String {
        switch tab {
        case .provider(let provider): provider.displayName
        case .all: String(localized: "All")
        }
    }

    private var providerToggle: some View {
        HStack(spacing: 4) {
            ForEach([UsageTab.provider(.claude), .provider(.codex), .all], id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    Text(Self.tabTitle(tab))
                        .panelFont(size: 14, weight: .semibold)
                        .foregroundColor(
                            resolvedTab == tab
                                ? TerminalColors.primaryText
                                : TerminalColors.dimmedText
                        )
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(resolvedTab == tab ? TerminalColors.hoverBackground : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, -6)
    }
}

private struct UsageProgressBar: View {
    let percentUsed: Int
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(TerminalColors.subtleBackground)
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: geometry.size.width * Double(min(max(percentUsed, 0), 100)) / 100)
            }
        }
        .frame(height: 5)
    }
}

struct UsagePeriodRowView: View {
    let display: UsagePeriodDisplay

    var body: some View {
        let color = display.isStale
            ? TerminalColors.dimmedText
            : TerminalColors.usageColor(forPercentUsed: display.percentUsed)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(display.title)
                    .panelFont(size: 14, weight: .semibold)
                    .foregroundColor(TerminalColors.primaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
                if display.isStale {
                    Text("stale data")
                        .panelFont(size: 10)
                        .foregroundColor(TerminalColors.secondaryText)
                        .lineLimit(1)
                } else if let resetText = display.resetText {
                    Text(resetText)
                        .panelFont(size: 10)
                        .foregroundColor(TerminalColors.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("\(display.percentUsed)%")
                    .panelFont(size: 11, weight: .semibold, design: .monospaced)
                    .foregroundColor(color)
                    .lineLimit(1)
                    .fixedSize()
            }
            UsageProgressBar(percentUsed: display.percentUsed, color: color)
        }
    }
}

struct ExtraUsageRowView: View {
    let display: ExtraUsageDisplay

    var body: some View {
        let color = TerminalColors.usageColor(forPercentUsed: display.percentUsed)
        VStack(alignment: .leading, spacing: 7) {
            Text("Extra usage")
                .panelFont(size: 14, weight: .semibold)
                .foregroundColor(TerminalColors.primaryText)
            UsageProgressBar(percentUsed: display.percentUsed, color: color)
            HStack {
                Text("\(Self.currency(display.usedCredits)) used")
                    .foregroundColor(TerminalColors.secondaryText)
                Spacer()
                Text("\(Self.currency(display.monthlyLimit)) limit")
                    .foregroundColor(TerminalColors.secondaryText)
            }
            .panelFont(size: 10)
        }
    }

    static func currency(_ value: Double) -> String {
        if value == value.rounded() {
            return "$\(Int(value))"
        }
        return String(format: "$%.2f", value)
    }
}

struct CodexCreditsRowView: View {
    let remainingUSD: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Extra usage")
                .panelFont(size: 14, weight: .semibold)
                .foregroundColor(TerminalColors.primaryText)
            HStack {
                Text(String(localized: "\(String(format: "$%.2f", remainingUSD)) remaining"))
                    .foregroundColor(TerminalColors.secondaryText)
                Spacer()
            }
            .panelFont(size: 10)
        }
    }
}
