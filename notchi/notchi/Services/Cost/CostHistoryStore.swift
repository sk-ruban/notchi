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
    private let pricingRetryInterval: TimeInterval = 60 * 60
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
        // Only this store uses its cache file, so after the first load the copy in memory matches the file.
        let savedCache = OSAllocatedUnfairLock<CostUsageCache?>(initialState: nil)
        self.init(windowDays: windowDays, calendar: calendar, provider: provider, pricingCatalog: pricing,
                  pricingClock: pricingClock) { now in
            await Task.detached(priority: .utility) {
                let sig = pricing.signature()
                let timeZoneID = calendar.timeZone.identifier
                let saved = savedCache.withLock { $0 } ?? CostUsageCacheStore.load(url: cacheURL)
                var updated = scan(saved.reconciled(withPricingSignature: sig, timeZoneIdentifier: timeZoneID), now)
                updated.pricingSignature = sig
                updated.timeZoneIdentifier = timeZoneID
                if updated != saved {
                    CostUsageCacheStore.save(updated, to: cacheURL)
                }
                savedCache.withLock { $0 = updated }
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
              let catalog = pricingCatalog, catalog.canRefreshFromNetwork,
              shouldRefreshPricing(after: buckets, now: now) else { return }
        // The fetch runs outside isScanning so a slow models.dev never blocks timer scans.
        pricingClock.lastRefresh = now
        await catalog.refreshFromNetwork()
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

    /// Fetches once at launch, then again only when a model released since scans unpriced.
    private func shouldRefreshPricing(after buckets: DayModelBuckets, now: Date) -> Bool {
        guard let lastPricingRefresh = pricingClock.lastRefresh else { return true }
        return Self.hasUnpricedRequests(buckets)
            && now.timeIntervalSince(lastPricingRefresh) >= pricingRetryInterval
    }

    private static func hasUnpricedRequests(_ buckets: DayModelBuckets) -> Bool {
        buckets.values.contains { models in
            models.values.contains { $0.pricedCount < $0.requestCount }
        }
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

    // Default arguments are evaluated outside the main actor.
    nonisolated init() {}

    // The isolated-deinit back-deploy shim aborts on macOS 15; this deinit only releases stored properties.
    nonisolated deinit {}
}
