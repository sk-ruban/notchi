import Foundation

nonisolated enum CostProvider: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
}

nonisolated struct ModelTokenTotals: Equatable, Sendable, Codable {
    var input: Int = 0
    var cacheRead: Int = 0
    var cacheCreation: Int = 0
    var cacheCreation1h: Int = 0
    var output: Int = 0
    var costNanos: Int = 0
    var requestCount: Int = 0
    var pricedCount: Int = 0

    var totalTokens: Int { input + cacheRead + cacheCreation + output }
    var costUSD: Double { Double(costNanos) / 1_000_000_000 }

    static func + (l: ModelTokenTotals, r: ModelTokenTotals) -> ModelTokenTotals {
        ModelTokenTotals(
            input: l.input + r.input, cacheRead: l.cacheRead + r.cacheRead,
            cacheCreation: l.cacheCreation + r.cacheCreation,
            cacheCreation1h: l.cacheCreation1h + r.cacheCreation1h,
            output: l.output + r.output, costNanos: l.costNanos + r.costNanos,
            requestCount: l.requestCount + r.requestCount, pricedCount: l.pricedCount + r.pricedCount)
    }
}

typealias DayModelBuckets = [String: [String: ModelTokenTotals]]

nonisolated struct DailyCostReport: Equatable, Sendable {
    nonisolated struct Segment: Equatable, Sendable, Identifiable {
        let rank: Int
        let costUSD: Double
        let models: [String]
        var id: Int { rank }
    }

    nonisolated struct DayEntry: Equatable, Sendable, Identifiable {
        let day: String
        let date: Date
        let costUSD: Double
        let totalTokens: Int
        let requestCount: Int
        let pricedFraction: Double
        let topModel: String?
        let segments: [Segment]
        var id: String { day }
    }

    static let shadedModelCount = 2

    let provider: CostProvider
    let entries: [DayEntry]
    let topModel: String?
    let shadedModels: [String]

    var hasOtherSegments: Bool {
        entries.contains { e in e.segments.contains { $0.rank == shadedModels.count } }
    }

    var windowCostUSD: Double { entries.reduce(0) { $0 + $1.costUSD } }
    var windowTokens: Int { entries.reduce(0) { $0 + $1.totalTokens } }
    var todayCostUSD: Double { entries.last?.costUSD ?? 0 }
    var todayTokens: Int { entries.last?.totalTokens ?? 0 }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func make(
        provider: CostProvider, buckets: DayModelBuckets,
        windowStart: Date, today: Date, calendar: Calendar) -> DailyCostReport
    {
        var days: [(key: String, date: Date, models: [String: ModelTokenTotals])] = []
        var cursor = calendar.startOfDay(for: windowStart)
        let last = calendar.startOfDay(for: today)
        var windowTotalsByModel: [String: ModelTokenTotals] = [:]
        while cursor <= last {
            let key = dayKey(cursor, calendar: calendar)
            let models = buckets[key] ?? [:]
            for (m, t) in models {
                windowTotalsByModel[m] = (windowTotalsByModel[m] ?? ModelTokenTotals()) + t
            }
            days.append((key, cursor, models))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        let shadedModels = Array(rankedModels(in: windowTotalsByModel).prefix(shadedModelCount))
        let entries = days.map { day -> DayEntry in
            var totals = ModelTokenTotals()
            for t in day.models.values { totals = totals + t }
            let priced = totals.requestCount == 0 ? 1 : Double(totals.pricedCount) / Double(totals.requestCount)
            return DayEntry(
                day: day.key, date: day.date, costUSD: totals.costUSD,
                totalTokens: totals.totalTokens, requestCount: totals.requestCount,
                pricedFraction: priced, topModel: topModel(in: day.models),
                segments: segments(for: day.models, shadedModels: shadedModels))
        }
        return DailyCostReport(
            provider: provider, entries: entries,
            topModel: shadedModels.first, shadedModels: shadedModels)
    }

    static func segments(
        for models: [String: ModelTokenTotals], shadedModels: [String]) -> [Segment]
    {
        var result: [Segment] = []
        for (rank, model) in shadedModels.enumerated() {
            if let cost = models[model]?.costUSD, cost > 0 {
                result.append(Segment(rank: rank, costUSD: cost, models: [model]))
            }
        }
        let others = models.filter { !shadedModels.contains($0.key) && $0.value.costUSD > 0 }
        if !others.isEmpty {
            let names = others
                .sorted { lhs, rhs in
                    lhs.value.costUSD != rhs.value.costUSD
                        ? lhs.value.costUSD > rhs.value.costUSD
                        : lhs.key < rhs.key
                }
                .map(\.key)
            result.append(Segment(
                rank: shadedModels.count,
                costUSD: others.values.reduce(0) { $0 + $1.costUSD },
                models: names))
        }
        return result
    }

    static func combinedAcrossProviders(
        _ perProvider: [(provider: CostProvider, buckets: DayModelBuckets)],
        windowStart: Date, today: Date, calendar: Calendar) -> DailyCostReport
    {
        var providerBuckets: DayModelBuckets = [:]
        var modelBuckets: DayModelBuckets = [:]
        for (provider, buckets) in perProvider {
            for (day, models) in buckets {
                for (model, totals) in models {
                    providerBuckets[day, default: [:]][provider.rawValue] =
                        (providerBuckets[day]?[provider.rawValue] ?? ModelTokenTotals()) + totals
                    modelBuckets[day, default: [:]][model] =
                        (modelBuckets[day]?[model] ?? ModelTokenTotals()) + totals
                }
            }
        }
        let base = make(
            provider: perProvider.first?.provider ?? .claude, buckets: providerBuckets,
            windowStart: windowStart, today: today, calendar: calendar)
        var windowTotalsByModel: [String: ModelTokenTotals] = [:]
        for entry in base.entries {
            for (model, totals) in modelBuckets[entry.day] ?? [:] {
                windowTotalsByModel[model] = (windowTotalsByModel[model] ?? ModelTokenTotals()) + totals
            }
        }
        let entries = base.entries.map { e in
            DayEntry(
                day: e.day, date: e.date, costUSD: e.costUSD,
                totalTokens: e.totalTokens, requestCount: e.requestCount,
                pricedFraction: e.pricedFraction,
                topModel: topModel(in: modelBuckets[e.day] ?? [:]),
                segments: e.segments.sorted { providerOrder($0) < providerOrder($1) })
        }
        return DailyCostReport(
            provider: base.provider, entries: entries,
            topModel: topModel(in: windowTotalsByModel),
            shadedModels: base.shadedModels)
    }

    private static func providerOrder(_ segment: Segment) -> Int {
        segment.models.first
            .flatMap(CostProvider.init(rawValue:))
            .flatMap(CostProvider.allCases.firstIndex(of:)) ?? CostProvider.allCases.count
    }

    static func rankedModels(in totalsByModel: [String: ModelTokenTotals]) -> [String] {
        totalsByModel
            .sorted { lhs, rhs in
                if lhs.value.costNanos != rhs.value.costNanos {
                    return lhs.value.costNanos > rhs.value.costNanos
                }
                if lhs.value.totalTokens != rhs.value.totalTokens {
                    return lhs.value.totalTokens > rhs.value.totalTokens
                }
                return lhs.key < rhs.key
            }
            .map(\.key)
    }

    static func topModel(in totalsByModel: [String: ModelTokenTotals]) -> String? {
        rankedModels(in: totalsByModel).first
    }
}
