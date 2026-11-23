import SwiftUI

struct UsageDetailView: View {
    let claudeUsage: ClaudeUsageService
    let codexUsage: CodexUsageService
    let devinUsage: DevinUsageService
    let costStore: CostHistoryStore
    let codexCostStore: CostHistoryStore
    let devinCostStore: CostHistoryStore
    let defaultProvider: AgentProvider
    /// Every Claude account running notchi; with two or more, the Claude tab can switch between them.
    let claudeAccounts: [ClaudeAccountUsage]

    struct ClaudeAccountUsage: Identifiable {
        let id: String
        let name: String
        let color: Color
        let usage: ClaudeUsageService
        /// Nil until the account's cost history has been set up.
        let cost: CostHistoryStore?

        init(id: String, name: String, color: Color, usage: ClaudeUsageService, cost: CostHistoryStore? = nil) {
            self.id = id
            self.name = name
            self.color = color
            self.usage = usage
            self.cost = cost
        }
    }

    /// Picks every Claude account at once: one chart stacked by account, without usage rows.
    static let allClaudeAccountsId = "notchi.allClaudeAccounts"

    enum UsageTab: Hashable {
        case provider(AgentProvider)
        case all
    }

    @State private var selectedTab: UsageTab
    @State private var selectedClaudeAccountId: String?
    @AppStorage(AppSettings.showGrassIslandKey) private var showGrassIsland = true
    @Environment(\.panelScale) private var panelScale

    init(
        claudeUsage: ClaudeUsageService,
        codexUsage: CodexUsageService,
        devinUsage: DevinUsageService,
        costStore: CostHistoryStore,
        codexCostStore: CostHistoryStore,
        devinCostStore: CostHistoryStore,
        defaultProvider: AgentProvider,
        claudeAccounts: [ClaudeAccountUsage] = [],
        initialClaudeAccountId: String? = nil
    ) {
        self.claudeUsage = claudeUsage
        self.codexUsage = codexUsage
        self.devinUsage = devinUsage
        self.costStore = costStore
        self.codexCostStore = codexCostStore
        self.devinCostStore = devinCostStore
        self.defaultProvider = defaultProvider
        self.claudeAccounts = claudeAccounts
        _selectedClaudeAccountId = State(initialValue: initialClaudeAccountId)
        _selectedTab = State(initialValue: .provider(defaultProvider))
    }

    var claudeHasData: Bool {
        claudeUsage.hasUsageData || claudeAccounts.contains { $0.usage.hasUsageData }
            || claudeCostStores.contains { !$0.buckets.isEmpty }
    }

    var showsClaudeAccountPicker: Bool {
        claudeAccounts.count > 1
    }

    var isShowingAllClaudeAccounts: Bool {
        showsClaudeAccountPicker && selectedClaudeAccountId == Self.allClaudeAccountsId
    }

    /// The Claude spend that counts: every account's running notchi, else the default one's.
    private var claudeCostStores: [CostHistoryStore] {
        claudeAccounts.isEmpty ? [costStore] : claudeAccounts.compactMap(\.cost)
    }

    private var costWindow: (start: Date, today: Date) {
        let calendar = costStore.calendar
        let today = Date()
        let startOfToday = calendar.startOfDay(for: today)
        let start = calendar.date(byAdding: .day, value: -(costStore.windowDays - 1), to: startOfToday) ?? startOfToday
        return (start, today)
    }

    /// Every Claude account's spend, one stack per account; nil while no account has a cost history.
    var claudeAccountsCostReport: DailyCostReport? {
        let series = claudeAccounts.compactMap { account in account.cost.map { (key: account.id, buckets: $0.buckets) } }
        guard !series.isEmpty else { return nil }
        let window = costWindow
        return DailyCostReport.combined(
            series, provider: .claude, windowStart: window.start, today: window.today, calendar: costStore.calendar)
    }

    private var claudeAccountSeries: [CostSeries] {
        claudeAccounts.map { CostSeries(key: $0.id, name: $0.name, color: $0.color) }
    }

    /// The Claude tab's chart: the picked account's spend, or every account's under All.
    var claudeCostReport: DailyCostReport? {
        if isShowingAllClaudeAccounts { return claudeAccountsCostReport }
        guard let selectedClaudeAccount else { return costStore.report }
        return selectedClaudeAccount.cost?.report
    }

    /// All Claude spend, for the tab comparing providers.
    private var claudeTotalCostReport: DailyCostReport? {
        claudeAccountsCostReport ?? claudeCostStores.first?.report
    }

