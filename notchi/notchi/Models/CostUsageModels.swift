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
    nonisolated struct DayEntry: Equatable, Sendable, Identifiable {
        let day: String
        let date: Date
        let costUSD: Double
        let totalTokens: Int
        let requestCount: Int
        let pricedFraction: Double
        let topModel: String?
        var id: String { day }
    }

    let provider: CostProvider
    let entries: [DayEntry]
    let topModel: String?

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
        var entries: [DayEntry] = []
        var cursor = calendar.startOfDay(for: windowStart)
        let last = calendar.startOfDay(for: today)
        var windowTotalsByModel: [String: ModelTokenTotals] = [:]
        while cursor <= last {
            let key = dayKey(cursor, calendar: calendar)
            let models = buckets[key] ?? [:]
            var totals = ModelTokenTotals()
            for (m, t) in models {
                totals = totals + t
                windowTotalsByModel[m] = (windowTotalsByModel[m] ?? ModelTokenTotals()) + t
            }
            let priced = totals.requestCount == 0 ? 1 : Double(totals.pricedCount) / Double(totals.requestCount)
            entries.append(DayEntry(
                day: key, date: cursor, costUSD: totals.costUSD,
                totalTokens: totals.totalTokens, requestCount: totals.requestCount,
                pricedFraction: priced, topModel: topModel(in: models)))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        return DailyCostReport(
            provider: provider, entries: entries,
            topModel: topModel(in: windowTotalsByModel))
    }

    static func topModel(in totalsByModel: [String: ModelTokenTotals]) -> String? {
        totalsByModel
            .max { lhs, rhs in
                if lhs.value.costNanos != rhs.value.costNanos {
                    return lhs.value.costNanos < rhs.value.costNanos
                }
                if lhs.value.totalTokens != rhs.value.totalTokens {
                    return lhs.value.totalTokens < rhs.value.totalTokens
                }
                return lhs.key > rhs.key
            }?
            .key
    }
}
