import Foundation
import Observation

@MainActor
@Observable
final class CostHistoryStore {
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
    private let pricingCatalog: PricingCatalog?

    init(windowDays: Int = 30, calendar: Calendar = .current, provider: CostProvider = .claude,
         scanProvider: @escaping @Sendable (Date) async -> DayModelBuckets) {
        self.windowDays = windowDays
        self.calendar = calendar
        self.provider = provider
        self.scanProvider = scanProvider
        self.pricingCatalog = nil
    }

    convenience init(windowDays: Int = 30, calendar: Calendar = .current,
                     provider: CostProvider = .claude,
                     pricing: PricingCatalog,
                     projectsRoots: [URL],
                     cacheURL: URL) {
        let scan = Self.makeScan(provider: provider, projectsRoots: projectsRoots,
                                 pricing: pricing, windowDays: windowDays, calendar: calendar)
        self.init(windowDays: windowDays, calendar: calendar, provider: provider, pricingCatalog: pricing) { now in
            await Task.detached(priority: .utility) {
                let sig = pricing.signature()
                let cache = CostUsageCacheStore.load(url: cacheURL).reconciled(withPricingSignature: sig)
                var updated = scan(cache, now)
                updated.pricingSignature = sig
                CostUsageCacheStore.save(updated, to: cacheURL)
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
        }
    }

    private init(windowDays: Int, calendar: Calendar, provider: CostProvider, pricingCatalog: PricingCatalog,
                 scanProvider: @escaping @Sendable (Date) async -> DayModelBuckets) {
        self.windowDays = windowDays
        self.calendar = calendar
        self.provider = provider
        self.scanProvider = scanProvider
        self.pricingCatalog = pricingCatalog
    }

    func start() {
        guard timer == nil else { return }
        if let catalog = pricingCatalog {
            Task.detached(priority: .utility) { await catalog.refreshFromNetwork() }
        }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        if isScanning { return }
        isScanning = true
        defer { isScanning = false }
        let now = Date()
        let buckets = await scanProvider(now)
        let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1),
                                        to: calendar.startOfDay(for: now))!
        self.buckets = buckets
        report = DailyCostReport.make(
            provider: provider, buckets: buckets,
            windowStart: windowStart, today: now, calendar: calendar)
        lastScan = now
    }
}

// MARK: - Shared singletons

extension CostHistoryStore {
    static let shared = makeStore(
        provider: .claude, config: .claude,
        projectsRoots: [homeURL(".claude/projects")], cacheFile: "claude.json")

    static let sharedCodex = makeStore(
        provider: .codex, config: .codex,
        projectsRoots: [homeURL(".codex/sessions"), homeURL(".codex/archived_sessions")],
        cacheFile: "codex.json")

    private static func homeURL(_ sub: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(sub, isDirectory: true)
    }

    private static func cacheURL(_ file: String) -> URL {
        if let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            return cachesDir.appendingPathComponent("CostUsage/\(file)")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".notchi/CostUsage/\(file)")
    }

    private static func makeStore(provider: CostProvider, config: ProviderConfig,
                                  projectsRoots: [URL], cacheFile: String) -> CostHistoryStore {
        let pricing = PricingCatalog(config: config, fallbackBundle: .main,
                                     snapshotURL: PricingCatalog.defaultSnapshotURL(for: config))
        return CostHistoryStore(provider: provider, pricing: pricing,
                                projectsRoots: projectsRoots, cacheURL: cacheURL(cacheFile))
    }
}
