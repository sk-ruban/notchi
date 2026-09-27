import AppKit

@MainActor
@Observable
final class DevinUsageService {
    static let shared = DevinUsageService()

    var currentUsage: QuotaPeriod?
    var currentWeeklyUsage: QuotaPeriod?
    var lastObservedAt: Date?
    var isUsageStale = false

    var hasUsageData: Bool {
        currentUsage != nil || currentWeeklyUsage != nil
    }

    static let desktopBundleIdentifier = "com.exafunction.windsurf"

    private static let refreshInterval: TimeInterval = 60
    private let readUsage: @Sendable (Date) -> DevinUsage?
    private let now: @Sendable () -> Date
    private let isDesktopRunning: @MainActor () -> Bool
    private var pollTimer: Timer?
    private var isRefreshing = false

    init(
        readUsage: @escaping @Sendable (Date) -> DevinUsage? = { DevinUsageReader.readUsage(now: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
        isDesktopRunning: @escaping @MainActor () -> Bool = {
            !NSRunningApplication.runningApplications(withBundleIdentifier: DevinUsageService.desktopBundleIdentifier).isEmpty
        }
    ) {
        self.readUsage = readUsage
        self.now = now
        self.isDesktopRunning = isDesktopRunning
    }

    func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let observedAt = now()
        let readUsage = readUsage
        let usage = await Task.detached(priority: .utility) { readUsage(observedAt) }.value

        currentUsage = usage?.daily
        currentWeeklyUsage = usage?.weekly
        lastObservedAt = hasUsageData ? observedAt : nil
        isUsageStale = hasUsageData && !isDesktopRunning()
    }
}
