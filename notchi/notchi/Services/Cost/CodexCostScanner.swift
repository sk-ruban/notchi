import Foundation

nonisolated final class CodexCostScanner {
    let projectsRoots: [URL]
    let pricing: any ClaudePricingProviding
    let windowDays: Int
    let calendar: Calendar

    nonisolated init(projectsRoots: [URL], pricing: any ClaudePricingProviding, windowDays: Int, calendar: Calendar) {
        self.projectsRoots = projectsRoots
        self.pricing = pricing
        self.windowDays = windowDays
        self.calendar = calendar
    }

    nonisolated deinit {}

    nonisolated func scan(cache input: CostUsageCache, now: Date) -> CostUsageCache {
        var cache = input
        let listing = CostLogFiles.list(in: projectsRoots)
        cache.track(listing.files, listingIsComplete: listing.isComplete)
        let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1),
                                        to: calendar.startOfDay(for: now))!
        let sinceKey = DailyCostReport.dayKey(windowStart, calendar: calendar)
        let cutoffDay = CostLogLine.cutoffDay(forWindowStart: windowStart, calendar: calendar)

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        var seen = Set<String>()

        for log in listing.files {
            let url = log.url
            let path = url.path
            var state = cache.files[path] ?? .init(size: 0, mtime: 0, offset: 0)
            if state.size == log.size, state.mtime == log.mtime { continue }
            // Nothing written before the window counts. Offset 0 makes a later write read the file from the top,
            // so it still picks up the session's model and running totals.
            if log.mtime < windowStart.timeIntervalSince1970 {
                cache.files[path] = .init(size: log.size, mtime: log.mtime, offset: 0)
                continue
            }
            // `track` rebuilt the cache if any file shrank, so every tracked offset is still valid.
            let startOffset = state.offset
            let resume = startOffset > 0 ? state.codexResume : nil
            if startOffset > 0 { seen.formUnion(state.recentDedupKeys ?? []) }

            let result = parseFile(url: url, startOffset: startOffset, sinceKey: sinceKey, cutoffDay: cutoffDay,
                                   resume: resume,
                                   seen: &seen, isoFractional: isoFractional, isoPlain: isoPlain,
                                   into: &cache.buckets)
            state.offset = result.offset
            state.codexResume = result.resume
            state.recentDedupKeys = state.dedupKeys(afterReadingFrom: startOffset, adding: result.dedupKeys)
            state.size = log.size
            state.mtime = log.mtime
            cache.files[path] = state
        }
        cache.buckets = cache.buckets.filter { $0.key >= sinceKey }
        return cache
    }

    nonisolated private func parseFile(url: URL, startOffset: Int64, sinceKey: String, cutoffDay: Data,
                                       resume: CostUsageCache.CodexResume?,
                                       seen: inout Set<String>,
                                       isoFractional: ISO8601DateFormatter, isoPlain: ISO8601DateFormatter,
                                       into buckets: inout DayModelBuckets)
        -> (offset: Int64, resume: CostUsageCache.CodexResume, dedupKeys: [String]) {
        var currentModel = resume?.model
        var runningBaseline: (input: Int, cached: Int, output: Int)?
        if let i = resume?.baseInput, let c = resume?.baseCached, let o = resume?.baseOutput {
            runningBaseline = (i, c, o)
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return (startOffset, resumeState(currentModel, runningBaseline), [])
        }
        defer { try? handle.close() }
        if startOffset > 0 { try? handle.seek(toOffset: UInt64(startOffset)) }
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            return (startOffset, resumeState(currentModel, runningBaseline), [])
        }

        var dedupKeys: [String] = []
        var consumed = startOffset
        var lineStart = data.startIndex
        let newline = UInt8(ascii: "\n")
        var i = data.startIndex
        while i < data.endIndex {
            if data[i] == newline {
                let lineData = data[lineStart..<i]
                consumed += Int64(lineData.count) + 1
                if let dedupKey = handleLine(lineData, sinceKey: sinceKey, cutoffDay: cutoffDay, currentModel: &currentModel,
                                             runningBaseline: &runningBaseline, seen: &seen,
                                             isoFractional: isoFractional, isoPlain: isoPlain, into: &buckets) {
                    dedupKeys.append(dedupKey)
                }
                lineStart = data.index(after: i)
            }
            i = data.index(after: i)
        }
        return (consumed, resumeState(currentModel, runningBaseline), dedupKeys)
    }

    nonisolated private func resumeState(_ model: String?,
                                         _ baseline: (input: Int, cached: Int, output: Int)?) -> CostUsageCache.CodexResume {
        CostUsageCache.CodexResume(model: model, baseInput: baseline?.input,
                                   baseCached: baseline?.cached, baseOutput: baseline?.output)
    }

    nonisolated private func handleLine(_ lineData: Data, sinceKey: String, cutoffDay: Data,
                                        currentModel: inout String?,
                                        runningBaseline: inout (input: Int, cached: Int, output: Int)?,
                                        seen: inout Set<String>,
                                        isoFractional: ISO8601DateFormatter, isoPlain: ISO8601DateFormatter,
                                        into buckets: inout DayModelBuckets) -> String? {
        let mentionsTurnContext = lineData.range(of: Data(#""turn_context""#.utf8)) != nil
        guard mentionsTurnContext || lineData.range(of: Data(#""token_count""#.utf8)) != nil else { return nil }
        // A turn context sets the model for the lines after it, however old, so only token counts skip by date.
        if !mentionsTurnContext, CostLogLine.isDated(lineData, before: cutoffDay) { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
              let type_ = obj["type"] as? String else { return nil }

        if type_ == "turn_context" {
            if let payload = obj["payload"] as? [String: Any],
               let model = payload["model"] as? String {
                currentModel = model
            }
            return nil
        }

        guard type_ == "event_msg",
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let ts = obj["timestamp"] as? String,
              let date = parseTimestamp(ts, isoFractional: isoFractional, isoPlain: isoPlain) else { return nil }

        let dayKey = DailyCostReport.dayKey(date, calendar: calendar)
        guard dayKey >= sinceKey else { return nil }

        guard let info = payload["info"] as? [String: Any] else { return nil }
        let last = info["last_token_usage"] as? [String: Any]
        let total = info["total_token_usage"] as? [String: Any]

        let delta: (input: Int, cached: Int, output: Int)
        if let last {
            delta = (intval(last["input_tokens"]), intval(last["cached_input_tokens"]), intval(last["output_tokens"]))
        } else if let total {
            let totalTuple = (intval(total["input_tokens"]), intval(total["cached_input_tokens"]), intval(total["output_tokens"]))
            if let baseline = runningBaseline {
                delta = (
                    max(0, totalTuple.0 - baseline.input),
                    max(0, totalTuple.1 - baseline.cached),
                    max(0, totalTuple.2 - baseline.output)
                )
            } else {
                delta = totalTuple
            }
        } else {
            return nil
        }

        if let total {
            runningBaseline = (intval(total["input_tokens"]), intval(total["cached_input_tokens"]), intval(total["output_tokens"]))
        }

        if delta.input == 0, delta.cached == 0, delta.output == 0 { return nil }

        let rawModel = currentModel ?? "gpt-5"
        let normalizedModel = CostPricing.normalizeOpenAIModel(rawModel)
        let cached = min(delta.cached, delta.input)
        let mappedInput = delta.input - cached
        let mappedCacheRead = cached
        let mappedOutput = delta.output

        let dedupKey = "\(ts)|\(normalizedModel)|\(delta.input)|\(delta.cached)|\(delta.output)"
        if !seen.insert(dedupKey).inserted { return dedupKey }

        let pricingResult = pricing.pricing(model: rawModel)
        let cost = pricingResult.map {
            CostPricing.claudeCostUSD(input: mappedInput, cacheRead: mappedCacheRead,
                cacheCreation: 0, cacheCreation1h: 0, output: mappedOutput, pricing: $0)
        } ?? nil
        let nanos = cost.map { Int(($0 * 1_000_000_000).rounded()) } ?? 0

        var dayModels = buckets[dayKey] ?? [:]
        dayModels[normalizedModel] = (dayModels[normalizedModel] ?? ModelTokenTotals()) + ModelTokenTotals(
            input: mappedInput, cacheRead: mappedCacheRead, cacheCreation: 0, cacheCreation1h: 0,
            output: mappedOutput, costNanos: nanos, requestCount: 1, pricedCount: cost == nil ? 0 : 1)
        buckets[dayKey] = dayModels
        return dedupKey
    }

    nonisolated private func intval(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

    nonisolated private func parseTimestamp(_ s: String, isoFractional: ISO8601DateFormatter,
                                            isoPlain: ISO8601DateFormatter) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
}
