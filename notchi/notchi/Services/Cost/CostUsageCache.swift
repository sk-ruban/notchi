import Foundation

nonisolated struct CostUsageCache: Codable, Equatable {
    nonisolated struct CodexResume: Codable, Equatable {
        var model: String?
        var baseInput: Int?
        var baseCached: Int?
        var baseOutput: Int?
    }

    nonisolated struct FileState: Codable, Equatable {
        var size: Int64
        var mtime: Double
        var offset: Int64
        var codexResume: CodexResume? = nil
        /// Dedup keys from the end of the last read, so a duplicate line written after a scan is still skipped.
        var recentDedupKeys: [String]? = nil

        // One reply's duplicate lines are written back to back, so a scan can only split the last few.
        static let retainedDedupKeyCount = 32

        /// Keys to remember after a read that started at `startOffset` and saw `newKeys`.
        func dedupKeys(afterReadingFrom startOffset: Int64, adding newKeys: [String]) -> [String] {
            let carried = startOffset > 0 ? (recentDedupKeys ?? []) : []
            return Array((carried + newKeys).suffix(Self.retainedDedupKeyCount))
        }
    }

    static let currentVersion = 3
    var version: Int
    var files: [String: FileState]
    var buckets: DayModelBuckets
    var pricingSignature: String? = nil
    var timeZoneIdentifier: String? = nil

    /// Buckets are keyed by local day, so a time zone change (e.g. travel) invalidates them.
    func reconciled(withPricingSignature signature: String, timeZoneIdentifier: String) -> CostUsageCache {
        pricingSignature == signature && self.timeZoneIdentifier == timeZoneIdentifier
            ? self
            : CostUsageCache(version: Self.currentVersion, files: [:], buckets: [:],
                             pricingSignature: signature, timeZoneIdentifier: timeZoneIdentifier)
    }
}

nonisolated enum CostUsageCacheStore {
    static func load(url: URL) -> CostUsageCache {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CostUsageCache.self, from: data),
              decoded.version == CostUsageCache.currentVersion
        else { return CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:], pricingSignature: nil) }
        return decoded
    }

    static func save(_ cache: CostUsageCache, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
        guard let data = try? JSONEncoder().encode(cache), (try? data.write(to: tmp, options: .atomic)) != nil
        else { return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
