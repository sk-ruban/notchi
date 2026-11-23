import Foundation
import XCTest
@testable import notchi

final class PollSchedulerEntry {
    let interval: TimeInterval
    let handler: () -> Void
    var isInvalidated = false

    init(interval: TimeInterval, handler: @escaping () -> Void) {
        self.interval = interval
        self.handler = handler
    }
}

struct TestPollTimer: ClaudeUsagePollTimer {
    let invalidateHandler: () -> Void

    func invalidate() {
        invalidateHandler()
    }
}

@MainActor
final class PollSchedulerSpy {
    private(set) var intervals: [TimeInterval] = []
    private var entries: [PollSchedulerEntry] = []

    func schedule(after interval: TimeInterval, handler: @escaping () -> Void) -> any ClaudeUsagePollTimer {
        intervals.append(interval)
        let entry = PollSchedulerEntry(interval: interval, handler: handler)
        entries.append(entry)
        return TestPollTimer {
            entry.isInvalidated = true
        }
    }

    func fireLast() {
        fire(at: entries.count - 1)
    }

    func fire(at index: Int) {
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        guard !entry.isInvalidated else { return }
        entry.handler()
    }
}

final class RequestRecorder {
    private(set) var paths: [String] = []

    @discardableResult
    func record(_ request: URLRequest) -> String {
        let path = request.url?.path ?? ""
        paths.append(path)
        return path
    }

    func reset() {
        paths.removeAll()
    }

    func assertOAuthOnly(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(paths, ["/api/oauth/usage"], file: file, line: line)
    }

    func assertHeadersOnly(
        count: Int = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(paths, Array(repeating: "/v1/messages", count: count), file: file, line: line)
    }

    func assertMixed(
        _ expected: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(paths, expected, file: file, line: line)
    }
}

@MainActor
final class ClaudeUsageServiceTests: XCTestCase {
    override func tearDown() {
        AppSettings.isUsageEnabled = false
        AppSettings.claudeExtraUsageObservation = nil
        ClaudeConfigDirectoryResolver.resetTestingHooks()
        ClaudeCLIResolver.resetTestingHooks()
        super.tearDown()
    }

    func makeDependencies(
        scheduler: PollSchedulerSpy,
        resolveUserAgent: @escaping () -> String?,
        getOAuthTokenFromEnvironment: @escaping () -> String? = { nil },
        getCachedOAuthToken: @escaping () -> String? = { nil },
        getOAuthCredentials: @escaping (_ allowInteraction: Bool) -> ClaudeOAuthCredentials? = { _ in nil },
        cacheOAuthToken: @escaping (_ token: String) -> Void = { _ in },
        refreshAccessTokenSilently: @escaping () -> String? = { nil },
        clearCachedOAuthToken: @escaping () -> Void = {},
        loadRecoverySnapshot: @escaping () -> ClaudeUsageRecoverySnapshot? = { nil },
        saveRecoverySnapshot: @escaping (ClaudeUsageRecoverySnapshot) -> Void = { _ in },
        clearRecoverySnapshot: @escaping () -> Void = {},
        now: @escaping () -> Date = { Date() },
        fetchUsage: @escaping (URLRequest) async throws -> (Data, URLResponse)
    ) -> ClaudeUsageServiceDependencies {
        ClaudeUsageServiceDependencies(
            fetchUsage: fetchUsage,
            getOAuthTokenFromEnvironment: getOAuthTokenFromEnvironment,
            getCachedOAuthToken: getCachedOAuthToken,
            getOAuthCredentials: getOAuthCredentials,
            cacheOAuthToken: cacheOAuthToken,
            refreshAccessTokenSilently: refreshAccessTokenSilently,
            clearCachedOAuthToken: clearCachedOAuthToken,
            loadRecoverySnapshot: loadRecoverySnapshot,
            saveRecoverySnapshot: saveRecoverySnapshot,
            clearRecoverySnapshot: clearRecoverySnapshot,
            resolveUserAgent: resolveUserAgent,
            pollJitter: { 0 },
            now: now,
            schedulePoll: { interval, handler in
                scheduler.schedule(after: interval, handler: handler)
            }
        )
    }

