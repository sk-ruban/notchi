import Foundation
import Observation
import os

@MainActor
@Observable
final class CostHistoryStore {
    // The isolated-deinit back-deploy shim aborts on macOS 15; this deinit only releases stored properties.
    nonisolated deinit {}

    private(set) var report: DailyCostReport?
    private(set) var buckets: DayModelBuckets = [:]
    private(set) var isScanning = false
    private(set) var lastScan: Date?

    let windowDays: Int
    let calendar: Calendar
    private let provider: CostProvider
    private let scanProvider: @Sendable (Date) async -> DayModelBuckets
    private var timer: Timer?
    private let refreshInterval: TimeInterval = 90
    // Lets macOS coalesce the wakeup with other timers; scans need no precise timing.
    private let refreshTolerance: TimeInterval = 15
    private let newlyUnpricedRetryInterval: TimeInterval = 60 * 60
    private let pricingRetryInterval: TimeInterval = 24 * 60 * 60
    private let pricingCatalog: PricingCatalog?
    private let pricingClock: PricingRefreshClock
    private var needsRescan = false

    init(windowDays: Int = 30, calendar: Calendar = .autoupdatingCurrent, provider: CostProvider = .claude,
         scanProvider: @escaping @Sendable (Date) async -> DayModelBuckets) {
        self.windowDays = windowDays
        self.calendar = calendar
        self.provider = provider
        self.scanProvider = scanProvider
        self.pricingCatalog = nil
        self.pricingClock = PricingRefreshClock()
    }

    convenience init(windowDays: Int = 30, calendar: Calendar = .autoupdatingCurrent,
                     provider: CostProvider = .claude,
                     pricing: PricingCatalog,
                     pricingClock: PricingRefreshClock = PricingRefreshClock(),
                     projectsRoots: [URL],
                     cacheURL: URL) {
        let scan = Self.makeScan(provider: provider, projectsRoots: projectsRoots,
                                 pricing: pricing, windowDays: windowDays, calendar: calendar)
        // Only this store uses its cache file, so after the first load it keeps the latest cache in memory,
        // along with the copy last written, to write the file only when the two differ.
        let caches = OSAllocatedUnfairLock<(latest: CostUsageCache, saved: CostUsageCache)?>(initialState: nil)
        self.init(windowDays: windowDays, calendar: calendar, provider: provider, pricingCatalog: pricing,
                  pricingClock: pricingClock) { now in
            await Task.detached(priority: .utility) {
                let sig = pricing.signature()
                let timeZoneID = calendar.timeZone.identifier
                let (latest, saved) = caches.withLock { $0 } ?? {
                    let loaded = CostUsageCacheStore.load(url: cacheURL)
                    return (loaded, loaded)
                }()
                var scanned = scan(latest.reconciled(withPricingSignature: sig, timeZoneIdentifier: timeZoneID), now)
                scanned.pricingSignature = sig
                scanned.timeZoneIdentifier = timeZoneID
                let updated = scanned
                let isSaved = updated == saved || CostUsageCacheStore.save(updated, to: cacheURL)
                caches.withLock { $0 = (updated, isSaved ? updated : saved) }
                return updated.buckets
            }.value
        }
    }

    private static func makeScan(provider: CostProvider, projectsRoots: [URL], pricing: PricingCatalog,
                                 windowDays: Int, calendar: Calendar) -> @Sendable (CostUsageCache, Date) -> CostUsageCache {
        switch provider {
        case .claude:
            let scanner = ClaudeCostScanner(projectsRoots: projectsRoots, pricing: pricing,
                                            windowDays: windowDays, calendar: calendar)
            return { scanner.scan(cache: $0, now: $1) }
        case .codex:
            let scanner = CodexCostScanner(projectsRoots: projectsRoots, pricing: pricing,
                                           windowDays: windowDays, calendar: calendar)
            return { scanner.scan(cache: $0, now: $1) }
        case .devin:
            let databaseURL = (projectsRoots.first ?? homeURL(".local/share/devin/cli"))
                .appendingPathComponent("sessions.db")
            let scanner = DevinCostScanner(databaseURL: databaseURL, pricing: pricing,
                                           windowDays: windowDays, calendar: calendar)
            return { scanner.scan(cache: $0, now: $1) }
        }
    }

