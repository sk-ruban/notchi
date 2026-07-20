import Foundation

nonisolated struct ProviderConfig: Sendable {
    let fallbackResource: String
    let modelsDevKey: ModelsDevKey
    let plausibilityAnchors: [String]
    let normalize: @Sendable (String) -> String
    let snapshotFileName: String

    enum ModelsDevKey: Sendable { case anthropic, openai }

    static let claude = ProviderConfig(
        fallbackResource: "claude-pricing-fallback",
        modelsDevKey: .anthropic,
        plausibilityAnchors: ["claude-sonnet-4", "claude-opus-4"],
        normalize: CostPricing.normalizeClaudeModel,
        snapshotFileName: "models-dev.json")

    static let codex = ProviderConfig(
        fallbackResource: "codex-pricing-fallback",
        modelsDevKey: .openai,
        plausibilityAnchors: ["gpt-5"],
        normalize: CostPricing.normalizeOpenAIModel,
        snapshotFileName: "models-dev-openai.json")
}

nonisolated final class PricingCatalog: ClaudePricingProviding, @unchecked Sendable {
    private struct Snapshot: Codable {
        let version: Int
        let models: [String: ClaudeModelPricingDTO]
    }

    private struct ClaudeModelPricingDTO: Codable {
        let inputPerToken: Double
        let outputPerToken: Double
        let cacheCreationPerToken: Double
        let cacheReadPerToken: Double
        let cacheCreation1hPerToken: Double?
        let thresholdTokens: Int?
        let inputPerTokenAboveThreshold: Double?
        let outputPerTokenAboveThreshold: Double?
        let cacheCreationPerTokenAboveThreshold: Double?
        let cacheReadPerTokenAboveThreshold: Double?

        init(from pricing: ClaudeModelPricing) {
            inputPerToken = pricing.inputPerToken
            outputPerToken = pricing.outputPerToken
            cacheCreationPerToken = pricing.cacheCreationPerToken
            cacheReadPerToken = pricing.cacheReadPerToken
            cacheCreation1hPerToken = pricing.cacheCreation1hPerToken
            thresholdTokens = pricing.thresholdTokens
            inputPerTokenAboveThreshold = pricing.inputPerTokenAboveThreshold
            outputPerTokenAboveThreshold = pricing.outputPerTokenAboveThreshold
            cacheCreationPerTokenAboveThreshold = pricing.cacheCreationPerTokenAboveThreshold
            cacheReadPerTokenAboveThreshold = pricing.cacheReadPerTokenAboveThreshold
        }

        func toPricing() -> ClaudeModelPricing {
            ClaudeModelPricing(
                inputPerToken: inputPerToken,
                outputPerToken: outputPerToken,
                cacheCreationPerToken: cacheCreationPerToken,
                cacheReadPerToken: cacheReadPerToken,
                cacheCreation1hPerToken: cacheCreation1hPerToken,
                thresholdTokens: thresholdTokens,
                inputPerTokenAboveThreshold: inputPerTokenAboveThreshold,
                outputPerTokenAboveThreshold: outputPerTokenAboveThreshold,
                cacheCreationPerTokenAboveThreshold: cacheCreationPerTokenAboveThreshold,
                cacheReadPerTokenAboveThreshold: cacheReadPerTokenAboveThreshold)
        }
    }

    private struct ModelsDev: Decodable {
        let anthropic: ModelsDev.Provider?
        let openai: ModelsDev.Provider?

        struct Provider: Decodable {
            let models: [String: ModelsDev.LenientEntry]
        }

        // WHY: models.dev omits cache fields for models that don't bill them,
        // and its shape drifts over time. A strict decoder made one unexpected
        // entry silently kill the refresh for every provider; unparseable
        // entries must degrade to "that model missing", nothing more.
        struct LenientEntry: Decodable {
            let entry: ModelEntry?

            init(from decoder: any Decoder) {
                entry = try? ModelEntry(from: decoder)
            }
        }

        struct ModelEntry: Decodable {
            let cost: ModelsDev.Cost?
        }

        struct Cost: Decodable {
            let input: Double
            let output: Double
            let cache_read: Double?
            let cache_write: Double?
            let tiers: [ModelsDev.Tier]?
        }

        struct Tier: Decodable {
            let input: Double
            let output: Double
            let cache_read: Double?
            let cache_write: Double?
            let tier: ModelsDev.TierSpec?
        }

        struct TierSpec: Decodable {
            let type: String
            let size: Int
        }
    }

    private let lock = NSLock()
    private var table: [String: ClaudeModelPricing]
    private let snapshotURL: URL?
    private let config: ProviderConfig

    init(config: ProviderConfig = .claude, fallbackBundle: Bundle, snapshotURL: URL? = nil) {
        self.config = config
        table = Self.loadFallback(bundle: fallbackBundle, config: config)
        if let url = snapshotURL, let overlay = Self.loadSnapshot(url: url) {
            table.merge(overlay) { _, new in new }
        }
        self.snapshotURL = snapshotURL
    }

    init(table: [String: ClaudeModelPricing]) {
        self.config = .claude
        self.table = table
        self.snapshotURL = nil
    }

    private static func loadFallback(bundle: Bundle, config: ProviderConfig) -> [String: ClaudeModelPricing] {
        guard let url = bundle.url(forResource: config.fallbackResource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return [:] }
        return snap.models.mapValues { $0.toPricing() }
    }

    private static func loadSnapshot(url: URL) -> [String: ClaudeModelPricing]? {
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return nil }
        return snap.models.mapValues { $0.toPricing() }
    }

    static func defaultSnapshotURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CostUsage/models-dev.json")
    }

    static func defaultSnapshotURL(for config: ProviderConfig) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CostUsage/\(config.snapshotFileName)")
    }

    func pricing(model: String, on date: Date) -> ClaudeModelPricing? {
        let key = config.normalize(model)
        lock.lock(); defer { lock.unlock() }
        return table[key]
    }

    func refreshFromNetwork() async {
        guard let url = URL(string: "https://models.dev/api.json") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        processNetworkData(data)
    }

    func processNetworkData(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode(ModelsDev.self, from: data) else { return }
        let provider: ModelsDev.Provider?
        switch config.modelsDevKey {
        case .anthropic: provider = decoded.anthropic
        case .openai: provider = decoded.openai
        }
        guard let provider else { return }

        let perMillion = 1_000_000.0
        var updated: [String: ClaudeModelPricing] = [:]

        for (rawId, lenient) in provider.models {
            guard let cost = lenient.entry?.cost else { continue }
            let key = config.normalize(rawId)

            let firstTier = cost.tiers?.first(where: { $0.tier?.type == "context" })
            let thresholdTokens = firstTier?.tier?.size

            updated[key] = ClaudeModelPricing(
                inputPerToken: cost.input / perMillion,
                outputPerToken: cost.output / perMillion,
                cacheCreationPerToken: (cost.cache_write ?? 0) / perMillion,
                cacheReadPerToken: (cost.cache_read ?? 0) / perMillion,
                cacheCreation1hPerToken: nil,
                thresholdTokens: thresholdTokens,
                inputPerTokenAboveThreshold: firstTier.map { $0.input / perMillion },
                outputPerTokenAboveThreshold: firstTier.map { $0.output / perMillion },
                cacheCreationPerTokenAboveThreshold: firstTier.map { ($0.cache_write ?? 0) / perMillion },
                cacheReadPerTokenAboveThreshold: firstTier.map { ($0.cache_read ?? 0) / perMillion })
        }

        guard Self.isPlausibleRefresh(updated, anchors: config.plausibilityAnchors) else { return }
        persistSnapshot(mergeIntoTable(updated))
    }

    private func mergeIntoTable(_ updated: [String: ClaudeModelPricing]) -> [String: ClaudeModelPricing] {
        lock.lock(); defer { lock.unlock() }
        table.merge(updated) { _, new in new }
        return table
    }

    private func persistSnapshot(_ updated: [String: ClaudeModelPricing]) {
        guard let url = snapshotURL else { return }
        let dtos = updated.mapValues { ClaudeModelPricingDTO(from: $0) }
        let snap = Snapshot(version: 1, models: dtos)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
        guard (try? data.write(to: tmp, options: .atomic)) != nil else { return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    func signature() -> String {
        lock.lock()
        let sorted = table.sorted(by: { $0.key < $1.key })
        lock.unlock()

        let fmt: (Double) -> String = { String(format: "%.12g", $0) }
        let fmtOpt: (Double?) -> String = { $0.map { String(format: "%.12g", $0) } ?? "-" }
        var buffer = ""
        for (key, p) in sorted {
            buffer += "\(key):\(fmt(p.inputPerToken)):\(fmt(p.outputPerToken)):\(fmt(p.cacheCreationPerToken)):\(fmt(p.cacheReadPerToken)):\(p.thresholdTokens ?? -1):\(fmtOpt(p.inputPerTokenAboveThreshold)):\(fmtOpt(p.outputPerTokenAboveThreshold)):\(fmtOpt(p.cacheCreationPerTokenAboveThreshold)):\(fmtOpt(p.cacheReadPerTokenAboveThreshold))"
        }
        let fnvOffsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
        let fnvPrime: UInt64 = 0x0000_0100_0000_01b3
        var hash = fnvOffsetBasis
        for byte in buffer.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* fnvPrime
        }
        return String(hash, radix: 16)
    }

    static func isPlausibleRefresh(_ candidate: [String: ClaudeModelPricing]) -> Bool {
        isPlausibleRefresh(candidate, anchors: ProviderConfig.claude.plausibilityAnchors)
    }

    static func isPlausibleRefresh(_ candidate: [String: ClaudeModelPricing], anchors: [String]) -> Bool {
        anchors.allSatisfy { anchor in candidate.keys.contains(where: { $0.hasPrefix(anchor) }) }
    }
}
