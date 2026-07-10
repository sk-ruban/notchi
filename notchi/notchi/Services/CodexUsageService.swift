import Foundation

nonisolated struct CodexUsageSnapshot: Sendable, Equatable {
    let usage: QuotaPeriod
    let weeklyUsage: QuotaPeriod?
    let observedAt: Date
}

nonisolated struct CodexUsageServiceDependencies: Sendable {
    var resolveUsage: @Sendable ([String]) -> CodexUsageSnapshot?
    var fetchAPIUsage: @Sendable () async -> CodexAPIUsage? = { nil }
    var now: @Sendable () -> Date

    static let live = CodexUsageServiceDependencies(
        resolveUsage: { transcriptPaths in
            CodexUsageSnapshotResolver.latestSnapshot(transcriptPaths: transcriptPaths)
        },
        fetchAPIUsage: { await CodexUsageAPIClient.fetchLive() },
        now: { Date() }
    )
}

nonisolated enum CodexUsageAPIClient {
    static func fetchLive() async -> CodexAPIUsage? {
        guard let data = try? Data(contentsOf: CodexUsageAPI.authFileURL()),
              let auth = CodexAPIAuth.load(from: data),
              !CodexUsageAPI.isAccessTokenExpired(auth.accessToken, now: Date()) else {
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
    var statusMessage: String?
    var lastObservedAt: Date?
    var hasUsageData: Bool {
        UsageMetrics.codexHasData(usage: currentUsage, weeklyUsage: currentWeeklyUsage)
    }

    private static let staleObservationInterval: TimeInterval = 15 * 60

    private static let apiUsageRefreshInterval: TimeInterval = 60
    private var lastAPIUsageFetchAt: Date?
    private var lastFetchedAPIUsage: CodexAPIUsage?

    private let dependencies: CodexUsageServiceDependencies

    init(dependencies: CodexUsageServiceDependencies = .live) {
        self.dependencies = dependencies
    }

    func refresh(transcriptPaths: [String]) async {
        let paths = Array(Set(transcriptPaths)).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !paths.isEmpty else {
            clear()
            return
        }

        let resolver = dependencies.resolveUsage
        let snapshot = await Task.detached(priority: .utility) {
            resolver(paths)
        }.value

        apply(snapshot)
        await fetchAndApplyAPIUsage(includeSessionWeekly: false)
    }

    func refreshFromAPI() async {
        await fetchAndApplyAPIUsage(includeSessionWeekly: true)
    }

    private func fetchAndApplyAPIUsage(includeSessionWeekly: Bool) async {
        let now = dependencies.now()
        let apiUsage: CodexAPIUsage?
        if let last = lastAPIUsageFetchAt, now.timeIntervalSince(last) < Self.apiUsageRefreshInterval {
            apiUsage = lastFetchedAPIUsage
        } else {
            lastAPIUsageFetchAt = now
            let fetched = await dependencies.fetchAPIUsage()
            if fetched != nil { lastFetchedAPIUsage = fetched }
            apiUsage = fetched
        }

        guard let apiUsage else { return }
        currentReviewsUsage = apiUsage.reviews
        currentExtraCreditsUSD = apiUsage.creditsBalance.map { $0 * CodexUsageAPI.creditUSDRate }

        if includeSessionWeekly, let session = apiUsage.session {
            currentUsage = session
            currentWeeklyUsage = apiUsage.weekly
            lastObservedAt = now
            isUsageStale = false
            statusMessage = nil
        }
    }

    func clear() {
        currentUsage = nil
        currentWeeklyUsage = nil
        currentReviewsUsage = nil
        currentExtraCreditsUSD = nil
        lastAPIUsageFetchAt = nil
        lastFetchedAPIUsage = nil
        isUsageStale = false
        statusMessage = nil
        lastObservedAt = nil
    }

    private func apply(_ snapshot: CodexUsageSnapshot?) {
        let now = dependencies.now()

        if let snapshot, isUsageStillValid(snapshot.usage, now: now) {
            currentUsage = snapshot.usage
            currentWeeklyUsage = snapshot.weeklyUsage
            lastObservedAt = snapshot.observedAt
            isUsageStale = now.timeIntervalSince(snapshot.observedAt) > Self.staleObservationInterval
            statusMessage = nil
            return
        }

        guard isUsageStillValid(currentUsage, now: now) else {
            clear()
            return
        }

        isUsageStale = true
        statusMessage = nil
    }

    private func isUsageStillValid(_ usage: QuotaPeriod?, now: Date) -> Bool {
        guard let usage, let resetDate = usage.resetDate else {
            return false
        }
        return resetDate > now
    }
}

nonisolated enum CodexUsageSnapshotResolver {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoBasic = ISO8601DateFormatter()

    static func latestSnapshot(transcriptPaths: [String]) -> CodexUsageSnapshot? {
        transcriptPaths
            .compactMap { latestSnapshot(transcriptPath: $0) }
            .max { lhs, rhs in lhs.observedAt < rhs.observedAt }
    }

    // WHY: Rollout files grow unbounded (>100MB in long sessions) and Codex
    // appends fresh token_count events near EOF, so the periodic refresh only
    // needs the file tail; re-reading the whole transcript pegged a core.
    static let defaultMaxTailBytes = 4 * 1024 * 1024

    static func latestSnapshot(
        transcriptPath: String,
        maxTailBytes: Int = defaultMaxTailBytes
    ) -> CodexUsageSnapshot? {
        let trimmedPath = transcriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty,
              let tail = tailData(forFileAtPath: trimmedPath, maxBytes: maxTailBytes) else {
            return nil
        }

        var latestSnapshot: CodexUsageSnapshot?
        let decoder = JSONDecoder()
        let tokenCountMarker = Data(#""token_count""#.utf8)
        for line in tail.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: tokenCountMarker) != nil,
                  let event = try? decoder.decode(CodexTokenCountEvent.self, from: Data(line)),
                  event.payload?.type == "token_count",
                  let primary = event.payload?.rateLimits?.primary,
                  let observedAt = parseDate(event.timestamp) else {
                continue
            }

            let weeklyUsage = event.payload?.rateLimits?.secondary.map { secondary in
                QuotaPeriod(
                    utilization: secondary.usedPercent.rounded(),
                    resetDate: Date(timeIntervalSince1970: secondary.resetsAt)
                )
            }

            let snapshot = CodexUsageSnapshot(
                usage: QuotaPeriod(
                    utilization: primary.usedPercent.rounded(),
                    resetDate: Date(timeIntervalSince1970: primary.resetsAt)
                ),
                weeklyUsage: weeklyUsage,
                observedAt: observedAt
            )
            if latestSnapshot.map({ observedAt > $0.observedAt }) ?? true {
                latestSnapshot = snapshot
            }
        }

        return latestSnapshot
    }

    private static func tailData(forFileAtPath path: String, maxBytes: Int) -> Data? {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fileHandle.close() }

        guard let fileSize = try? fileHandle.seekToEnd() else { return nil }
        let tailOffset = fileSize > UInt64(maxBytes) ? fileSize - UInt64(maxBytes) : 0
        guard (try? fileHandle.seek(toOffset: tailOffset)) != nil,
              let data = try? fileHandle.readToEnd() else {
            return nil
        }

        guard tailOffset > 0 else { return data }

        // A window that begins right after a newline already starts a whole line,
        // so only drop the leading fragment when the seek lands mid-line.
        if tailBeginsOnLineBoundary(fileHandle, tailOffset: tailOffset) {
            return data
        }

        guard let firstNewline = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        return data[data.index(after: firstNewline)...]
    }

    private static func tailBeginsOnLineBoundary(_ fileHandle: FileHandle, tailOffset: UInt64) -> Bool {
        guard (try? fileHandle.seek(toOffset: tailOffset - 1)) != nil,
              let previousByte = try? fileHandle.read(upToCount: 1) else {
            return false
        }
        return previousByte.first == UInt8(ascii: "\n")
    }

    private static func parseDate(_ rawValue: String?) -> Date? {
        guard let rawValue else { return nil }
        return isoFractional.date(from: rawValue) ?? isoBasic.date(from: rawValue)
    }
}

private nonisolated struct CodexTokenCountEvent: Decodable {
    let timestamp: String?
    let payload: Payload?

    struct Payload: Decodable {
        let type: String
        let rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case type
            case rateLimits = "rate_limits"
        }
    }

    struct RateLimits: Decodable {
        let primary: Limit?
        let secondary: Limit?
    }

    struct Limit: Decodable {
        let usedPercent: Double
        let resetsAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetsAt = "resets_at"
        }
    }
}
