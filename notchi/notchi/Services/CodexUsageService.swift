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
            CodexUsageScanner.shared.latestSnapshot(transcriptPaths: transcriptPaths)
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

// WHY: The periodic refresh re-read up to a full tail window per transcript
// every 5 seconds. Tracking a per-path offset keeps steady-state refreshes to
// only the bytes appended since the previous scan, with the tail window as the
// fallback for first sight, truncation, and oversized append bursts.
nonisolated final class CodexUsageScanner: @unchecked Sendable {
    private struct PathScanState {
        var offset: UInt64
        var snapshot: CodexUsageSnapshot?
    }

    static let shared = CodexUsageScanner()

    private let maxTailBytes: Int
    private let lock = NSLock()
    private var states: [String: PathScanState] = [:]
    private var bytesRead: UInt64 = 0

    init(maxTailBytes: Int = CodexUsageSnapshotResolver.defaultMaxTailBytes) {
        self.maxTailBytes = maxTailBytes
    }

    func latestSnapshot(transcriptPaths: [String]) -> CodexUsageSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        let requestedPaths = Set(transcriptPaths)
        states = states.filter { requestedPaths.contains($0.key) }
        return transcriptPaths
            .compactMap { scan(path: $0) }
            .max { lhs, rhs in lhs.observedAt < rhs.observedAt }
    }

    private func scan(path: String) -> CodexUsageSnapshot? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            states[path] = nil
            return nil
        }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else {
            return states[path]?.snapshot
        }

        let previous = states[path]
        let isIncremental = previous.map {
            $0.offset <= fileSize && fileSize - $0.offset <= UInt64(maxTailBytes)
        } ?? false

        if isIncremental, previous?.offset == fileSize {
            return previous?.snapshot
        }

        let tailStart = fileSize > UInt64(maxTailBytes) ? fileSize - UInt64(maxTailBytes) : 0
        let readStart = isIncremental ? previous!.offset : tailStart
        guard (try? handle.seek(toOffset: readStart)) != nil,
              let readData = try? handle.readToEnd() else {
            return previous?.snapshot
        }
        bytesRead += UInt64(readData.count)

        var lineStart = readStart
        var data = readData
        if !isIncremental, readStart > 0,
           !CodexUsageSnapshotResolver.tailBeginsOnLineBoundary(handle, tailOffset: readStart) {
            guard let firstNewline = data.firstIndex(of: UInt8(ascii: "\n")) else {
                states[path] = PathScanState(offset: readStart, snapshot: nil)
                return nil
            }
            let droppedCount = data.distance(from: data.startIndex, to: firstNewline) + 1
            lineStart += UInt64(droppedCount)
            data = Data(data[data.index(after: firstNewline)...])
        }

        // The trailing unterminated line is scanned but the offset stays before
        // it, so a line completed by a later write is parsed again in full.
        let scanned = CodexUsageSnapshotResolver.snapshot(scanningLines: data)
        let carried = isIncremental ? previous?.snapshot : nil
        let best = latest(of: scanned, carried)

        let newOffset: UInt64
        if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
            newOffset = lineStart + UInt64(data.distance(from: data.startIndex, to: lastNewline) + 1)
        } else {
            newOffset = lineStart
        }

        states[path] = PathScanState(offset: newOffset, snapshot: best)
        return best
    }

    private func latest(of lhs: CodexUsageSnapshot?, _ rhs: CodexUsageSnapshot?) -> CodexUsageSnapshot? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return lhs.observedAt >= rhs.observedAt ? lhs : rhs
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

#if DEBUG
    var bytesReadForTesting: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return bytesRead
    }
#endif
}

nonisolated enum CodexUsageSnapshotResolver {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoBasic = ISO8601DateFormatter()

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

        return snapshot(scanningLines: tail)
    }

    static func snapshot(scanningLines data: Data) -> CodexUsageSnapshot? {
        var latestSnapshot: CodexUsageSnapshot?
        let decoder = JSONDecoder()
        let tokenCountMarker = Data(#""token_count""#.utf8)
        for line in data.split(separator: UInt8(ascii: "\n")) {
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

    static func tailBeginsOnLineBoundary(_ fileHandle: FileHandle, tailOffset: UInt64) -> Bool {
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
