import Foundation

final class ClaudeCostScanner {
    let projectsRoots: [URL]
    let pricing: any ClaudePricingProviding
    let windowDays: Int
    let calendar: Calendar

    nonisolated private static let assistantMarker = LogLineMarker(#""type":"assistant""#)
    nonisolated private static let usageMarker = LogLineMarker(#""usage""#)

    nonisolated(unsafe) private var seen = Set<String>()

    nonisolated init(projectsRoots: [URL], pricing: any ClaudePricingProviding, windowDays: Int, calendar: Calendar) {
        self.projectsRoots = projectsRoots
        self.pricing = pricing
        self.windowDays = windowDays
        self.calendar = calendar
    }

    nonisolated deinit {}

    nonisolated func scan(cache input: CostUsageCache, now: Date) -> CostUsageCache {
        seen.removeAll()
        var cache = input
        let listing = CostLogFiles.list(in: projectsRoots)
        cache.track(listing.files, listingIsComplete: listing.isComplete)
        let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1),
                                        to: calendar.startOfDay(for: now))!
        let sinceKey = DailyCostReport.dayKey(windowStart, calendar: calendar)
        let cutoffDay = CostLogLine.cutoffDay(forWindowStart: windowStart, calendar: calendar)
        var models = ModelPricingLookup(pricing: pricing, normalize: CostPricing.normalizeClaudeModel)

        for log in listing.files {
            let url = log.url
            let path = url.path
            var state = cache.files[path] ?? .init(size: 0, mtime: 0, offset: 0)
            if state.size == log.size, state.mtime == log.mtime { continue }
            // Nothing written before the window counts. Offset 0 makes a later write read the file from the top.
            if log.mtime < windowStart.timeIntervalSince1970 {
                cache.files[path] = .init(size: log.size, mtime: log.mtime, offset: 0)
                continue
            }
            // `track` rebuilt the cache if any file shrank, so every tracked offset is still valid.
            let startOffset = state.offset
            if startOffset > 0 { seen.formUnion(state.recentDedupKeys ?? []) }

            let parsed = parseFile(url: url, startOffset: startOffset, sinceKey: sinceKey, cutoffDay: cutoffDay,
                                   models: &models, into: &cache.buckets)
            state.offset = parsed.offset
            state.recentDedupKeys = state.dedupKeys(afterReadingFrom: startOffset, adding: parsed.dedupKeys)
            state.size = log.size
            state.mtime = log.mtime
            cache.files[path] = state
        }
        cache.buckets = cache.buckets.filter { $0.key >= sinceKey }
        return cache
    }

    nonisolated private func parseFile(url: URL, startOffset: Int64, sinceKey: String, cutoffDay: [UInt8],
                                       models: inout ModelPricingLookup,
                                       into buckets: inout DayModelBuckets) -> (offset: Int64, dedupKeys: [String]) {
        var dedupKeys: [String] = []
        let consumed = CostLogFiles.forEachLine(in: url, from: startOffset) { line in
            if let dedupKey = handleLine(line, sinceKey: sinceKey, cutoffDay: cutoffDay, models: &models,
                                         into: &buckets) {
                dedupKeys.append(dedupKey)
            }
        }
        return (consumed ?? startOffset, dedupKeys)
    }

    nonisolated private func handleLine(_ line: UnsafeRawBufferPointer, sinceKey: String, cutoffDay: [UInt8],
                                        models: inout ModelPricingLookup,
                                        into buckets: inout DayModelBuckets) -> String? {
        guard Self.assistantMarker.occurs(in: line),
              Self.usageMarker.occurs(in: line),
              !CostLogLine.isDated(line, before: cutoffDay) else { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              obj["type"] as? String == "assistant",
              let ts = obj["timestamp"] as? String,
              let date = CostLogLine.date(fromTimestamp: ts) else { return nil }
        let dayKey = DailyCostReport.dayKey(date, calendar: calendar)
        guard dayKey >= sinceKey else { return nil }
        guard let message = obj["message"] as? [String: Any],
              let model = message["model"] as? String,
              let usage = message["usage"] as? [String: Any] else { return nil }

        let input = intval(usage["input_tokens"])
        let output = intval(usage["output_tokens"])
        let cacheCreate = intval(usage["cache_creation_input_tokens"])
        let cacheRead = intval(usage["cache_read_input_tokens"])
        let cacheCreate1h = intval((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"])
        let speedMultiplier = usage["speed"] as? String == "fast" ? CostPricing.fastModeMultiplier : 1
        if input == 0, output == 0, cacheCreate == 0, cacheRead == 0 { return nil }

        let msgId = message["id"] as? String ?? ""
        let reqId = obj["requestId"] as? String ?? ""
        let hasDedupKey = !(msgId.isEmpty && reqId.isEmpty)
        let dedupKey = msgId + "|" + reqId
        if hasDedupKey, !seen.insert(dedupKey).inserted { return dedupKey }

        let resolved = models.resolve(model)
        let cost = resolved.pricing.flatMap {
            CostPricing.claudeCostUSD(input: input, cacheRead: cacheRead,
                cacheCreation: cacheCreate, cacheCreation1h: cacheCreate1h, output: output, pricing: $0)
        }.map { $0 * speedMultiplier }
        let nanos = cost.map { Int(($0 * 1_000_000_000).rounded()) } ?? 0
        let key = resolved.model
        var dayModels = buckets[dayKey] ?? [:]
        dayModels[key] = (dayModels[key] ?? ModelTokenTotals()) + ModelTokenTotals(
            input: input, cacheRead: cacheRead, cacheCreation: cacheCreate, cacheCreation1h: cacheCreate1h,
            output: output, costNanos: nanos, requestCount: 1, pricedCount: cost == nil ? 0 : 1)
        buckets[dayKey] = dayModels
        return hasDedupKey ? dedupKey : nil
    }

    nonisolated private func intval(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
}
