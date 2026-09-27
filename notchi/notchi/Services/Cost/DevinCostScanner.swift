import Foundation

nonisolated final class DevinCostScanner {
    let databaseURL: URL
    let pricing: any ClaudePricingProviding
    let windowDays: Int
    let calendar: Calendar

    nonisolated init(databaseURL: URL, pricing: any ClaudePricingProviding, windowDays: Int, calendar: Calendar) {
        self.databaseURL = databaseURL
        self.pricing = pricing
        self.windowDays = windowDays
        self.calendar = calendar
    }

    nonisolated deinit {}

    nonisolated func scan(cache input: CostUsageCache, now: Date) -> CostUsageCache {
        var cache = input
        let path = databaseURL.path
        guard let fingerprint = databaseFingerprint() else {
            cache.files[path] = nil
            cache.buckets = [:]
            return cache
        }

        let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1),
                                        to: calendar.startOfDay(for: now))!
        let sinceKey = DailyCostReport.dayKey(windowStart, calendar: calendar)

        if cache.files[path] != fingerprint, let rebuilt = buckets(since: windowStart, sinceKey: sinceKey) {
            cache.buckets = rebuilt
            cache.files[path] = fingerprint
        }

        cache.buckets = cache.buckets.filter { $0.key >= sinceKey }
        return cache
    }

    private static let endOfRowsMarker = "notchi-end-of-rows"

    private struct Reply {
        let date: Date
        let model: String
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheCreation: Int
    }

    nonisolated private func databaseFingerprint() -> CostUsageCache.FileState? {
        let fileManager = FileManager.default
        guard let database = try? fileManager.attributesOfItem(atPath: databaseURL.path) else { return nil }
        let wal = try? fileManager.attributesOfItem(atPath: databaseURL.path + "-wal")
        let size = [database, wal].compactMap { ($0?[.size] as? NSNumber)?.int64Value }.reduce(0, +)
        let mtime = [database, wal].compactMap { ($0?[.modificationDate] as? Date)?.timeIntervalSince1970 }.max() ?? 0
        return CostUsageCache.FileState(size: size, mtime: mtime, offset: 0)
    }

    nonisolated private func buckets(since windowStart: Date, sinceKey: String) -> DayModelBuckets? {
        guard let replies = replies(since: windowStart) else { return nil }
        var buckets: DayModelBuckets = [:]
        for reply in replies {
            let dayKey = DailyCostReport.dayKey(reply.date, calendar: calendar)
            guard dayKey >= sinceKey else { continue }

            let cost = pricing.pricing(model: reply.model, on: reply.date).flatMap {
                CostPricing.claudeCostUSD(
                    model: reply.model, input: reply.input, cacheRead: reply.cacheRead,
                    cacheCreation: reply.cacheCreation, cacheCreation1h: 0, output: reply.output, pricing: $0)
            }
            let nanos = cost.map { Int(($0 * 1_000_000_000).rounded()) } ?? 0

            buckets[dayKey, default: [:]][reply.model, default: ModelTokenTotals()] += ModelTokenTotals(
                input: reply.input, cacheRead: reply.cacheRead, cacheCreation: reply.cacheCreation,
                cacheCreation1h: 0, output: reply.output, costNanos: nanos,
                requestCount: 1, pricedCount: cost == nil ? 0 : 1)
        }
        return buckets
    }

    nonisolated private func replies(since windowStart: Date) -> [Reply]? {
        let query = """
            SELECT reply_at, written_at, model, input, output, cache_read, cache_creation FROM (
              SELECT *, ROW_NUMBER() OVER (PARTITION BY request ORDER BY model IS NULL, metrics IS NULL, row_id DESC) AS copy FROM (
                SELECT row_id, created_at AS written_at,
                  COALESCE(json_extract(chat_message, '$.metadata.request_id'),
                           json_extract(chat_message, '$.message_id'), row_id) AS request,
                  json_extract(chat_message, '$.metadata.created_at') AS reply_at,
                  json_extract(chat_message, '$.metadata.generation_model') AS model,
                  json_extract(chat_message, '$.metadata.metrics') AS metrics,
                  COALESCE(json_extract(chat_message, '$.metadata.metrics.input_tokens'), 0) AS input,
                  COALESCE(json_extract(chat_message, '$.metadata.metrics.output_tokens'), 0) AS output,
                  COALESCE(json_extract(chat_message, '$.metadata.metrics.cache_read_tokens'), 0) AS cache_read,
                  COALESCE(json_extract(chat_message, '$.metadata.metrics.cache_creation_tokens'), 0) AS cache_creation
                FROM message_nodes
                WHERE created_at >= \(Int64(windowStart.timeIntervalSince1970))
                  AND CASE WHEN json_valid(chat_message)
                           THEN json_extract(chat_message, '$.role') END = 'assistant'
              )
            )
            WHERE copy = 1 AND model IS NOT NULL;
            SELECT '\(Self.endOfRowsMarker)';
            """

        guard let output = CodexFileSystem.runSQLite(query: query, databasePath: databaseURL.path, readOnly: true) else {
            return nil
        }
        var rows = output.split(separator: "\n")
        guard rows.last == Self.endOfRowsMarker[...] else { return nil }
        rows.removeLast()

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        return rows.compactMap { row in
            let fields = row.split(separator: Character(CodexFileSystem.sqliteSeparator), omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count == 7 else { return nil }
            let generatedAt = isoFractional.date(from: fields[0]) ?? isoPlain.date(from: fields[0])
            guard let date = generatedAt ?? TimeInterval(fields[1]).map(Date.init(timeIntervalSince1970:)) else {
                return nil
            }
            return Reply(
                date: date,
                model: fields[2],
                input: Int(fields[3]) ?? 0,
                output: Int(fields[4]) ?? 0,
                cacheRead: Int(fields[5]) ?? 0,
                cacheCreation: Int(fields[6]) ?? 0
            )
        }
    }
}