    private var claudeCostBuckets: DayModelBuckets {
        let stores = claudeCostStores
        return stores.count == 1 ? stores[0].buckets : DailyCostReport.merged(stores.map(\.buckets))
    }

    /// The picked account, else the first one listed, which the picker then shows as picked.
    private var selectedClaudeAccount: ClaudeAccountUsage? {
        claudeAccounts.first { $0.id == selectedClaudeAccountId } ?? claudeAccounts.first
    }

    /// The Claude usage the tab shows: the picked account's, else the one this view was given.
    private var selectedClaudeUsage: ClaudeUsageService {
        selectedClaudeAccount?.usage ?? claudeUsage
    }

    static func claudePeriods(_ usage: ClaudeUsageService) -> [UsagePeriodDisplay] {
        let stale = usage.isUsageStale
        let heldOver = usage.isWeeklyUsageHeldOver
        return [
            UsageMetrics.periodDisplay(title: String(localized: "Session"), usage: usage.currentUsage, isStale: stale),
            UsageMetrics.periodDisplay(title: String(localized: "Weekly"), usage: usage.currentWeeklyUsage, isStale: heldOver),
            UsageMetrics.periodDisplay(
                title: usage.currentModelUsageName ?? String(localized: "Model"),
                usage: usage.currentModelUsage,
                isStale: heldOver
            ),
        ].compactMap { $0 }
    }

    var codexHasData: Bool {
        codexUsage.hasUsageData || !codexCostStore.buckets.isEmpty
    }

    var devinHasData: Bool {
        devinUsage.hasUsageData || !devinCostStore.buckets.isEmpty
    }

    private var costsByProvider: [(provider: AgentProvider, buckets: DayModelBuckets, report: DailyCostReport?)] {
        [
            (.claude, claudeCostBuckets, claudeTotalCostReport),
            (.codex, codexCostStore.buckets, codexCostStore.report),
            (.devin, devinCostStore.buckets, devinCostStore.report),
        ]
    }

    private var providersWithData: [AgentProvider] {
        Self.providersWithData(claudeHasData: claudeHasData, codexHasData: codexHasData, devinHasData: devinHasData)
    }

    var showsToggle: Bool {
        providersWithData.count > 1
    }

    private var showsAllTab: Bool {
        costsByProvider.filter { !$0.buckets.isEmpty }.count > 1
    }

    var tabs: [UsageTab] {
        providersWithData.map(UsageTab.provider) + (showsAllTab ? [.all] : [])
    }

    private var resolvedTab: UsageTab {
        switch selectedTab {
        case .all where showsAllTab:
            return .all
        case .all:
            return .provider(Self.resolvedProvider(
                selected: defaultProvider,
                claudeHasData: claudeHasData,
                codexHasData: codexHasData,
                devinHasData: devinHasData
            ))
        case .provider(let provider):
            return .provider(Self.resolvedProvider(
                selected: provider,
                claudeHasData: claudeHasData,
                codexHasData: codexHasData,
                devinHasData: devinHasData
            ))
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
        codexHasData: Bool,
        devinHasData: Bool = false
    ) -> AgentProvider {
        let withData = providersWithData(claudeHasData: claudeHasData, codexHasData: codexHasData, devinHasData: devinHasData)
        guard let firstWithData = withData.first, !withData.contains(selected) else {
            return selected
        }
        return firstWithData
    }

    private static func providersWithData(claudeHasData: Bool, codexHasData: Bool, devinHasData: Bool) -> [AgentProvider] {
        [(AgentProvider.claude, claudeHasData), (.codex, codexHasData), (.devin, devinHasData)]
            .filter(\.1)
            .map(\.0)
    }

    var periods: [UsagePeriodDisplay] {
        switch resolvedProvider {
        case .claude:
            return Self.claudePeriods(selectedClaudeUsage)
        case .codex:
            let stale = codexUsage.isUsageStale
            return [
                UsageMetrics.periodDisplay(title: String(localized: "Session"), usage: codexUsage.currentUsage, isStale: stale),
                UsageMetrics.periodDisplay(title: String(localized: "Weekly"), usage: codexUsage.currentWeeklyUsage, isStale: stale),
                UsageMetrics.periodDisplay(title: String(localized: "Reviews"), usage: codexUsage.currentReviewsUsage, isStale: stale),
            ].compactMap { $0 }
        case .devin:
            return [
                UsageMetrics.periodDisplay(title: String(localized: "Daily"), usage: devinUsage.currentUsage, isStale: devinUsage.isUsageStale),
                UsageMetrics.periodDisplay(title: String(localized: "Weekly"), usage: devinUsage.currentWeeklyUsage, isStale: devinUsage.isUsageStale),
            ].compactMap { $0 }
        }
    }

    private var codexCreditsUSD: Double? {
        resolvedProvider == .codex && !codexUsage.hasUnlimitedCredits ? codexUsage.currentExtraCreditsUSD : nil
    }

    private var extraUsage: ExtraUsageDisplay? {
        resolvedProvider == .claude
            ? UsageMetrics.extraUsageDisplay(selectedClaudeUsage.currentExtraUsage)
            : nil
    }

    private var combinedReport: DailyCostReport? {
        guard showsAllTab else { return nil }
        let window = costWindow
        return DailyCostReport.combinedAcrossProviders(
            [(.claude, claudeCostBuckets), (.codex, codexCostStore.buckets), (.devin, devinCostStore.buckets)],
            windowStart: window.start, today: window.today, calendar: costStore.calendar)
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
            CostDashboardView(
                report: costReport(for: provider),
                sizingPeerReports: (costsByProvider.filter { $0.provider != provider }.map(\.report)
                    + [combinedReport]).compactMap { $0 },
                series: provider == .claude && isShowingAllClaudeAccounts ? claudeAccountSeries : [],
                chartHeight: chartHeight)
        case .all:
            CostDashboardView(
                report: combinedReport,
                sizingPeerReports: costsByProvider.compactMap(\.report),
                series: CostSeries.providers,
                chartHeight: chartHeight)
        }
    }

