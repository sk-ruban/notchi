import Foundation

final class ClaudeCostScanner {
    let projectsRoots: [URL]
    let pricing: any ClaudePricingProviding
    let windowDays: Int
    let calendar: Calendar

    nonisolated(unsafe) private var seen = Set<String>()

    nonisolated(unsafe) private let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private let isoPlain = ISO8601DateFormatter()

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
        if anyTrackedFileShrank(cache.files) {
            cache.files = [:]
            cache.buckets = [:]
        }
        let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1),
                                        to: calendar.startOfDay(for: now))!
        let sinceKey = DailyCostReport.dayKey(windowStart, calendar: calendar)

        for root in projectsRoots {
            guard let en = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                let path = url.path
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let mtime = ((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0
                var state = cache.files[path] ?? .init(size: 0, mtime: 0, offset: 0)
                if state.size == size, state.mtime == mtime { continue }
                let startOffset = (size >= state.size) ? state.offset : 0

                state.offset = parseFile(url: url, startOffset: startOffset, sinceKey: sinceKey, into: &cache.buckets)
                state.size = size
                state.mtime = mtime
                cache.files[path] = state
            }
        }
        cache.buckets = cache.buckets.filter { $0.key >= sinceKey }
        return cache
    }

    nonisolated private func anyTrackedFileShrank(_ files: [String: CostUsageCache.FileState]) -> Bool {
        for (path, state) in files {
            let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
            if size < state.size { return true }
        }
        return false
    }

    nonisolated private func parseFile(url: URL, startOffset: Int64, sinceKey: String,
                                       into buckets: inout DayModelBuckets) -> Int64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return startOffset }
        defer { try? handle.close() }
        if startOffset > 0 { try? handle.seek(toOffset: UInt64(startOffset)) }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return startOffset }

        var consumed = startOffset
        var lineStart = data.startIndex
        let newline = UInt8(ascii: "\n")
        var i = data.startIndex
        while i < data.endIndex {
            if data[i] == newline {
                let lineData = data[lineStart..<i]
                consumed += Int64(lineData.count) + 1
                handleLine(lineData, sinceKey: sinceKey, into: &buckets)
                lineStart = data.index(after: i)
            }
            i = data.index(after: i)
        }
        return consumed
    }

    nonisolated private func handleLine(_ lineData: Data, sinceKey: String, into buckets: inout DayModelBuckets) {
        guard lineData.range(of: Data(#""type":"assistant""#.utf8)) != nil,
              lineData.range(of: Data(#""usage""#.utf8)) != nil else { return }
        guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
              obj["type"] as? String == "assistant",
              let ts = obj["timestamp"] as? String,
              let date = parseTimestamp(ts) else { return }
        let dayKey = DailyCostReport.dayKey(date, calendar: calendar)
        guard dayKey >= sinceKey else { return }
        guard let message = obj["message"] as? [String: Any],
              let model = message["model"] as? String,
              let usage = message["usage"] as? [String: Any] else { return }

        let input = intval(usage["input_tokens"])
        let output = intval(usage["output_tokens"])
        let cacheCreate = intval(usage["cache_creation_input_tokens"])
        let cacheRead = intval(usage["cache_read_input_tokens"])
        let cacheCreate1h = intval((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"])
        let speedMultiplier = usage["speed"] as? String == "fast" ? CostPricing.fastModeMultiplier : 1
        if input == 0, output == 0, cacheCreate == 0, cacheRead == 0 { return }

        let msgId = message["id"] as? String ?? ""
        let reqId = obj["requestId"] as? String ?? ""
        let dedupKey = msgId + "|" + reqId
        if !(msgId.isEmpty && reqId.isEmpty), !seen.insert(dedupKey).inserted { return }

        let cost = pricing.pricing(model: model).flatMap {
            CostPricing.claudeCostUSD(input: input, cacheRead: cacheRead,
                cacheCreation: cacheCreate, cacheCreation1h: cacheCreate1h, output: output, pricing: $0)
        }.map { $0 * speedMultiplier }
        let nanos = cost.map { Int(($0 * 1_000_000_000).rounded()) } ?? 0
        let key = CostPricing.normalizeClaudeModel(model)
        var dayModels = buckets[dayKey] ?? [:]
        dayModels[key] = (dayModels[key] ?? ModelTokenTotals()) + ModelTokenTotals(
            input: input, cacheRead: cacheRead, cacheCreation: cacheCreate, cacheCreation1h: cacheCreate1h,
            output: output, costNanos: nanos, requestCount: 1, pricedCount: cost == nil ? 0 : 1)
        buckets[dayKey] = dayModels
    }

    nonisolated private func intval(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

    nonisolated private func parseTimestamp(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
}
