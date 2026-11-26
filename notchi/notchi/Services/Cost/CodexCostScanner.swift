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

    private static let turnContextMarker = LogLineMarker(#""turn_context""#)
    private static let tokenCountMarker = LogLineMarker(#""token_count""#)

    nonisolated func scan(cache input: CostUsageCache, now: Date) -> CostUsageCache {
        var cache = input
        let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1),
                                        to: calendar.startOfDay(for: now))!
        let sinceKey = DailyCostReport.dayKey(windowStart, calendar: calendar)
        let cutoffDay = CostLogLine.cutoffDay(forWindowStart: windowStart, timeZone: calendar.timeZone)
        let logs = CostLogFiles.list(in: projectsRoots)
        cache.track(logs, windowStart: windowStart)

        var seen = Set<String>()
        var models = ModelPricingLookup(pricing: pricing, normalize: CostPricing.normalizeOpenAIModel)

        for log in logs {
            let url = log.url
            let path = url.path
            let tracked = cache.files[path]
            var state = tracked ?? .init(size: 0, mtime: 0, offset: 0)
            if state.size == log.size, state.mtime == log.mtime { continue }
            // Nothing written before the window counts. Offset 0 makes a later write read the file from the top,
            // so it still picks up the session's model.
            if tracked == nil, log.mtime < windowStart.timeIntervalSince1970 {
                cache.files[path] = .init(size: log.size, mtime: log.mtime, offset: 0)
                continue
            }
            // `track` rebuilt the cache if any file shrank, so every tracked offset is still valid.
            let startOffset = state.offset
            let resume = startOffset > 0 ? state.codexResume : nil
            if startOffset > 0 { seen.formUnion(state.recentDedupKeys ?? []) }

            let result = parseFile(url: url, startOffset: startOffset, sinceKey: sinceKey, cutoffDay: cutoffDay,
                                   resume: resume,
                                   seen: &seen, models: &models, into: &cache.buckets)
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

    nonisolated private func parseFile(url: URL, startOffset: Int64, sinceKey: String, cutoffDay: [UInt8],
                                       resume: CostUsageCache.CodexResume?,
                                       seen: inout Set<String>, models: inout ModelPricingLookup,
                                       into buckets: inout DayModelBuckets)
        -> (offset: Int64, resume: CostUsageCache.CodexResume, dedupKeys: [String]) {
        var currentModel = resume?.model
        var runningBaseline: (input: Int, cached: Int, output: Int)?
        if let i = resume?.baseInput, let c = resume?.baseCached, let o = resume?.baseOutput {
            runningBaseline = (i, c, o)
        }

        var dedupKeys: [String] = []
        let consumed = CostLogFiles.forEachLine(in: url, from: startOffset) { line in
            if let dedupKey = handleLine(line, sinceKey: sinceKey, cutoffDay: cutoffDay, currentModel: &currentModel,
                                         runningBaseline: &runningBaseline, seen: &seen, models: &models,
                                         into: &buckets) {
                dedupKeys.append(dedupKey)
            }
        }
        return (consumed, resumeState(currentModel, runningBaseline), dedupKeys)
    }

    nonisolated private func resumeState(_ model: String?,
                                         _ baseline: (input: Int, cached: Int, output: Int)?) -> CostUsageCache.CodexResume {
        CostUsageCache.CodexResume(model: model, baseInput: baseline?.input,
                                   baseCached: baseline?.cached, baseOutput: baseline?.output)
    }

    nonisolated private func handleLine(_ line: UnsafeRawBufferPointer, sinceKey: String, cutoffDay: [UInt8],
                                        currentModel: inout String?,
                                        runningBaseline: inout (input: Int, cached: Int, output: Int)?,
                                        seen: inout Set<String>, models: inout ModelPricingLookup,
                                        into buckets: inout DayModelBuckets) -> String? {
        let mentionsTurnContext = Self.turnContextMarker.occurs(in: line)
        guard mentionsTurnContext || Self.tokenCountMarker.occurs(in: line) else { return nil }
        // A turn context sets the model for the lines after it, however old, so only token counts skip by date.
        if !mentionsTurnContext, CostLogLine.isDated(line, before: cutoffDay) { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
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
              let date = CostLogLine.date(fromTimestamp: ts) else { return nil }

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

        let resolved = models.resolve(currentModel ?? "gpt-5")
        let normalizedModel = resolved.model
        let cached = min(delta.cached, delta.input)
        let mappedInput = delta.input - cached
        let mappedCacheRead = cached
        let mappedOutput = delta.output

        let dedupKey = "\(ts)|\(normalizedModel)|\(delta.input)|\(delta.cached)|\(delta.output)"
        if !seen.insert(dedupKey).inserted { return dedupKey }

        let cost = resolved.pricing.map {
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
}