    static func usesTwoColumnLayout(rowCount: Int, showGrassIsland: Bool, panelScale: CGFloat) -> Bool {
        guard panelScale <= 1 else { return false }
        return rowCount >= 3 && showGrassIsland
    }

    var showsUnlimitedCredits: Bool {
        resolvedProvider == .codex && codexUsage.hasUnlimitedCredits
    }

    var showsStaleUnlimitedCredits: Bool {
        showsUnlimitedCredits && codexUsage.isUsageStale
    }

    var showsDevinNoQuotaPlan: Bool {
        resolvedProvider == .devin && devinUsage.hasNoQuota
    }

    private var usageRowCount: Int {
        periods.count + (extraUsage == nil ? 0 : 1) + (codexCreditsUSD == nil ? 0 : 1)
            + (showsUnlimitedCredits ? 1 : 0) + (showsDevinNoQuotaPlan ? 1 : 0)
    }

    @ViewBuilder private var usageRows: some View {
        ForEach(periods, id: \.title) { period in
            UsagePeriodRowView(display: period)
        }

        if let extraUsage {
            ExtraUsageRowView(display: extraUsage)
        }

        if showsUnlimitedCredits {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("No spending cap")
                    .panelFont(size: 14, weight: .semibold)
                    .foregroundColor(TerminalColors.primaryText)
                if showsStaleUnlimitedCredits {
                    Text("stale data")
                        .panelFont(size: 10)
                        .foregroundColor(TerminalColors.secondaryText)
                }
            }
        }

        if let codexCreditsUSD {
            CodexCreditsRowView(remainingUSD: codexCreditsUSD)
        }

