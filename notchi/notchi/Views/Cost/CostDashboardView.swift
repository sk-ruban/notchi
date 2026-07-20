import Charts
import SwiftUI

enum CostStatFormatter {
    private static let usdFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        f.currencyCode = "USD"
        f.currencySymbol = "$"
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    static func tokens(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName))
    }

    static func usd(_ amount: Double) -> String {
        usdFormatter.string(from: NSNumber(value: amount)) ?? String(format: "$%.2f", amount)
    }

    static func modelName(_ raw: String) -> String {
        var s = raw
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        if s.lowercased().hasPrefix("gpt") { return "GPT" + s.dropFirst(3) }
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        let parts = s.split(separator: "-").map(String.init)
        guard let family = parts.first, !family.isEmpty else { return raw }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? name : "\(name) \(version)"
    }
}

@MainActor
struct CostDashboardView: View {
    let store: CostHistoryStore
    var sizingPeerStore: CostHistoryStore?

    @State private var selected: DailyCostReport.DayEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let report = store.report {
                statsRow(report)
                chart(report)
                if report.entries.contains(where: { $0.requestCount > 0 && $0.pricedFraction < 1 }) {
                    Text("Some models lack pricing — cost is partial")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else if store.isScanning {
                ProgressView("Scanning usage…").font(.caption)
            } else {
                Text("No cost history yet").font(.caption).foregroundStyle(TerminalColors.dimmedText)
            }
        }
    }

    private static let statColumnWeights: [CGFloat] = [0.20, 0.19, 0.23, 0.19, 0.19]
    private static let statSpacing: CGFloat = 12
    private static let statValueBaseSize: CGFloat = 15

    private static func statItems(
        _ r: DailyCostReport,
        selected: DailyCostReport.DayEntry?
    ) -> [(title: String, value: String)] {
        [
            (
                selected.map { dayFormatter.string(from: $0.date) } ?? String(localized: "Today"),
                CostStatFormatter.usd(selected?.costUSD ?? r.todayCostUSD)
            ),
            (
                selected.map { String(localized: "\(dayFormatter.string(from: $0.date)) toks") } ?? String(localized: "Today's toks"),
                CostStatFormatter.tokens(selected?.totalTokens ?? r.todayTokens)
            ),
            (String(localized: "30d"), CostStatFormatter.usd(r.windowCostUSD)),
            (String(localized: "30d toks"), CostStatFormatter.tokens(r.windowTokens)),
            (
                String(localized: "Top model"),
                (selected.map(\.topModel) ?? r.topModel).map(CostStatFormatter.modelName) ?? "—"
            ),
        ]
    }

    @ViewBuilder private func statsRow(_ r: DailyCostReport) -> some View {
        let items = Self.statItems(r, selected: selected)
        let peerValues = sizingPeerStore?.report.map { Self.statItems($0, selected: nil).map(\.value) } ?? []
        GeometryReader { geo in
            let available = geo.size.width - Self.statSpacing * CGFloat(items.count - 1)
            let widths = Self.statColumnWeights.map { $0 * available }
            let valueSize = Self.fittedValueFontSize(
                valueSets: [items.map(\.value), peerValues],
                widths: widths
            )
            HStack(alignment: .top, spacing: Self.statSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    stat(item.title, item.value, valueSize: valueSize)
                        .frame(width: widths[index], alignment: .leading)
                }
            }
        }
        .frame(height: 34)
    }

    private static let statLayoutSafetyMargin: CGFloat = 2

    private static func fittedValueFontSize(valueSets: [[String]], widths: [CGFloat]) -> CGFloat {
        let pairs = valueSets.flatMap { Array(zip($0, widths)) }
        var size = statValueBaseSize
        while size > 8 {
            let font = NSFont.systemFont(ofSize: size, weight: .semibold)
            let fits = pairs.allSatisfy { value, width in
                (value as NSString).size(withAttributes: [.font: font]).width <= width - statLayoutSafetyMargin
            }
            if fits { return size }
            size -= 1
        }
        return size
    }

    private func stat(_ title: String, _ value: String, valueSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(TerminalColors.secondaryText)
                .lineLimit(1)
            Text(value).font(.system(size: valueSize, weight: .semibold))
                .foregroundStyle(TerminalColors.primaryText)
                .lineLimit(1)
        }
    }

    private func accent(_ provider: CostProvider) -> Color {
        provider == .codex ? TerminalColors.codexAccentDeep : TerminalColors.claudeOrangeDeep
    }
    private func peak(_ provider: CostProvider) -> Color {
        provider == .codex ? TerminalColors.codexAccent : TerminalColors.claudeOrange
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    private func barColor(for e: DailyCostReport.DayEntry, provider: CostProvider) -> Color {
        if let s = selected, s.id == e.id { return peak(provider) }
        return accent(provider)
    }

    private func nearest(to date: Date, in entries: [DailyCostReport.DayEntry]) -> DailyCostReport.DayEntry? {
        entries.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        })
    }

    @ViewBuilder private func chart(_ r: DailyCostReport) -> some View {
        Chart(r.entries) { e in
            BarMark(x: .value("Day", e.date, unit: .day), y: .value("Cost", e.costUSD))
                .foregroundStyle(barColor(for: e, provider: r.provider))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 105)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let x = location.x - geo[plotFrame].origin.x
                            if let date: Date = proxy.value(atX: x) {
                                selected = nearest(to: date, in: r.entries)
                            }
                        case .ended:
                            selected = nil
                        }
                    }
            }
        }
    }
}