    func makeService(
        now: @escaping () -> Date = { Date() },
        cachedToken: @escaping () -> String? = { nil },
        snapshot: @escaping () -> ClaudeUsageRecoverySnapshot? = { nil },
        fetchUsage: @escaping (URLRequest) async throws -> (Data, URLResponse)
    ) -> (service: ClaudeUsageService, scheduler: PollSchedulerSpy) {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { cachedToken() },
            loadRecoverySnapshot: snapshot,
            now: now,
            fetchUsage: fetchUsage
        )
        return (ClaudeUsageService(dependencies: dependencies), scheduler)
    }

    func oauthSequence(
        recorder: RequestRecorder,
        oauth: @escaping (_ call: Int, _ request: URLRequest) -> (Data, URLResponse),
        headers: @escaping (_ call: Int, _ request: URLRequest) -> (Data, URLResponse)
    ) -> (URLRequest) async throws -> (Data, URLResponse) {
        var oauthCalls = 0
        var headersCalls = 0

        return { request in
            let path = recorder.record(request)
            if path == "/api/oauth/usage" {
                oauthCalls += 1
                return oauth(oauthCalls, request)
            }

            XCTAssertEqual(path, "/v1/messages")
            headersCalls += 1
            return headers(headersCalls, request)
        }
    }

    func oauth429ThenHeaders(
        recorder: RequestRecorder,
        retryAfter: String? = nil,
        headers: @escaping (_ call: Int, _ request: URLRequest) -> (Data, URLResponse)
    ) -> (URLRequest) async throws -> (Data, URLResponse) {
        oauthSequence(
            recorder: recorder,
            oauth: { _, _ in
                let headersMap = retryAfter.map { ["Retry-After": $0] } ?? [:]
                return (Data(), self.makeResponse(statusCode: 429, headers: headersMap))
            },
            headers: headers
        )
    }

    func oauth403ThenHeaders(
        recorder: RequestRecorder,
        oauthResponse: @escaping () -> (Data, URLResponse),
        headers: @escaping (_ call: Int, _ request: URLRequest) -> (Data, URLResponse)
    ) -> (URLRequest) async throws -> (Data, URLResponse) {
        oauthSequence(
            recorder: recorder,
            oauth: { _, _ in oauthResponse() },
            headers: headers
        )
    }

    func makeSuccessPayload(
        utilization: Double,
        resetAt: String = "2099-01-01T01:00:00Z",
        weeklyUtilization: Double? = nil,
        weeklyResetAt: String = "2099-01-08T01:00:00Z",
        sonnetUtilization: Double? = nil,
        opusUtilization: Double? = nil,
        scopedWeeklyLimit: (modelName: String, percent: Double)? = nil,
        extraUsage: ExtraUsage? = nil
    ) -> Data {
        var payload: [String: Any] = [
            "five_hour": [
                "utilization": utilization,
                "resets_at": resetAt,
            ],
            "seven_day": weeklyUtilization.map { weekly in
                ["utilization": weekly, "resets_at": weeklyResetAt] as [String: Any]
            } ?? NSNull(),
        ]

        if let sonnetUtilization {
            payload["seven_day_sonnet"] = ["utilization": sonnetUtilization]
        }

        if let opusUtilization {
            payload["seven_day_opus"] = ["utilization": opusUtilization]
        }

        if let scopedWeeklyLimit {
            payload["limits"] = [
                [
                    "kind": "session",
                    "percent": utilization,
                    "resets_at": resetAt,
                    "scope": NSNull(),
                ],
                [
                    "kind": "weekly_all",
                    "percent": weeklyUtilization ?? 0,
                    "resets_at": weeklyResetAt,
                    "scope": NSNull(),
                ],
                [
                    "kind": "weekly_scoped",
                    "percent": scopedWeeklyLimit.percent,
                    "resets_at": weeklyResetAt,
                    "scope": [
                        "model": [
                            "id": NSNull(),
                            "display_name": scopedWeeklyLimit.modelName,
                        ],
                        "surface": NSNull(),
                    ],
                ] as [String: Any],
            ]
        }

        if let extraUsage {
            payload["extra_usage"] = [
                "is_enabled": extraUsage.isEnabled,
                "monthly_limit": extraUsage.monthlyLimit.map { $0 as Any } ?? NSNull(),
                "used_credits": extraUsage.usedCredits.map { $0 as Any } ?? NSNull(),
                "utilization": extraUsage.utilization.map { $0 as Any } ?? NSNull(),
            ]
        }

        return try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    var messagesURL: URL { URL(string: "https://api.anthropic.com/v1/messages")! }

    func makeQuotaPeriod(utilization: Double) -> QuotaPeriod {
        QuotaPeriod(utilization: utilization, resetsAt: "2099-01-01T01:00:00Z")
    }

    func makeRecoverySnapshot(
        oauthBackoffUntil: Date? = nil,
        oauthHeadersFallbackProbeUntil: Date? = nil,
        isHeadersFallbackActive: Bool = false,
        lastGoodUsage: QuotaPeriod? = nil,
        lastGoodWeeklyUsage: QuotaPeriod? = nil,
        lastGoodModelUsage: QuotaPeriod? = nil,
        lastGoodModelUsageName: String? = nil,
        lastGoodExtraUsage: ExtraUsage? = nil,
        lastObservedExtraUsageCredits: Double? = nil,
        extraUsageResetMarker: String? = nil,
        isUsingExtraUsage: Bool? = nil
    ) -> ClaudeUsageRecoverySnapshot {
        ClaudeUsageRecoverySnapshot(
            oauthBackoffUntil: oauthBackoffUntil,
            oauthHeadersFallbackProbeUntil: oauthHeadersFallbackProbeUntil,
            isHeadersFallbackActive: isHeadersFallbackActive,
            lastGoodUsage: lastGoodUsage,
            lastGoodWeeklyUsage: lastGoodWeeklyUsage,
            lastGoodModelUsage: lastGoodModelUsage,
            lastGoodModelUsageName: lastGoodModelUsageName,
            lastGoodExtraUsage: lastGoodExtraUsage,
            lastObservedExtraUsageCredits: lastObservedExtraUsageCredits,
            extraUsageResetMarker: extraUsageResetMarker,
            isUsingExtraUsage: isUsingExtraUsage
        )
    }

    func makeResponse(statusCode: Int, headers: [String: String] = [:], url: URL? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url ?? URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    func makeHeadersResponse(utilization: String, reset: String?, statusCode: Int = 200) -> HTTPURLResponse {
        var headers: [String: String] = [
            "anthropic-ratelimit-unified-5h-utilization": utilization,
        ]
        if let reset {
            headers["anthropic-ratelimit-unified-5h-reset"] = reset
        }
        return HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    func makeAnthropicErrorPayload(
        type: String,
        message: String,
        requestID: String = "req_test_123"
    ) -> Data {
        let payload: [String: Any] = [
            "type": "error",
            "error": [
                "type": type,
                "message": message,
            ],
            "request_id": requestID,
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    func makeCredentials(
        accessToken: String,
        expiresAt: Date? = nil,
        scopes: Set<String> = []
    ) -> ClaudeOAuthCredentials {
        ClaudeOAuthCredentials(
            accessToken: accessToken,
            expiresAt: expiresAt,
            scopes: scopes
        )
    }
}