        if showsDevinNoQuotaPlan {
            DevinNoQuotaPlanRowView(planName: devinUsage.planName, isStale: devinUsage.isUsageStale)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing(showGrassIsland: showGrassIsland)) {
            header
                .padding(.bottom, -4)

            costDashboard
                .padding(.bottom, showGrassIsland ? -4 : 2)

            switch resolvedTab {
            case .provider(.claude) where isShowingAllClaudeAccounts:
                claudeAccountBreakdown
            case .provider:
                usageGrid(rowCount: usageRowCount) { usageRows }
            case .all:
                providerBreakdown
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func usageGrid<Rows: View>(rowCount: Int, @ViewBuilder rows: () -> Rows) -> some View {
        if Self.usesTwoColumnLayout(rowCount: rowCount, showGrassIsland: showGrassIsland, panelScale: panelScale) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 14, alignment: .topLeading),
                    GridItem(.flexible(), alignment: .topLeading),
                ],
                spacing: 12
            ) {
                rows()
            }
        } else {
            rows()
        }
    }

    private static let accountDotSize: CGFloat = 8
    private static let accountDotHitSize: CGFloat = 16
    private static let selectedAccountRingWidth: CGFloat = 1.5
    private static let selectedAccountRingInset: CGFloat = -2.5

    /// Sits on the header line, so switching accounts never changes the page's height.
    private var claudeAccountPicker: some View {
        HStack(spacing: 6) {
            // The highlighted All chip already says it, so no label then.
            if !isShowingAllClaudeAccounts, let selected = selectedClaudeAccount {
                Text(selected.name)
                    .panelFont(size: 11, weight: .semibold)
                    .foregroundColor(TerminalColors.secondaryText)
                    .lineLimit(1)
            }
            HStack(spacing: 2) {
                Button(action: { selectedClaudeAccountId = Self.allClaudeAccountsId }) {
                    Text("All")
                        .panelFont(size: 10, weight: .semibold)
                        .foregroundColor(isShowingAllClaudeAccounts ? TerminalColors.primaryText : TerminalColors.dimmedText)
                        .padding(.horizontal, 4)
                        .frame(height: Self.accountDotHitSize * panelScale)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isShowingAllClaudeAccounts ? TerminalColors.hoverBackground : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "All accounts"))
                .accessibilityLabel(String(localized: "All accounts"))
                .accessibilityAddTraits(isShowingAllClaudeAccounts ? .isSelected : [])
                ForEach(claudeAccounts) { account in
                    let isSelected = !isShowingAllClaudeAccounts && account.id == selectedClaudeAccount?.id
                    Button(action: { selectedClaudeAccountId = account.id }) {
                        Circle()
                            .fill(account.color)
                            .frame(width: Self.accountDotSize * panelScale, height: Self.accountDotSize * panelScale)
                            .overlay {
                                if isSelected {
                                    Circle()
                                        .stroke(TerminalColors.primaryText, lineWidth: Self.selectedAccountRingWidth)
                                        .padding(Self.selectedAccountRingInset)
                                }
                            }
                            .frame(width: Self.accountDotHitSize * panelScale, height: Self.accountDotHitSize * panelScale)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(account.name)
                    .accessibilityLabel(account.name)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
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

            if resolvedTab == .provider(.claude), showsClaudeAccountPicker {
                claudeAccountPicker
            }
        }
    }

    @ViewBuilder private var providerBreakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(costsByProvider.filter { !$0.buckets.isEmpty }, id: \.provider) { entry in
                providerBreakdownRow(
                    name: entry.provider.displayName,
                    color: entry.provider == .claude ? TerminalColors.claudeOrangeDeep : entry.provider.accentColor,
                    report: entry.report)
            }
        }
        .padding(.top, 5)
    }

    /// Scrolls within the panel's fixed height, which only fits a handful of accounts.
    @ViewBuilder private var claudeAccountBreakdown: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(claudeAccounts) { account in
                    providerBreakdownRow(name: account.name, color: account.color, report: account.cost?.report)
                }
            }
            .padding(.top, 5)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func costReport(for provider: AgentProvider) -> DailyCostReport? {
        switch provider {
        case .claude: claudeCostReport
        case .codex: codexCostStore.report
        case .devin: devinCostStore.report
        }
    }

    @ViewBuilder private func providerBreakdownRow(
        name: String, color: Color, report: DailyCostReport?) -> some View
    {
        if let report {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(name)
                    .panelFont(size: 13, weight: .semibold)
                    .foregroundColor(TerminalColors.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Self.breakdownDetail(report))
                    .panelFont(size: 11)
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
            ForEach(tabs, id: \.self) { tab in
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

struct DevinNoQuotaPlanRowView: View {
    let planName: String?
    let isStale: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let planName {
                Text("\(planName) plan")
                    .panelFont(size: 14, weight: .semibold)
                    .foregroundColor(TerminalColors.secondaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            Group {
                if isStale {
                    Text("stale data")
                } else {
                    Text("No daily or weekly quota")
                }
            }
                .panelFont(size: 10)
                .foregroundColor(TerminalColors.dimmedText)
                .lineLimit(1)
        }
    }
}

struct ExtraUsageRowView: View {
    let display: ExtraUsageDisplay

    var body: some View {
        let color = TerminalColors.usageColor(forPercentUsed: display.percentUsed)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Extra usage")
                    .panelFont(size: 14, weight: .semibold)
                    .foregroundColor(TerminalColors.primaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(verbatim: "\(Self.currency(display.usedUSD)) / \(Self.currency(display.monthlyLimitUSD))")
                    .panelFont(size: 10)
                    .foregroundColor(TerminalColors.secondaryText)
                    .lineLimit(1)
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

    static func currency(_ value: Double) -> String {
        let fractionDigits = value == value.rounded() ? 0 : 2
        return value.formatted(
            .currency(code: "USD")
                .locale(Locale(identifier: "en_US"))
                .precision(.fractionLength(fractionDigits))
        )
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
