import SwiftUI

struct UsageDetailView: View {
    let claudeUsage: ClaudeUsageService
    let codexUsage: CodexUsageService
    let costStore: CostHistoryStore
    let codexCostStore: CostHistoryStore
    let defaultProvider: AgentProvider

    @State private var selectedProvider: AgentProvider
    @AppStorage(AppSettings.hideGrassIslandKey) private var hideGrassIsland = false

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
        _selectedProvider = State(initialValue: defaultProvider)
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

    private var resolvedProvider: AgentProvider {
        Self.resolvedProvider(
            selected: selectedProvider,
            claudeHasData: claudeHasData,
            codexHasData: codexHasData
        )
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
            let heldOver = stale || claudeUsage.isUsingHeadersFallback
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

    private var costDashboardStores: (store: CostHistoryStore, peer: CostHistoryStore) {
        switch resolvedProvider {
        case .claude: (costStore, codexCostStore)
        case .codex: (codexCostStore, costStore)
        }
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
        VStack(alignment: .leading, spacing: 10) {
            header
                .padding(.bottom, -4)

            CostDashboardView(
                store: costDashboardStores.store,
                sizingPeerStore: costDashboardStores.peer
            )
            .padding(.bottom, 2)

            if usageRowCount >= 3 && !hideGrassIsland {
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
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if showsToggle {
                providerToggle
            } else {
                Text(resolvedProvider.displayName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(TerminalColors.primaryText)
            }

            Spacer()
        }
    }

    private var providerToggle: some View {
        HStack(spacing: 4) {
            ForEach([AgentProvider.claude, .codex], id: \.self) { provider in
                Button(action: { selectedProvider = provider }) {
                    Text(provider.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(
                            resolvedProvider == provider
                                ? TerminalColors.primaryText
                                : TerminalColors.dimmedText
                        )
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(resolvedProvider == provider ? TerminalColors.hoverBackground : .clear)
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(TerminalColors.primaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
                if display.isStale {
                    Text("stale data")
                        .font(.system(size: 10))
                        .foregroundColor(TerminalColors.secondaryText)
                        .lineLimit(1)
                } else if let resetText = display.resetText {
                    Text(resetText)
                        .font(.system(size: 10))
                        .foregroundColor(TerminalColors.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("\(display.percentUsed)%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(TerminalColors.primaryText)
            UsageProgressBar(percentUsed: display.percentUsed, color: color)
            HStack {
                Text("\(Self.currency(display.usedCredits)) used")
                    .foregroundColor(TerminalColors.secondaryText)
                Spacer()
                Text("\(Self.currency(display.monthlyLimit)) limit")
                    .foregroundColor(TerminalColors.secondaryText)
            }
            .font(.system(size: 10))
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(TerminalColors.primaryText)
            HStack {
                Text(String(localized: "\(String(format: "$%.2f", remainingUSD)) remaining"))
                    .foregroundColor(TerminalColors.secondaryText)
                Spacer()
            }
            .font(.system(size: 10))
        }
    }
}
