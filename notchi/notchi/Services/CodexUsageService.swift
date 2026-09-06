import Foundation

nonisolated enum CodexRateLimitWindows {
    private static let weeklyWindowMinimumMinutes: Double = 1440

    static func split<Window>(
        primary: Window?,
        secondary: Window?,
        windowMinutes: (Window) -> Double?,
        resetDate: (Window) -> Date?
    ) -> (session: Window?, weekly: Window?) {
        var session: Window?
        var weekly: Window?
        var unsized: [Window] = []

        for window in [primary, secondary].compactMap({ $0 }) {
            guard let minutes = windowMinutes(window) else {
                unsized.append(window)
                continue
            }
            if minutes >= weeklyWindowMinimumMinutes {
                weekly = weekly ?? window
            } else {
                session = session ?? window
            }
        }

        if unsized.count > 1 {
            let byReset = unsized.sorted {
                (resetDate($0) ?? .distantFuture) < (resetDate($1) ?? .distantFuture)
            }
            session = byReset.first
            weekly = byReset.last
        } else if let lone = unsized.first {
            if weekly == nil {
                weekly = lone
            } else {
                session = lone
            }
        }

        return (session, weekly)
    }
}

protocol CodexUsagePollTimer {
    func invalidate()
}

private struct LiveCodexUsagePollTimer: CodexUsagePollTimer {
    let timer: Timer

    func invalidate() {
        timer.invalidate()
    }
}

struct CodexUsageServiceDependencies {
    var loadAuth: @Sendable () -> CodexAuthRead
    var fetchAPIUsage: @Sendable (CodexAPIAuth) async -> CodexAPIUsage?
    var now: @Sendable () -> Date
    var schedulePoll: (TimeInterval, @escaping @MainActor () -> Void) -> any CodexUsagePollTimer = { interval, action in
        LiveCodexUsagePollTimer(timer: Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in action() }
        })
    }

    static let live = CodexUsageServiceDependencies(
        loadAuth: { CodexUsageAPI.loadAuth() },
        fetchAPIUsage: { await CodexUsageAPIClient.fetchLive(auth: $0) },
        now: { Date() }
    )
}

nonisolated enum CodexUsageAPIClient {
    static func fetchLive(auth: CodexAPIAuth) async -> CodexAPIUsage? {
        guard !CodexUsageAPI.isAccessTokenExpired(auth.accessToken, now: Date()) else {
            return nil
        }

        let request = CodexUsageAPI.makeRequest(auth: auth)
        guard let (body, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(CodexUsageAPIResponse.self, from: body) else {
            return nil
        }

        return CodexUsageAPI.usage(from: decoded, now: Date())
    }
}

@MainActor
@Observable
final class CodexUsageService {
    static let shared = CodexUsageService()

    var currentUsage: QuotaPeriod?
    var currentWeeklyUsage: QuotaPeriod?
    var currentReviewsUsage: QuotaPeriod?
    var currentExtraCreditsUSD: Double?
    var isUsageStale = false
    var lastObservedAt: Date?
    var hasUsageData: Bool {
        UsageMetrics.codexHasData(usage: currentUsage, weeklyUsage: currentWeeklyUsage)
    }

    var displayUsage: QuotaPeriod? {
        currentUsage ?? currentWeeklyUsage
    }

    private static let apiUsageRefreshInterval: TimeInterval = 60
    private var lastAPIUsageFetchAt: Date?
    private var currentAccountId: String?
    private var generation: UInt64 = 0
    private var isFetching = false
    private var pollTimer: (any CodexUsagePollTimer)?
    private let dependencies: CodexUsageServiceDependencies

    init(dependencies: CodexUsageServiceDependencies = .live) {
        self.dependencies = dependencies
    }

    func startPolling() {
        stopPolling()
        pollTimer = dependencies.schedulePoll(Self.apiUsageRefreshInterval) { [weak self] in
            Task { await self?.refreshFromAPI() }
        }
        Task { await refreshFromAPI() }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refreshFromAPI() async {
        let auth: CodexAPIAuth
        switch dependencies.loadAuth() {
        case let .authenticated(value):
            auth = value
        case .signedOut:
            clear()
            return
        case .unavailable:
            discardExpiredUsage()
            isUsageStale = hasUsageData
            return
        }
        guard let accountId = auth.accountId, !accountId.isEmpty else { return }
        if accountId != currentAccountId {
            clear()
            currentAccountId = accountId
        }

        let now = dependencies.now()
        discardExpiredUsage()
        guard !isFetching else { return }
        if let last = lastAPIUsageFetchAt, now.timeIntervalSince(last) < Self.apiUsageRefreshInterval {
            return
        }

        isFetching = true
        lastAPIUsageFetchAt = now
        let requestGeneration = generation
        defer {
            if generation == requestGeneration { isFetching = false }
        }
        let fetched = await dependencies.fetchAPIUsage(auth)
        guard generation == requestGeneration else { return }
        switch dependencies.loadAuth() {
        case let .authenticated(latest):
            guard latest.accountId == accountId else {
                clear()
                return
            }
        case .signedOut:
            clear()
            return
        case .unavailable:
            break
        }
        guard let fetched else {
            isUsageStale = hasUsageData
            return
        }

        let observedAt = dependencies.now()
        currentUsage = unexpiredOnly(fetched.session, now: observedAt)
        currentWeeklyUsage = unexpiredOnly(fetched.weekly, now: observedAt)
        currentReviewsUsage = unexpiredOnly(fetched.reviews, now: observedAt)
        currentExtraCreditsUSD = fetched.creditsBalance.map { $0 * CodexUsageAPI.creditUSDRate }
        lastObservedAt = hasUsageData ? observedAt : nil
        isUsageStale = false
    }

    func clear() {
        generation &+= 1
        isFetching = false
        currentAccountId = nil
        currentUsage = nil
        currentWeeklyUsage = nil
        currentReviewsUsage = nil
        currentExtraCreditsUSD = nil
        lastAPIUsageFetchAt = nil
        isUsageStale = false
        lastObservedAt = nil
    }

    private func discardExpiredUsage() {
        let now = dependencies.now()
        currentUsage = unexpiredOnly(currentUsage, now: now)
        currentWeeklyUsage = unexpiredOnly(currentWeeklyUsage, now: now)
        currentReviewsUsage = unexpiredOnly(currentReviewsUsage, now: now)
        if !hasUsageData {
            lastObservedAt = nil
            isUsageStale = false
        }
    }

    private func unexpiredOnly(_ usage: QuotaPeriod?, now: Date) -> QuotaPeriod? {
        guard let resetDate = usage?.resetDate, resetDate <= now else { return usage }
        return nil
    }
}
