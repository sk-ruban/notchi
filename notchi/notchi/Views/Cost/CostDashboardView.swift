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

    private static let gptPrefix = "GPT-"
    private static let longestPrefixedGptName = "GPT-5.5"

    static func modelName(_ raw: String) -> String {
        var s = raw
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        if s.lowercased().hasPrefix("gpt") {
            let named = "GPT" + s.dropFirst(3)
            guard named.count > longestPrefixedGptName.count, named.hasPrefix(gptPrefix) else {
                return named
            }
            return String(named.dropFirst(gptPrefix.count))
        }
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

    private static let modelSizingReference = "Opus 4.8"

    static func sizingValueSets(_ r: DailyCostReport) -> [[String]] {
        let unselected = statItems(r, selected: nil).map(\.value)
        var reference = unselected
        reference[reference.count - 1] = modelSizingReference

        let hoverStates = r.entries
            .filter { $0.requestCount > 0 }
            .map { statItems(r, selected: $0).map(\.value) }

        return [unselected, reference] + hoverStates
    }

    @ViewBuilder private func statsRow(_ r: DailyCostReport) -> some View {
        let items = Self.statItems(r, selected: selected)
        let peerValues = sizingPeerStore?.report.map { Self.sizingValueSets($0) } ?? []
        GeometryReader { geo in
            let available = geo.size.width - Self.statSpacing * CGFloat(items.count - 1)
            let widths = Self.statColumnWeights.map { $0 * available }
            let valueSize = Self.fittedValueFontSize(
                valueSets: Self.sizingValueSets(r) + peerValues,
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

    private func shade(rank: Int, provider: CostProvider) -> Color {
        let shades = provider == .codex
            ? TerminalColors.codexChartShades : TerminalColors.claudeChartShades
        return shades[min(rank, shades.count - 1)]
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    private static let unselectedDayOpacity = 0.55

    private func nearest(to date: Date, in entries: [DailyCostReport.DayEntry]) -> DailyCostReport.DayEntry? {
        entries.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        })
    }

    private struct StackedSegment: Identifiable {
        let rank: Int
        let yStart: Double
        let yEnd: Double
        var id: Int { rank }
    }

    private static let chartHeight: CGFloat = 105
    private static let segmentGapPixels = 1.0
    private static let hoverGracePixels: CGFloat = 12

    private static func stackedSegments(
        _ e: DailyCostReport.DayEntry, gap: Double) -> [StackedSegment]
    {
        var result: [StackedSegment] = []
        var cumulative = 0.0
        for s in e.segments {
            let inset = result.isEmpty ? 0 : min(gap, s.costUSD / 2)
            result.append(StackedSegment(
                rank: s.rank, yStart: cumulative + inset, yEnd: cumulative + s.costUSD))
            cumulative += s.costUSD
        }
        return result
    }

    @ViewBuilder private func chart(_ r: DailyCostReport) -> some View {
        let gap = (r.entries.map(\.costUSD).max() ?? 0) * Self.segmentGapPixels / Self.chartHeight
        Chart(r.entries) { e in
            ForEach(Self.stackedSegments(e, gap: gap)) { s in
                BarMark(
                    x: .value("Day", e.date, unit: .day),
                    yStart: .value("Cost", s.yStart),
                    yEnd: .value("Cost", s.yEnd))
                    .foregroundStyle(shade(rank: s.rank, provider: r.provider))
                    .opacity(selected == nil || selected?.id == e.id ? 1 : Self.unselectedDayOpacity)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .animation(.easeOut(duration: 0.15), value: selected)
        .frame(height: Self.chartHeight)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let origin = geo[plotFrame].origin
                            let x = location.x - origin.x
                            let y = location.y - origin.y
                            guard let date: Date = proxy.value(atX: x),
                                  let entry = nearest(to: date, in: r.entries),
                                  let barTop = proxy.position(forY: entry.costUSD)
                            else {
                                selected = nil
                                return
                            }
                            selected = y >= barTop - Self.hoverGracePixels ? entry : nil
                        case .ended:
                            selected = nil
                        }
                    }
            }
        }
    }
}