    init(windowDays: Int, calendar: Calendar, provider: CostProvider, pricingCatalog: PricingCatalog,
         pricingClock: PricingRefreshClock = PricingRefreshClock(),
         scanProvider: @escaping @Sendable (Date) async -> DayModelBuckets) {
        self.windowDays = windowDays
        self.calendar = calendar
        self.provider = provider
        self.scanProvider = scanProvider
        self.pricingCatalog = pricingCatalog
        self.pricingClock = pricingClock
    }

    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer?.tolerance = refreshTolerance
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        let now = Date()
        guard let buckets = await scanAndPublish(),
              let catalog = pricingCatalog, catalog.canRefreshFromNetwork else { return }
        let unpricedModels = Self.unpricedModels(in: buckets)
        guard shouldRefreshPricing(unpricedModels: unpricedModels, now: now) else { return }
        // The fetch runs outside isScanning so a slow models.dev never blocks timer scans.
        pricingClock.lastRefresh = now
        if await catalog.refreshFromNetwork() {
            pricingClock.fetchedUnpricedModels.formUnion(unpricedModels)
        }
        await scanAndPublish(rescanIfBusy: true)
    }

    /// Overlapping timer ticks are dropped. The post-fetch call instead makes a running scan
    /// go once more, so a scan that began before new pricing arrived is never the last one published.
    @discardableResult
    private func scanAndPublish(rescanIfBusy: Bool = false) async -> DayModelBuckets? {
        if isScanning {
            if rescanIfBusy { needsRescan = true }
            return nil
        }
        isScanning = true
        defer { isScanning = false }
        var buckets: DayModelBuckets
        repeat {
            needsRescan = false
            let now = Date()
            buckets = await scanProvider(now)
            publish(buckets, now: now)
        } while needsRescan
        return buckets
    }

    private func publish(_ buckets: DayModelBuckets, now: Date) {
        let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1),
                                        to: calendar.startOfDay(for: now))!
        self.buckets = buckets
        report = DailyCostReport.make(
            provider: provider, buckets: buckets,
            windowStart: windowStart, today: now, calendar: calendar)
        lastScan = now
    }

    /// Fetches once at launch. After that, a model unpriced since the last successful fetch, such as one
    /// released since, is retried hourly; models still unpriced after one, like ones behind a proxy, daily.
    private func shouldRefreshPricing(unpricedModels: Set<String>, now: Date) -> Bool {
        guard let lastPricingRefresh = pricingClock.lastRefresh else { return true }
        guard !unpricedModels.isEmpty else { return false }
        let hasNewlyUnpriced = !unpricedModels.isSubset(of: pricingClock.fetchedUnpricedModels)
        return now.timeIntervalSince(lastPricingRefresh)
            >= (hasNewlyUnpriced ? newlyUnpricedRetryInterval : pricingRetryInterval)
    }

    private static func unpricedModels(in buckets: DayModelBuckets) -> Set<String> {
        Set(buckets.values.flatMap { models in
            models.filter { $0.value.pricedCount < $0.value.requestCount }.keys
        })
    }
}

// MARK: - Shared singletons

extension CostHistoryStore {
    /// One price list for every Claude account's store.
    static let claudePricing = pricingCatalog(for: .claude)
    private static let claudePricingClock = PricingRefreshClock()

    static let shared = makeStore(
        provider: .claude, pricing: claudePricing, pricingClock: claudePricingClock,
        projectsRoots: [homeURL(".claude/projects")], cacheFile: "claude.json")

    /// The folder the shared Claude store reads, so the account store can reuse it for that account.
    static let sharedClaudeDirectory = homeURL(".claude")

    /// Another Claude account's spend, read from its own config folder.
    static func claudeAccountStore(projectsRoot: URL, cacheFile: String) -> CostHistoryStore {
        makeStore(provider: .claude, pricing: claudePricing, pricingClock: claudePricingClock,
                  projectsRoots: [projectsRoot], cacheFile: cacheFile)
    }

    static let sharedCodex = makeStore(
        provider: .codex, pricing: pricingCatalog(for: .codex),
        projectsRoots: [homeURL(".codex/sessions"), homeURL(".codex/archived_sessions")],
        cacheFile: "codex.json")

    static let sharedDevin = makeStore(
        provider: .devin, pricing: pricingCatalog(for: .devin),
        projectsRoots: [homeURL(".local/share/devin/cli")],
        cacheFile: "devin.json")

    private static func homeURL(_ sub: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(sub, isDirectory: true)
    }

    private static func cacheURL(_ file: String) -> URL {
        if let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            return cachesDir.appendingPathComponent("CostUsage/\(file)")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".notchi/CostUsage/\(file)")
    }

    private static func pricingCatalog(for config: ProviderConfig) -> PricingCatalog {
        PricingCatalog(config: config, fallbackBundle: .main, snapshotURL: PricingCatalog.defaultSnapshotURL(for: config))
    }

    private static func makeStore(provider: CostProvider, pricing: PricingCatalog,
                                  pricingClock: PricingRefreshClock = PricingRefreshClock(),
                                  projectsRoots: [URL], cacheFile: String) -> CostHistoryStore {
        CostHistoryStore(provider: provider, pricing: pricing, pricingClock: pricingClock,
                         projectsRoots: projectsRoots, cacheURL: cacheURL(cacheFile))
    }
}

/// When a price list was last fetched. Stores sharing a price list share one, so it downloads once.
@MainActor
final class PricingRefreshClock {
    var lastRefresh: Date?
    /// Models that were unpriced when a fetch succeeded, so finding them unpriced again waits a day.
    var fetchedUnpricedModels: Set<String> = []

    // Default arguments are evaluated outside the main actor.
    nonisolated init() {}

    // The isolated-deinit back-deploy shim aborts on macOS 15; this deinit only releases stored properties.
    nonisolated deinit {}
}
