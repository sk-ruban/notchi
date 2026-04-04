import Foundation
import XCTest
@testable import notchi

private final class PollSchedulerEntry {
    let interval: TimeInterval
    let handler: () -> Void
    var isInvalidated = false

    init(interval: TimeInterval, handler: @escaping () -> Void) {
        self.interval = interval
        self.handler = handler
    }
}

private struct TestPollTimer: ClaudeUsagePollTimer {
    let invalidateHandler: () -> Void

    func invalidate() {
        invalidateHandler()
    }
}

@MainActor
private final class PollSchedulerSpy {
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

private final class RequestRecorder {
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

private struct ResolverProcessCall: Equatable {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]?
}

@MainActor
final class ClaudeUsageServiceTests: XCTestCase {
    override func tearDown() {
        AppSettings.isUsageEnabled = false
        AppSettings.claudeUsageRecoverySnapshot = nil
        ClaudeConfigDirectoryResolver.resetTestingHooks()
        ClaudeCLIResolver.resetTestingHooks()
        super.tearDown()
    }

    func testClaudeConfigDirectoryResolverUsesProcessEnvironment() {
        ClaudeConfigDirectoryResolver.testHooks = .init(
            environment: { ["CLAUDE_CONFIG_DIR": "/tmp/claude-config"] },
            isExecutableFile: { _ in false },
            runProcess: { _, _, _ in
                XCTFail("Shell probing should not run when the environment already provides CLAUDE_CONFIG_DIR")
                return nil
            }
        )

        let resolution = ClaudeConfigDirectoryResolver.resolve()

        XCTAssertEqual(resolution.path, "/tmp/claude-config")
        XCTAssertEqual(resolution.source, .environment)
    }

    func testClaudeConfigDirectoryResolverFallsBackToShell() {
        var processCalls: [[String]] = []
        ClaudeConfigDirectoryResolver.testHooks = .init(
            environment: { ["SHELL": "/mock/zsh"] },
            isExecutableFile: { path in
                path == "/mock/zsh"
            },
            runProcess: { _, arguments, _ in
                processCalls.append(arguments)
                if arguments == ["-lc", "printf '%s' \"$CLAUDE_CONFIG_DIR\""] {
                    return "/tmp/from-shell\n"
                }
                return nil
            }
        )

        let resolution = ClaudeConfigDirectoryResolver.resolve()

        XCTAssertEqual(resolution.path, "/tmp/from-shell")
        XCTAssertEqual(resolution.source, .shell)
        XCTAssertEqual(processCalls, [["-lc", "printf '%s' \"$CLAUDE_CONFIG_DIR\""]])
    }

    func testClaudeConfigDirectoryResolverExtractsPathFromNoisyShellOutput() {
        ClaudeConfigDirectoryResolver.testHooks = .init(
            environment: { ["SHELL": "/mock/zsh"] },
            isExecutableFile: { path in
                path == "/mock/zsh"
            },
            runProcess: { _, arguments, _ in
                if arguments == ["-lc", "printf '%s' \"$CLAUDE_CONFIG_DIR\""] {
                    return "warning: plugin loaded\n/tmp/from-shell\n"
                }
                return nil
            }
        )

        let resolution = ClaudeConfigDirectoryResolver.resolve()

        XCTAssertEqual(resolution.path, "/tmp/from-shell")
        XCTAssertEqual(resolution.source, .shell)
    }

    func testClaudeConfigDirectoryResolverFallsBackToInteractiveShell() {
        var processCalls: [[String]] = []
        ClaudeConfigDirectoryResolver.testHooks = .init(
            environment: { ["SHELL": "/mock/zsh"] },
            isExecutableFile: { path in
                path == "/mock/zsh"
            },
            runProcess: { _, arguments, _ in
                processCalls.append(arguments)
                if arguments == ["-ic", "printf '%s' \"$CLAUDE_CONFIG_DIR\""] {
                    return "~/custom-claude\n"
                }
                return nil
            }
        )

        let resolution = ClaudeConfigDirectoryResolver.resolve()

        XCTAssertTrue(resolution.path.hasSuffix("/custom-claude"))
        XCTAssertEqual(resolution.source, .shell)
        XCTAssertEqual(
            processCalls,
            [
                ["-lc", "printf '%s' \"$CLAUDE_CONFIG_DIR\""],
                ["-ic", "printf '%s' \"$CLAUDE_CONFIG_DIR\""],
            ]
        )
    }

    func testClaudeConfigDirectoryResolverFallsBackToDefaultDirectory() {
        ClaudeConfigDirectoryResolver.testHooks = .init(
            environment: { [:] },
            isExecutableFile: { _ in false },
            runProcess: { _, _, _ in nil }
        )

        let resolution = ClaudeConfigDirectoryResolver.resolve()
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        XCTAssertEqual(resolution.path, "\(home)/.claude")
        XCTAssertEqual(resolution.source, .fallback)
    }

    func testResolveUserAgentUsesClaudeBinaryFromResolvedConfigDirectory() {
        let claudePath = "/tmp/custom-claude/bin/claude"
        ClaudeConfigDirectoryResolver.testHooks = .init(
            environment: { ["CLAUDE_CONFIG_DIR": "/tmp/custom-claude"] },
            isExecutableFile: { _ in false },
            runProcess: { _, _, _ in nil }
        )

        var processCalls: [(String, [String])] = []
        ClaudeCLIResolver.testHooks = .init(
            environment: { [:] },
            isExecutableFile: { path in
                path == claudePath
            },
            runProcess: { executablePath, arguments, _ in
                processCalls.append((executablePath, arguments))
                return "2.1.92 (Claude Code)\n"
            }
        )

        let userAgent = ClaudeCLIResolver.resolveUserAgent()

        XCTAssertEqual(userAgent, "claude-code/2.1.92")
        XCTAssertEqual(processCalls.count, 1)
        XCTAssertEqual(processCalls.first?.0, claudePath)
        XCTAssertEqual(processCalls.first?.1, ["--version"])
    }

    func testSuccessfulFetchClearsStaleStateAndSchedulesNormalPolling() async throws {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
                XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "claude-code/2.1.77")
                return (self.makeSuccessPayload(utilization: 42), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.currentUsage = makeQuotaPeriod(utilization: 8)
        service.error = "Old error"
        service.statusMessage = "Updating in 120s"
        service.isUsageStale = true
        service.recoveryAction = .retry

        await service.performFetch(with: "token")

        XCTAssertEqual(service.currentUsage?.usagePercentage, 42)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testStartPollingDuringActiveHeadersFallbackDoesNotSendOAuthImmediately() async throws {
        let now = Date(timeIntervalSince1970: 100)
        let recorder = RequestRecorder()
        let (service, scheduler) = makeService(
            now: { now },
            cachedToken: { "token" },
            fetchUsage: oauth429ThenHeaders(recorder: recorder) { _, _ in
                (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
            }
        )
        service.currentUsage = self.makeQuotaPeriod(utilization: 46)
        await service.performFetch(with: "token")
        recorder.assertMixed(["/api/oauth/usage", "/v1/messages"])

        recorder.reset()
        service.startPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(recorder.paths.isEmpty)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 46)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60, 60])
    }

    func testStartPollingRestoresPersistedActiveHeadersFallbackState() async throws {
        let scheduler = PollSchedulerSpy()
        let now = Date(timeIntervalSince1970: 100)
        var fetchCalled = false
        let snapshot = makeRecoverySnapshot(
            oauthHeadersFallbackProbeUntil: now.addingTimeInterval(600),
            isHeadersFallbackActive: true,
            lastGoodUsage: makeQuotaPeriod(utilization: 46)
        )
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { _ in "token" },
            loadRecoverySnapshot: { snapshot },
            now: { now },
            fetchUsage: { _ in
                fetchCalled = true
                return (self.makeSuccessPayload(utilization: 20), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(fetchCalled)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 46)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testStartPollingRestoresPersistedOAuthBackoffState() async throws {
        let scheduler = PollSchedulerSpy()
        let now = Date(timeIntervalSince1970: 100)
        var fetchCalled = false
        let snapshot = makeRecoverySnapshot(
            oauthBackoffUntil: now.addingTimeInterval(120),
            lastGoodUsage: makeQuotaPeriod(utilization: 52)
        )
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { _ in "token" },
            loadRecoverySnapshot: { snapshot },
            now: { now },
            fetchUsage: { _ in
                fetchCalled = true
                return (self.makeSuccessPayload(utilization: 20), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(fetchCalled)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 52)
        XCTAssertNil(service.error)
        XCTAssertEqual(service.statusMessage, "Updating in 120s")
        XCTAssertTrue(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .retry)
        XCTAssertEqual(scheduler.intervals, [120])
    }

    func testExpiredPersistedRecoveryStateIsClearedAndLiveFetchRuns() async throws {
        let scheduler = PollSchedulerSpy()
        let now = Date(timeIntervalSince1970: 100)
        var clearCalls = 0
        var requestURLs: [String] = []
        let snapshot = makeRecoverySnapshot(
            oauthBackoffUntil: now.addingTimeInterval(-5),
            lastGoodUsage: makeQuotaPeriod(utilization: 40)
        )
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { _ in "token" },
            loadRecoverySnapshot: { snapshot },
            clearRecoverySnapshot: { clearCalls += 1 },
            now: { now },
            fetchUsage: { request in
                requestURLs.append(request.url?.path ?? "")
                return (self.makeSuccessPayload(utilization: 33), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(clearCalls, 2)
        XCTAssertEqual(requestURLs, ["/api/oauth/usage"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 33)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testSuccessfulOAuthAfterRestoredBackoffClearsPersistedRecoveryState() async throws {
        let scheduler = PollSchedulerSpy()
        var now = Date(timeIntervalSince1970: 100)
        var storedSnapshot: ClaudeUsageRecoverySnapshot? = makeRecoverySnapshot(
            oauthBackoffUntil: now.addingTimeInterval(5),
            lastGoodUsage: makeQuotaPeriod(utilization: 41)
        )
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { _ in "token" },
            loadRecoverySnapshot: { storedSnapshot },
            saveRecoverySnapshot: { storedSnapshot = $0 },
            clearRecoverySnapshot: { storedSnapshot = nil },
            now: { now },
            fetchUsage: { request in
                requestURLs.append(request.url?.path ?? "")
                return (self.makeSuccessPayload(utilization: 35), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()
        XCTAssertNotNil(storedSnapshot)
        XCTAssertTrue(requestURLs.isEmpty)

        now = now.addingTimeInterval(6)
        scheduler.fireLast()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(requestURLs, ["/api/oauth/usage"])
        XCTAssertNil(storedSnapshot)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 35)
        XCTAssertEqual(scheduler.intervals, [60, 60])
    }

    func testConnectAndStartPollingClearsPersistedRecoveryState() async throws {
        let scheduler = PollSchedulerSpy()
        var clearCalls = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { _ in "token" },
            clearRecoverySnapshot: { clearCalls += 1 },
            fetchUsage: { _ in
                (self.makeSuccessPayload(utilization: 27), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.connectAndStartPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(clearCalls, 2)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 27)
    }

    func testRateLimitWithoutCachedUsageShowsRetryState() async throws {
        let recorder = RequestRecorder()
        let (service, scheduler) = makeService(
            fetchUsage: oauth429ThenHeaders(recorder: recorder, retryAfter: "0") { _, _ in
                (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
            }
        )
        await service.performFetch(with: "token")

        recorder.assertMixed(["/api/oauth/usage", "/v1/messages"])
        XCTAssertNil(service.currentUsage)
        XCTAssertEqual(service.error, "Rate limited, retrying in 120s")
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .retry)
        XCTAssertEqual(scheduler.intervals, [120])
    }

    func testPositiveRetryAfterHeaderRaisesBackoffDelay() async throws {
        let recorder = RequestRecorder()
        let (service, scheduler) = makeService(
            fetchUsage: oauth429ThenHeaders(recorder: recorder, retryAfter: "300") { _, _ in
                (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
            }
        )
        await service.performFetch(with: "token")

        recorder.assertMixed(["/api/oauth/usage", "/v1/messages"])
        XCTAssertEqual(service.error, "Rate limited, retrying in 300s")
        XCTAssertEqual(scheduler.intervals, [300])
    }

    func testRateLimitWithCachedUsageKeepsLastGoodValueCurrentDuringActiveFallback() async throws {
        let scheduler = PollSchedulerSpy()
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                switch requestURLs.count {
                case 1:
                    return (self.makeSuccessPayload(utilization: 55), self.makeResponse(statusCode: 200))
                case 2:
                    return (Data(), self.makeResponse(statusCode: 429))
                default:
                    XCTAssertEqual(path, "/v1/messages")
                    return (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
                }
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")
        await service.performFetch(with: "token")

        XCTAssertEqual(requestURLs, ["/api/oauth/usage", "/api/oauth/usage", "/v1/messages"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 55)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60, 60])
    }

    func testManualRetryDuringActiveBackoffDoesNotSendOAuthAgainWhenHeadersAlreadyTried() async throws {
        let now = Date(timeIntervalSince1970: 100)
        let recorder = RequestRecorder()
        let (service, scheduler) = makeService(
            now: { now },
            cachedToken: { "token" },
            fetchUsage: oauth429ThenHeaders(recorder: recorder) { _, _ in
                (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
            }
        )
        service.startPolling()
        await Task.yield()
        await Task.yield()
        service.retryNow()
        await Task.yield()
        await Task.yield()

        recorder.assertMixed(["/api/oauth/usage", "/v1/messages"])
        XCTAssertEqual(service.error, "Rate limited, retrying in 120s")
        XCTAssertNil(service.statusMessage)
        XCTAssertEqual(service.recoveryAction, .retry)
        XCTAssertEqual(scheduler.intervals, [120, 120])
    }

    func testRetryAfterBackoffExpiryUsesOAuthAgainAndClearsBackoffState() async throws {
        var now = Date(timeIntervalSince1970: 100)
        let recorder = RequestRecorder()
        let (service, scheduler) = makeService(
            now: { now },
            cachedToken: { "token" },
            fetchUsage: oauthSequence(
                recorder: recorder,
                oauth: { call, request in
                    XCTAssertEqual(request.url?.path, "/api/oauth/usage")
                    if call == 1 {
                        return (Data(), self.makeResponse(statusCode: 429))
                    }
                    return (self.makeSuccessPayload(utilization: 37), self.makeResponse(statusCode: 200))
                },
                headers: { _, _ in
                    (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
                }
            )
        )
        service.startPolling()
        await Task.yield()
        await Task.yield()

        now = now.addingTimeInterval(121)
        service.retryNow()
        await Task.yield()
        await Task.yield()

        recorder.assertMixed(["/api/oauth/usage", "/v1/messages", "/api/oauth/usage"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 37)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [120, 60])
    }

    func testSuccessfulHeadersFallbackDefersOAuthProbeForTenMinutes() async throws {
        var now = Date(timeIntervalSince1970: 100)
        let recorder = RequestRecorder()
        let (service, scheduler) = makeService(
            now: { now },
            cachedToken: { "token" },
            fetchUsage: oauthSequence(
                recorder: recorder,
                oauth: { call, _ in
                    if call == 1 {
                        return (Data(), self.makeResponse(statusCode: 429))
                    }
                    return (self.makeSuccessPayload(utilization: 37), self.makeResponse(statusCode: 200))
                },
                headers: { _, _ in
                    (
                        Data(),
                        self.makeHeadersResponse(
                            utilization: "0.41",
                            reset: "2099-01-01T01:00:00Z"
                        )
                    )
                }
            )
        )
        service.startPolling()
        await Task.yield()
        await Task.yield()

        recorder.assertMixed(["/api/oauth/usage", "/v1/messages"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 41)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60])

        recorder.reset()
        now = now.addingTimeInterval(60)
        scheduler.fireLast()
        await Task.yield()
        await Task.yield()

        recorder.assertHeadersOnly()
        XCTAssertEqual(service.currentUsage?.usagePercentage, 41)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60, 60])

        recorder.reset()
        now = Date(timeIntervalSince1970: 701)
        scheduler.fireLast()
        await Task.yield()
        await Task.yield()

        recorder.assertOAuthOnly()
        XCTAssertEqual(service.currentUsage?.usagePercentage, 37)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60, 60, 60])
    }

    func testSystemWakeDuringActiveHeadersFallbackRefreshesHeadersAndResetsProbeWindow() async throws {
        var now = Date(timeIntervalSince1970: 100)
        let recorder = RequestRecorder()
        let (service, scheduler) = makeService(
            now: { now },
            cachedToken: { "token" },
            fetchUsage: oauthSequence(
                recorder: recorder,
                oauth: { call, _ in
                    if call == 1 {
                        return (Data(), self.makeResponse(statusCode: 429))
                    }
                    return (self.makeSuccessPayload(utilization: 37), self.makeResponse(statusCode: 200))
                },
                headers: { call, _ in
                    let utilization: String
                    switch call {
                    case 1:
                        utilization = "0.41"
                    case 2:
                        utilization = "0.42"
                    default:
                        utilization = "0.43"
                    }
                    return (
                        Data(),
                        self.makeHeadersResponse(
                            utilization: utilization,
                            reset: "2099-01-01T01:00:00Z"
                        )
                    )
                }
            )
        )

        service.startPolling()
        await Task.yield()
        await Task.yield()

        recorder.assertMixed(["/api/oauth/usage", "/v1/messages"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 41)

        recorder.reset()
        now = Date(timeIntervalSince1970: 1000)
        service.startPolling(afterSystemWake: true)
        await Task.yield()
        await Task.yield()

        recorder.assertHeadersOnly()
        XCTAssertEqual(service.currentUsage?.usagePercentage, 42)
        XCTAssertEqual(scheduler.intervals, [60, 60])

        recorder.reset()
        now = now.addingTimeInterval(60)
        scheduler.fireLast()
        await Task.yield()
        await Task.yield()

        recorder.assertHeadersOnly()
        XCTAssertEqual(service.currentUsage?.usagePercentage, 43)
        XCTAssertEqual(scheduler.intervals, [60, 60, 60])
    }

    func testRetryDuringSuccessfulHeadersFallbackDoesNotForceOAuthProbe() async throws {
        let now = Date(timeIntervalSince1970: 100)
        let recorder = RequestRecorder()
        let (service, scheduler) = makeService(
            now: { now },
            cachedToken: { "token" },
            fetchUsage: oauth429ThenHeaders(recorder: recorder) { _, _ in
                (
                    Data(),
                    self.makeHeadersResponse(
                        utilization: "0.42",
                        reset: "2099-01-01T01:00:00Z"
                    )
                )
            }
        )
        service.startPolling()
        await Task.yield()
        await Task.yield()

        service.retryNow()
        await Task.yield()
        await Task.yield()

        recorder.assertMixed(["/api/oauth/usage", "/v1/messages"])
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60, 60])
    }

    func testActiveHeadersFallbackRefreshUsesHeadersAndKeepsUsageCurrent() async throws {
        var now = Date(timeIntervalSince1970: 100)
        let recorder = RequestRecorder()
        let (service, scheduler) = makeService(
            now: { now },
            cachedToken: { "token" },
            fetchUsage: oauth429ThenHeaders(recorder: recorder) { call, _ in
                (
                    Data(),
                    self.makeHeadersResponse(
                        utilization: call == 1 ? "0.42" : "0.43",
                        reset: "2099-01-01T01:00:00Z"
                    )
                )
            }
        )
        service.startPolling()
        await Task.yield()
        await Task.yield()

        recorder.reset()
        now = now.addingTimeInterval(60)
        scheduler.fireLast()
        await Task.yield()
        await Task.yield()

        recorder.assertHeadersOnly()
        XCTAssertEqual(service.currentUsage?.usagePercentage, 43)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60, 60])
    }

    func testActiveHeadersFallbackMissKeepsLastGoodUsageVisible() async throws {
        var now = Date(timeIntervalSince1970: 100)
        let recorder = RequestRecorder()
        let (service, scheduler) = makeService(
            now: { now },
            cachedToken: { "token" },
            fetchUsage: oauth429ThenHeaders(recorder: recorder) { call, _ in
                if call == 1 {
                    return (
                        Data(),
                        self.makeHeadersResponse(
                            utilization: "0.42",
                            reset: "2099-01-01T01:00:00Z"
                        )
                    )
                }
                return (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
            }
        )
        service.startPolling()
        await Task.yield()
        await Task.yield()

        recorder.reset()
        now = now.addingTimeInterval(60)
        scheduler.fireLast()
        await Task.yield()
        await Task.yield()

        recorder.assertHeadersOnly()
        XCTAssertEqual(service.currentUsage?.usagePercentage, 42)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60, 60])
    }

    func testOAuthProbe429RestartsHeadersFallbackCycleCleanly() async throws {
        var now = Date(timeIntervalSince1970: 100)
        let recorder = RequestRecorder()
        let (service, scheduler) = makeService(
            now: { now },
            cachedToken: { "token" },
            fetchUsage: oauthSequence(
                recorder: recorder,
                oauth: { _, _ in
                    (Data(), self.makeResponse(statusCode: 429))
                },
                headers: { call, _ in
                    (
                        Data(),
                        self.makeHeadersResponse(
                            utilization: call == 1 ? "0.42" : "0.45",
                            reset: "2099-01-01T01:00:00Z"
                        )
                    )
                }
            )
        )
        service.startPolling()
        await Task.yield()
        await Task.yield()

        recorder.reset()
        now = Date(timeIntervalSince1970: 701)
        scheduler.fireLast()
        await Task.yield()
        await Task.yield()

        recorder.assertMixed(["/api/oauth/usage", "/v1/messages"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 45)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60, 60])
    }

    func testHeadersFallbackResetsRateLimitCounterBeforeLaterOAuthProbe() async throws {
        let scheduler = PollSchedulerSpy()
        var now = Date(timeIntervalSince1970: 100)
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { _ in "token" },
            now: { now },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 429))
                }
                return (
                    Data(),
                    self.makeHeadersResponse(
                        utilization: "0.42",
                        reset: "2099-01-01T01:00:00Z"
                    )
                )
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()

        requestURLs.removeAll()
        now = Date(timeIntervalSince1970: 701)
        scheduler.fireLast()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(requestURLs, ["/api/oauth/usage", "/v1/messages"])
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60, 60])
    }

    func testMissingClaudeCLIStopsBeforeSendingRequest() async throws {
        let scheduler = PollSchedulerSpy()
        var fetchCalled = false
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { nil },
            fetchUsage: { _ in
                fetchCalled = true
                return (Data(), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertFalse(fetchCalled)
        XCTAssertEqual(service.error, "Install Claude Code CLI to continue")
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testShellResolverUsesLoginShellResultWithoutInteractiveFallback() {
        var processCalls: [[String]] = []
        ClaudeCLIResolver.testHooks = .init(
            environment: { [:] },
            isExecutableFile: { path in
                path == "/mock/zsh" || path == "/resolved/claude"
            },
            runProcess: { executablePath, arguments, _ in
                XCTAssertEqual(executablePath, "/mock/zsh")
                processCalls.append(arguments)
                if arguments == ["-lc", "command -v claude"] {
                    return "/resolved/claude\n"
                }
                return nil
            }
        )

        let resolvedPath = ClaudeCLIResolver.resolveCommandPathViaShell(environment: ["SHELL": "/mock/zsh"])

        XCTAssertEqual(resolvedPath, "/resolved/claude")
        XCTAssertEqual(processCalls, [["-lc", "command -v claude"]])
    }

    func testShellResolverFallsBackToInteractiveShellWhenLoginShellMisses() {
        var processCalls: [[String]] = []
        ClaudeCLIResolver.testHooks = .init(
            environment: { [:] },
            isExecutableFile: { path in
                path == "/mock/zsh" || path == "/resolved/claude"
            },
            runProcess: { executablePath, arguments, _ in
                XCTAssertEqual(executablePath, "/mock/zsh")
                processCalls.append(arguments)
                if arguments == ["-ic", "command -v claude"] {
                    return "/resolved/claude\n"
                }
                return nil
            }
        )

        let resolvedPath = ClaudeCLIResolver.resolveCommandPathViaShell(environment: ["SHELL": "/mock/zsh"])

        XCTAssertEqual(resolvedPath, "/resolved/claude")
        XCTAssertEqual(
            processCalls,
            [
                ["-lc", "command -v claude"],
                ["-ic", "command -v claude"],
            ]
        )
    }

    func testShellResolverIgnoresShellNoiseBeforeExecutablePath() {
        ClaudeCLIResolver.testHooks = .init(
            environment: { [:] },
            isExecutableFile: { path in
                path == "/mock/zsh" || path == "/resolved/claude"
            },
            runProcess: { _, arguments, _ in
                if arguments == ["-lc", "command -v claude"] {
                    return "nvm initialized\n /resolved/claude \n"
                }
                return nil
            }
        )

        let resolvedPath = ClaudeCLIResolver.resolveCommandPathViaShell(environment: ["SHELL": "/mock/zsh"])

        XCTAssertEqual(resolvedPath, "/resolved/claude")
    }

    func testShellResolverReturnsNilWhenNeitherModeFindsExecutablePath() {
        var processCalls: [[String]] = []
        ClaudeCLIResolver.testHooks = .init(
            environment: { [:] },
            isExecutableFile: { path in
                path == "/mock/zsh"
            },
            runProcess: { _, arguments, _ in
                processCalls.append(arguments)
                return "claude not found\n"
            }
        )

        let resolvedPath = ClaudeCLIResolver.resolveCommandPathViaShell(environment: ["SHELL": "/mock/zsh"])

        XCTAssertNil(resolvedPath)
        XCTAssertEqual(
            processCalls,
            [
                ["-lc", "command -v claude"],
                ["-ic", "command -v claude"],
            ]
        )
    }

    func testShellResolverFallsBackToDefaultShellsWhenSHELLIsUnset() {
        var processCalls: [[String]] = []
        ClaudeCLIResolver.testHooks = .init(
            environment: { [:] },
            isExecutableFile: { path in
                path == "/bin/zsh" || path == "/bin/bash" || path == "/resolved/claude"
            },
            runProcess: { executablePath, arguments, _ in
                processCalls.append([executablePath] + arguments)
                if executablePath == "/bin/bash", arguments == ["-lc", "command -v claude"] {
                    return "/resolved/claude\n"
                }
                return nil
            }
        )

        let resolvedPath = ClaudeCLIResolver.resolveCommandPathViaShell(environment: [:])

        XCTAssertEqual(resolvedPath, "/resolved/claude")
        XCTAssertEqual(
            processCalls,
            [
                ["/bin/zsh", "-lc", "command -v claude"],
                ["/bin/zsh", "-ic", "command -v claude"],
                ["/bin/bash", "-lc", "command -v claude"],
            ]
        )
    }

    func testResolveUserAgentUsesClaudeFromPATHBeforeShellFallback() {
        var processCalls: [(String, [String])] = []
        ClaudeCLIResolver.testHooks = .init(
            environment: { ["PATH": "/mock/bin"] },
            isExecutableFile: { path in
                path == "/mock/bin/claude"
            },
            runProcess: { executablePath, arguments, _ in
                processCalls.append((executablePath, arguments))
                XCTAssertEqual(executablePath, "/mock/bin/claude")
                XCTAssertEqual(arguments, ["--version"])
                return "2.1.89 (Claude Code)\n"
            }
        )

        let userAgent = ClaudeCLIResolver.resolveUserAgent()

        XCTAssertEqual(userAgent, "claude-code/2.1.89")
        XCTAssertEqual(processCalls.count, 1)
    }

    func testResolveVersionInjectsResolvedClaudeDirectoryIntoPATH() {
        let claudePath = "/mock/nvm/bin/claude"
        var receivedEnvironment: [String: String]?
        ClaudeCLIResolver.testHooks = .init(
            environment: { ["PATH": "/usr/bin:/bin"] },
            isExecutableFile: { path in
                path == claudePath
            },
            runProcess: { executablePath, arguments, environment in
                XCTAssertEqual(executablePath, claudePath)
                XCTAssertEqual(arguments, ["--version"])
                receivedEnvironment = environment
                return "2.1.89 (Claude Code)\n"
            }
        )

        let version = ClaudeCLIResolver.resolveVersion(at: claudePath)

        XCTAssertEqual(version, "2.1.89")
        XCTAssertEqual(receivedEnvironment?["PATH"], "/mock/nvm/bin:/usr/bin:/bin")
    }

    func testResolveVersionWorksForNativeBinaryInstall() {
        let claudePath = "/opt/homebrew/bin/claude"
        var processCalls: [ResolverProcessCall] = []
        ClaudeCLIResolver.testHooks = .init(
            environment: { ["PATH": "/usr/bin:/bin"] },
            isExecutableFile: { path in
                path == claudePath
            },
            runProcess: { executablePath, arguments, environment in
                processCalls.append(
                    ResolverProcessCall(
                        executablePath: executablePath,
                        arguments: arguments,
                        environment: environment
                    )
                )
                return "2.1.89 (Claude Code)\n"
            }
        )

        let version = ClaudeCLIResolver.resolveVersion(at: claudePath)

        XCTAssertEqual(version, "2.1.89")
        XCTAssertEqual(
            processCalls,
            [
                ResolverProcessCall(
                    executablePath: claudePath,
                    arguments: ["--version"],
                    environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]
                ),
            ]
        )
    }

    func testResolveVersionFallsBackToInteractiveShellAfterDirectAndLoginShellMiss() {
        let claudePath = "/mock/nvm/bin/claude"
        var processCalls: [ResolverProcessCall] = []
        ClaudeCLIResolver.testHooks = .init(
            environment: { ["PATH": "/usr/bin:/bin", "SHELL": "/mock/zsh"] },
            isExecutableFile: { path in
                path == claudePath || path == "/mock/zsh"
            },
            runProcess: { executablePath, arguments, environment in
                processCalls.append(
                    ResolverProcessCall(
                        executablePath: executablePath,
                        arguments: arguments,
                        environment: environment
                    )
                )
                if executablePath == "/mock/zsh", arguments == ["-ic", "\"$1\" --version", "zsh", claudePath] {
                    return "nvm initialized\n2.1.89 (Claude Code)\n"
                }
                return nil
            }
        )

        let version = ClaudeCLIResolver.resolveVersion(at: claudePath)

        XCTAssertEqual(version, "2.1.89")
        XCTAssertEqual(
            processCalls,
            [
                ResolverProcessCall(
                    executablePath: claudePath,
                    arguments: ["--version"],
                    environment: ["PATH": "/mock/nvm/bin:/usr/bin:/bin", "SHELL": "/mock/zsh"]
                ),
                ResolverProcessCall(
                    executablePath: "/mock/zsh",
                    arguments: ["-lc", "\"$1\" --version", "zsh", claudePath],
                    environment: ["PATH": "/mock/nvm/bin:/usr/bin:/bin", "SHELL": "/mock/zsh"]
                ),
                ResolverProcessCall(
                    executablePath: "/mock/zsh",
                    arguments: ["-ic", "\"$1\" --version", "zsh", claudePath],
                    environment: ["PATH": "/mock/nvm/bin:/usr/bin:/bin", "SHELL": "/mock/zsh"]
                ),
            ]
        )
    }

    func testResolveVersionShellFallbackPassesResolvedClaudePathAsDollarOne() {
        let claudePath = "/mock/nvm/bin/claude"
        var shellArguments: [String]?
        ClaudeCLIResolver.testHooks = .init(
            environment: { ["PATH": "/usr/bin:/bin", "SHELL": "/mock/zsh"] },
            isExecutableFile: { path in
                path == claudePath || path == "/mock/zsh"
            },
            runProcess: { executablePath, arguments, _ in
                if executablePath == claudePath {
                    return nil
                }
                shellArguments = arguments
                return "2.1.89 (Claude Code)\n"
            }
        )

        let version = ClaudeCLIResolver.resolveVersion(at: claudePath)

        XCTAssertEqual(version, "2.1.89")
        XCTAssertEqual(shellArguments, ["-lc", "\"$1\" --version", "zsh", claudePath])
    }

    func testExtractVersionIgnoresShellNoiseAndReturnsFirstVersionLine() {
        let version = ClaudeCLIResolver.extractVersion(
            from: """
            nvm initialized
            export PATH=/mock/nvm/bin:$PATH
            2.1.89 (Claude Code)
            """
        )

        XCTAssertEqual(version, "2.1.89")
    }

    func testResolveVersionReturnsNilWhenDirectAndShellProbesDoNotYieldVersion() {
        let claudePath = "/mock/nvm/bin/claude"
        var processCalls: [ResolverProcessCall] = []
        ClaudeCLIResolver.testHooks = .init(
            environment: { ["PATH": "/usr/bin:/bin", "SHELL": "/mock/zsh"] },
            isExecutableFile: { path in
                path == claudePath || path == "/mock/zsh"
            },
            runProcess: { executablePath, arguments, environment in
                processCalls.append(
                    ResolverProcessCall(
                        executablePath: executablePath,
                        arguments: arguments,
                        environment: environment
                    )
                )
                if executablePath == claudePath {
                    return "claude version lookup failed\n"
                }
                return "nvm initialized\n"
            }
        )

        let version = ClaudeCLIResolver.resolveVersion(at: claudePath)

        XCTAssertNil(version)
        XCTAssertEqual(
            processCalls,
            [
                ResolverProcessCall(
                    executablePath: claudePath,
                    arguments: ["--version"],
                    environment: ["PATH": "/mock/nvm/bin:/usr/bin:/bin", "SHELL": "/mock/zsh"]
                ),
                ResolverProcessCall(
                    executablePath: "/mock/zsh",
                    arguments: ["-lc", "\"$1\" --version", "zsh", claudePath],
                    environment: ["PATH": "/mock/nvm/bin:/usr/bin:/bin", "SHELL": "/mock/zsh"]
                ),
                ResolverProcessCall(
                    executablePath: "/mock/zsh",
                    arguments: ["-ic", "\"$1\" --version", "zsh", claudePath],
                    environment: ["PATH": "/mock/nvm/bin:/usr/bin:/bin", "SHELL": "/mock/zsh"]
                ),
            ]
        )
    }

    func testConnectAndStartPollingUsesSilentStoredTokenRecovery() async throws {
        let scheduler = PollSchedulerSpy()
        var environmentTokenCalls = 0
        var getCachedTokenCalls: [Bool] = []
        var getOAuthCredentialCalls: [Bool] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthTokenFromEnvironment: {
                environmentTokenCalls += 1
                return nil
            },
            getCachedOAuthToken: { allowInteraction in
                getCachedTokenCalls.append(allowInteraction)
                return nil
            },
            getOAuthCredentials: { allowInteraction in
                getOAuthCredentialCalls.append(allowInteraction)
                return nil
            },
            fetchUsage: { _ in
                XCTFail("fetchUsage should not run without a token")
                return (Data(), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.connectAndStartPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(environmentTokenCalls, 1)
        XCTAssertEqual(getCachedTokenCalls, [false])
        XCTAssertEqual(getOAuthCredentialCalls, [false])
        XCTAssertEqual(service.error, "Claude authentication needs attention. Tap to reconnect.")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.isEmpty)
        XCTAssertFalse(AppSettings.isUsageEnabled)
    }

    func testStartPollingPrefersEnvironmentTokenBeforeKeychainLookups() async throws {
        let scheduler = PollSchedulerSpy()
        var environmentTokenCalls = 0
        var getCachedTokenCalls: [Bool] = []
        var getOAuthCredentialCalls: [Bool] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthTokenFromEnvironment: {
                environmentTokenCalls += 1
                return "env-token"
            },
            getCachedOAuthToken: { allowInteraction in
                getCachedTokenCalls.append(allowInteraction)
                return "cached-token"
            },
            getOAuthCredentials: { allowInteraction in
                getOAuthCredentialCalls.append(allowInteraction)
                return self.makeCredentials(accessToken: "credential-token")
            },
            fetchUsage: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer env-token")
                return (self.makeSuccessPayload(utilization: 31), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(environmentTokenCalls, 1)
        XCTAssertTrue(getCachedTokenCalls.isEmpty)
        XCTAssertTrue(getOAuthCredentialCalls.isEmpty)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 31)
        XCTAssertNil(service.error)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testWhitespaceEnvironmentTokenFallsBackToBackgroundSafeSources() async throws {
        let scheduler = PollSchedulerSpy()
        var environmentTokenCalls = 0
        var getCachedTokenCalls: [Bool] = []
        var getOAuthCredentialCalls: [Bool] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthTokenFromEnvironment: {
                environmentTokenCalls += 1
                return "   "
            },
            getCachedOAuthToken: { allowInteraction in
                getCachedTokenCalls.append(allowInteraction)
                return nil
            },
            getOAuthCredentials: { allowInteraction in
                getOAuthCredentialCalls.append(allowInteraction)
                return nil
            },
            fetchUsage: { _ in
                XCTFail("fetchUsage should not run without a token")
                return (Data(), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(environmentTokenCalls, 1)
        XCTAssertEqual(getCachedTokenCalls, [false])
        XCTAssertEqual(getOAuthCredentialCalls, [false])
        XCTAssertFalse(AppSettings.isUsageEnabled)
    }

    func testStartPollingDisablesUsageWhenNoCachedTokenExists() async throws {
        let scheduler = PollSchedulerSpy()
        var getCachedTokenCalls: [Bool] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { allowInteraction in
                getCachedTokenCalls.append(allowInteraction)
                return nil
            },
            fetchUsage: { _ in
                XCTFail("fetchUsage should not run without a cached token")
                return (Data(), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        AppSettings.isUsageEnabled = true
        service.startPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(getCachedTokenCalls, [false])
        XCTAssertFalse(AppSettings.isUsageEnabled)
        XCTAssertFalse(service.isConnected)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testStartPollingWithoutTokenKeepsReconnectAffordanceWhenUsageIsVisible() async throws {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { _ in nil },
            getOAuthCredentials: { _ in nil },
            fetchUsage: { _ in
                XCTFail("fetchUsage should not run without a background-safe token")
                return (Data(), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.currentUsage = makeQuotaPeriod(utilization: 42)
        AppSettings.isUsageEnabled = true

        service.startPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(AppSettings.isUsageEnabled)
        XCTAssertFalse(service.isConnected)
        XCTAssertNil(service.error)
        XCTAssertEqual(service.statusMessage, "Claude authentication needs attention. Tap to reconnect.")
        XCTAssertTrue(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 42)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testStartPollingRecoversFreshCredentialsWhenNoCachedTokenExists() async throws {
        let scheduler = PollSchedulerSpy()
        var getOAuthCredentialCalls: [Bool] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { _ in nil },
            getOAuthCredentials: { allowInteraction in
                getOAuthCredentialCalls.append(allowInteraction)
                return self.makeCredentials(
                    accessToken: "silent-token",
                    scopes: ["user:profile"]
                )
            },
            fetchUsage: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer silent-token")
                return (self.makeSuccessPayload(utilization: 29), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        AppSettings.isUsageEnabled = true
        service.startPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(getOAuthCredentialCalls, [false])
        XCTAssertTrue(AppSettings.isUsageEnabled)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 29)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testStartPollingWithExpiredRecoveredCredentialsShowsWaitForClaudeCode() async throws {
        let scheduler = PollSchedulerSpy()
        let expiredDate = Date(timeIntervalSince1970: 10)
        let now = Date(timeIntervalSince1970: 20)
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { _ in nil },
            getOAuthCredentials: { allowInteraction in
                XCTAssertFalse(allowInteraction)
                return self.makeCredentials(
                    accessToken: "expired-token",
                    expiresAt: expiredDate,
                    scopes: ["user:profile"]
                )
            },
            refreshAccessTokenSilently: { "expired-token" },
            now: { now },
            fetchUsage: { _ in
                XCTFail("fetchUsage should not run with expired recovered credentials")
                return (Data(), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        AppSettings.isUsageEnabled = true
        service.startPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(AppSettings.isUsageEnabled)
        XCTAssertEqual(service.error, "Start a Claude Code session to refresh credentials")
        XCTAssertEqual(service.recoveryAction, .waitForClaudeCode)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testStartPollingPrefersCachedTokenWithoutReadingClaudeCredentials() async throws {
        let scheduler = PollSchedulerSpy()
        var credentialReads = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { _ in "stale-cached-token" },
            getOAuthCredentials: { allowInteraction in
                credentialReads += 1
                XCTAssertFalse(allowInteraction)
                return self.makeCredentials(accessToken: "fresh-claude-token", scopes: ["user:profile"])
            },
            fetchUsage: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer stale-cached-token")
                return (self.makeSuccessPayload(utilization: 31), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(credentialReads, 0)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 31)
        XCTAssertTrue(AppSettings.isUsageEnabled)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testConnectAndStartPollingWithCachedTokenSkipsExpiredCredentialMetadataPreflight() async throws {
        let scheduler = PollSchedulerSpy()
        var credentialReads = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { _ in "cached-token" },
            getOAuthCredentials: { allowInteraction in
                credentialReads += 1
                XCTAssertFalse(allowInteraction)
                return self.makeCredentials(
                    accessToken: "cached-token",
                    expiresAt: Date(timeIntervalSince1970: 10),
                    scopes: ["user:profile"]
                )
            },
            now: { Date(timeIntervalSince1970: 20) },
            fetchUsage: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cached-token")
                return (self.makeSuccessPayload(utilization: 41), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.connectAndStartPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(credentialReads, 1)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 41)
        XCTAssertNil(service.error)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertTrue(AppSettings.isUsageEnabled)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testConnectAndStartPollingRecoversCachedTokenFromSilentCredentials() async throws {
        let scheduler = PollSchedulerSpy()
        var cachedTokens: [String] = []
        var getOAuthCredentialCalls: [Bool] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { _ in nil },
            getOAuthCredentials: { allowInteraction in
                getOAuthCredentialCalls.append(allowInteraction)
                return self.makeCredentials(
                    accessToken: "silent-token",
                    scopes: ["user:profile"]
                )
            },
            cacheOAuthToken: { token in
                cachedTokens.append(token)
            },
            fetchUsage: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer silent-token")
                return (self.makeSuccessPayload(utilization: 27), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.connectAndStartPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(getOAuthCredentialCalls, [false])
        XCTAssertEqual(cachedTokens, ["silent-token"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 27)
        XCTAssertTrue(AppSettings.isUsageEnabled)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testConnectAndStartPollingWithExpiredCredentialsAndStaleUsageShowsReason() async throws {
        let scheduler = PollSchedulerSpy()
        let expiredDate = Date(timeIntervalSince1970: 10)
        let now = Date(timeIntervalSince1970: 20)
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { _ in nil },
            getOAuthCredentials: { _ in
                self.makeCredentials(
                    accessToken: "expired-token",
                    expiresAt: expiredDate,
                    scopes: ["user:profile"]
                )
            },
            refreshAccessTokenSilently: { "expired-token" },
            now: { now },
            fetchUsage: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer expired-token")
                return (Data(), self.makeResponse(statusCode: 401))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.currentUsage = makeQuotaPeriod(utilization: 55)

        service.connectAndStartPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertNil(service.error)
        XCTAssertEqual(service.statusMessage, "Start a Claude Code session to refresh credentials")
        XCTAssertTrue(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .waitForClaudeCode)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 55)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testHandleClaudeResumeTriggerSchedulesDelayedReconnectFromSessionStart() async throws {
        let scheduler = PollSchedulerSpy()
        var fetchCount = 0
        let fetchExpectation = expectation(description: "SessionStart triggers delayed usage reconnect")
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthCredentials: { allowInteraction in
                XCTAssertFalse(allowInteraction)
                return self.makeCredentials(accessToken: "fresh-token", scopes: ["user:profile"])
            },
            fetchUsage: { request in
                fetchCount += 1
                fetchExpectation.fulfill()
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-token")
                return (self.makeSuccessPayload(utilization: 29), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        AppSettings.isUsageEnabled = true
        service.recoveryAction = .waitForClaudeCode
        service.error = "Start a Claude Code session to refresh credentials"

        service.handleClaudeResumeTrigger(.sessionStart)

        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(scheduler.intervals, [2])

        scheduler.fireLast()
        await fulfillment(of: [fetchExpectation], timeout: 1)

        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 29)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [2, 60])
    }

    func testHandleClaudeResumeTriggerSchedulesDelayedReconnectFromUserPromptSubmit() async throws {
        let scheduler = PollSchedulerSpy()
        var fetchCount = 0
        let fetchExpectation = expectation(description: "UserPromptSubmit triggers delayed usage reconnect")
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthCredentials: { _ in
                self.makeCredentials(accessToken: "fresh-token", scopes: ["user:profile"])
            },
            fetchUsage: { _ in
                fetchCount += 1
                fetchExpectation.fulfill()
                return (self.makeSuccessPayload(utilization: 31), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        AppSettings.isUsageEnabled = true
        service.recoveryAction = .waitForClaudeCode

        service.handleClaudeResumeTrigger(.userPromptSubmit)

        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(scheduler.intervals, [2])

        scheduler.fireLast()
        await fulfillment(of: [fetchExpectation], timeout: 1)

        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(scheduler.intervals, [2, 60])
    }

    func testHandleClaudeResumeTriggerCoalescesSessionStartThenUserPromptSubmit() async throws {
        let scheduler = PollSchedulerSpy()
        var fetchCount = 0
        let fetchExpectation = expectation(description: "Mixed resume triggers still cause one reconnect")
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthCredentials: { _ in
                self.makeCredentials(accessToken: "fresh-token", scopes: ["user:profile"])
            },
            fetchUsage: { _ in
                fetchCount += 1
                fetchExpectation.fulfill()
                return (self.makeSuccessPayload(utilization: 31), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        AppSettings.isUsageEnabled = true
        service.recoveryAction = .waitForClaudeCode

        service.handleClaudeResumeTrigger(.sessionStart)
        service.handleClaudeResumeTrigger(.userPromptSubmit)

        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(scheduler.intervals, [2])

        scheduler.fireLast()
        await fulfillment(of: [fetchExpectation], timeout: 1)

        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(scheduler.intervals, [2, 60])
    }

    func testHandleClaudeResumeTriggerCoalescesUserPromptSubmitThenSessionStart() async throws {
        let scheduler = PollSchedulerSpy()
        var fetchCount = 0
        let fetchExpectation = expectation(description: "Mixed resume triggers still coalesce when prompt arrives first")
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthCredentials: { _ in
                self.makeCredentials(accessToken: "fresh-token", scopes: ["user:profile"])
            },
            fetchUsage: { _ in
                fetchCount += 1
                fetchExpectation.fulfill()
                return (self.makeSuccessPayload(utilization: 31), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        AppSettings.isUsageEnabled = true
        service.recoveryAction = .waitForClaudeCode

        service.handleClaudeResumeTrigger(.userPromptSubmit)
        service.handleClaudeResumeTrigger(.sessionStart)

        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(scheduler.intervals, [2])

        scheduler.fireLast()
        await fulfillment(of: [fetchExpectation], timeout: 1)

        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(scheduler.intervals, [2, 60])
    }

    func testHandleClaudeResumeTriggerDoesNothingOutsideWaitForClaudeCode() async throws {
        let scheduler = PollSchedulerSpy()
        var fetchCount = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { _ in
                fetchCount += 1
                return (self.makeSuccessPayload(utilization: 31), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        AppSettings.isUsageEnabled = true

        service.handleClaudeResumeTrigger(.sessionStart)

        XCTAssertEqual(fetchCount, 0)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testHandleClaudeResumeTriggerDoesNothingWhenUsageIsDisabled() async throws {
        let scheduler = PollSchedulerSpy()
        var fetchCount = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { _ in
                fetchCount += 1
                return (self.makeSuccessPayload(utilization: 31), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        AppSettings.isUsageEnabled = false
        service.recoveryAction = .waitForClaudeCode

        service.handleClaudeResumeTrigger(.userPromptSubmit)

        XCTAssertEqual(fetchCount, 0)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testManualReconnectCancelsPendingResumeRetry() async throws {
        let scheduler = PollSchedulerSpy()
        var fetchCount = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthCredentials: { _ in
                self.makeCredentials(accessToken: "fresh-token", scopes: ["user:profile"])
            },
            fetchUsage: { _ in
                fetchCount += 1
                return (self.makeSuccessPayload(utilization: 34), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        AppSettings.isUsageEnabled = true
        service.recoveryAction = .waitForClaudeCode
        service.error = "Start a Claude Code session to refresh credentials"

        service.handleClaudeResumeTrigger(.sessionStart)
        XCTAssertEqual(scheduler.intervals, [2])

        service.connectAndStartPolling()
        await Task.yield()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(fetchCount, 1)

        scheduler.fire(at: 0)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(scheduler.intervals, [2, 60])
    }

    func testConnectAndStartPollingPrefersClaudeCredentialsOverCachedToken() async throws {
        let scheduler = PollSchedulerSpy()
        var credentialReads = 0
        var authHeaders: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { _ in "stale-cached-token" },
            getOAuthCredentials: { allowInteraction in
                credentialReads += 1
                XCTAssertFalse(allowInteraction)
                return self.makeCredentials(accessToken: "fresh-claude-token", scopes: ["user:profile"])
            },
            fetchUsage: { request in
                let authHeader = request.value(forHTTPHeaderField: "Authorization") ?? "<missing>"
                authHeaders.append(authHeader)
                XCTAssertEqual(authHeader, "Bearer fresh-claude-token")
                return (self.makeSuccessPayload(utilization: 37), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.connectAndStartPolling()
        await Task.yield()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(credentialReads, 1)
        XCTAssertEqual(authHeaders, ["Bearer fresh-claude-token"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 37)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertTrue(AppSettings.isUsageEnabled)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testPerformFetch401RetriesWithRecoveredClaudeCredentials() async throws {
        let scheduler = PollSchedulerSpy()
        var credentialReads = 0
        var clearCachedTokenCalls = 0
        var authHeaders: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthCredentials: { allowInteraction in
                credentialReads += 1
                XCTAssertFalse(allowInteraction)
                return self.makeCredentials(accessToken: "new-token", scopes: ["user:profile"])
            },
            clearCachedOAuthToken: {
                clearCachedTokenCalls += 1
            },
            fetchUsage: { request in
                let authHeader = request.value(forHTTPHeaderField: "Authorization") ?? "<missing>"
                authHeaders.append(authHeader)
                if authHeader == "Bearer old-token" {
                    return (Data(), self.makeResponse(statusCode: 401))
                }
                return (self.makeSuccessPayload(utilization: 33), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "old-token", consultCredentialMetadata: false)

        XCTAssertEqual(credentialReads, 1)
        XCTAssertEqual(clearCachedTokenCalls, 1)
        XCTAssertEqual(authHeaders, ["Bearer old-token", "Bearer new-token"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 33)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testPerformFetch401ShowsWaitForClaudeCodeWhenCredentialsRemainExpired() async throws {
        let scheduler = PollSchedulerSpy()
        let expiredDate = Date(timeIntervalSince1970: 10)
        let now = Date(timeIntervalSince1970: 20)
        var clearCachedTokenCalls = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthCredentials: { allowInteraction in
                XCTAssertFalse(allowInteraction)
                return self.makeCredentials(
                    accessToken: "expired-token",
                    expiresAt: expiredDate,
                    scopes: ["user:profile"]
                )
            },
            clearCachedOAuthToken: {
                clearCachedTokenCalls += 1
            },
            now: { now },
            fetchUsage: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer expired-token")
                return (Data(), self.makeResponse(statusCode: 401))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "expired-token", consultCredentialMetadata: false)

        XCTAssertEqual(clearCachedTokenCalls, 1)
        XCTAssertNil(service.currentUsage)
        XCTAssertEqual(service.error, "Start a Claude Code session to refresh credentials")
        XCTAssertNil(service.statusMessage)
        XCTAssertEqual(service.recoveryAction, .waitForClaudeCode)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testLocalPreflightBlocksOAuthWhenScopeIsMissing() async throws {
        let scheduler = PollSchedulerSpy()
        var fetchCalled = false
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthCredentials: { allowInteraction in
                XCTAssertFalse(allowInteraction)
                return self.makeCredentials(accessToken: "token", scopes: ["openid"])
            },
            fetchUsage: { _ in
                fetchCalled = true
                return (self.makeSuccessPayload(utilization: 20), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token", userInitiated: true)

        XCTAssertFalse(fetchCalled)
        XCTAssertEqual(service.error, "Claude authentication needs attention. Tap to reconnect.")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testLocalPreflightSilentlyRefreshesExpiredToken() async throws {
        let scheduler = PollSchedulerSpy()
        var refreshCalls = 0
        var authHeaders: [String] = []
        let expiredDate = Date(timeIntervalSince1970: 10)
        let now = Date(timeIntervalSince1970: 20)
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthCredentials: { allowInteraction in
                XCTAssertFalse(allowInteraction)
                return self.makeCredentials(
                    accessToken: "cached-token",
                    expiresAt: expiredDate,
                    scopes: ["user:profile"]
                )
            },
            refreshAccessTokenSilently: {
                refreshCalls += 1
                return "fresh-token"
            },
            now: { now },
            fetchUsage: { request in
                authHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "<missing>")
                return (self.makeSuccessPayload(utilization: 34), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "cached-token")

        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(authHeaders, ["Bearer fresh-token"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 34)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testLocalPreflightExpiredTokenSameRefreshTokenWaitsForClaudeCodeWithoutNetwork() async throws {
        let scheduler = PollSchedulerSpy()
        var refreshCalls = 0
        var fetchCalled = false
        let expiredDate = Date(timeIntervalSince1970: 10)
        let now = Date(timeIntervalSince1970: 20)
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthCredentials: { allowInteraction in
                XCTAssertFalse(allowInteraction)
                return self.makeCredentials(
                    accessToken: "cached-token",
                    expiresAt: expiredDate,
                    scopes: ["user:profile"]
                )
            },
            refreshAccessTokenSilently: {
                refreshCalls += 1
                return "cached-token"
            },
            now: { now },
            fetchUsage: { _ in
                fetchCalled = true
                return (self.makeSuccessPayload(utilization: 34), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "cached-token")

        XCTAssertEqual(refreshCalls, 1)
        XCTAssertFalse(fetchCalled)
        XCTAssertNil(service.currentUsage)
        XCTAssertEqual(service.error, "Start a Claude Code session to refresh credentials")
        XCTAssertEqual(service.recoveryAction, .waitForClaudeCode)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testLocalPreflightExpiredTokenOnlyRefreshesOncePerFetchCycleBeforeUsingRefreshedToken() async throws {
        let scheduler = PollSchedulerSpy()
        var credentialReads = 0
        var refreshCalls = 0
        var authHeaders: [String] = []
        let expiredDate = Date(timeIntervalSince1970: 10)
        let now = Date(timeIntervalSince1970: 20)
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthCredentials: { allowInteraction in
                XCTAssertFalse(allowInteraction)
                credentialReads += 1
                let token = credentialReads == 1 ? "cached-token" : "fresh-token-1"
                return self.makeCredentials(
                    accessToken: token,
                    expiresAt: expiredDate,
                    scopes: ["user:profile"]
                )
            },
            refreshAccessTokenSilently: {
                refreshCalls += 1
                return refreshCalls == 1 ? "fresh-token-1" : "fresh-token-2"
            },
            now: { now },
            fetchUsage: { request in
                authHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "<missing>")
                return (self.makeSuccessPayload(utilization: 34), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "cached-token")

        XCTAssertEqual(credentialReads, 1)
        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(authHeaders, ["Bearer fresh-token-1"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 34)
        XCTAssertNil(service.error)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testManualFetchPrefersSilentCredentialsWhenTokenMismatchExists() async throws {
        let scheduler = PollSchedulerSpy()
        var authHeaders: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthCredentials: { allowInteraction in
                XCTAssertFalse(allowInteraction)
                return self.makeCredentials(
                    accessToken: "silent-fresh-token",
                    scopes: ["user:profile"]
                )
            },
            fetchUsage: { request in
                authHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "<missing>")
                return (self.makeSuccessPayload(utilization: 44), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "stale-cached-token", userInitiated: true)

        XCTAssertEqual(authHeaders, ["Bearer silent-fresh-token"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 44)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testBackgroundFetchKeepsCachedTokenWhenSilentCredentialsMismatch() async throws {
        let scheduler = PollSchedulerSpy()
        var authHeaders: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthCredentials: { allowInteraction in
                XCTAssertFalse(allowInteraction)
                return self.makeCredentials(
                    accessToken: "different-silent-token",
                    scopes: ["user:profile"]
                )
            },
            fetchUsage: { request in
                authHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "<missing>")
                return (self.makeSuccessPayload(utilization: 22), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "cached-background-token")

        XCTAssertEqual(authHeaders, ["Bearer cached-background-token"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 22)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testThreeConsecutiveRateLimitsRefreshTokenAndRetry() async throws {
        let scheduler = PollSchedulerSpy()
        var refreshCalls = 0
        var requests: [String] = []
        var oauthCalls = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            refreshAccessTokenSilently: {
                refreshCalls += 1
                return "fresh-token"
            },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                let authHeader = request.value(forHTTPHeaderField: "Authorization") ?? "<missing>"
                requests.append("\(path) \(authHeader)")
                if path == "/v1/messages" {
                    return (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
                }
                oauthCalls += 1
                if oauthCalls <= 3 {
                    return (Data(), self.makeResponse(statusCode: 429))
                }
                return (self.makeSuccessPayload(utilization: 64), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "old-token")
        await service.performFetch(with: "old-token")
        await service.performFetch(with: "old-token")

        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(
            requests,
            [
                "/api/oauth/usage Bearer old-token",
                "/v1/messages Bearer old-token",
                "/api/oauth/usage Bearer old-token",
                "/api/oauth/usage Bearer old-token",
                "/api/oauth/usage Bearer fresh-token",
            ]
        )
        XCTAssertEqual(service.currentUsage?.usagePercentage, 64)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [120, 240, 60])
    }

    private func makeDependencies(
        scheduler: PollSchedulerSpy,
        resolveUserAgent: @escaping () -> String?,
        getOAuthTokenFromEnvironment: @escaping () -> String? = { nil },
        getCachedOAuthToken: @escaping (_ allowInteraction: Bool) -> String? = { _ in nil },
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

    private func makeService(
        now: @escaping () -> Date = { Date() },
        cachedToken: @escaping () -> String? = { nil },
        snapshot: @escaping () -> ClaudeUsageRecoverySnapshot? = { nil },
        fetchUsage: @escaping (URLRequest) async throws -> (Data, URLResponse)
    ) -> (service: ClaudeUsageService, scheduler: PollSchedulerSpy) {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { _ in cachedToken() },
            loadRecoverySnapshot: snapshot,
            now: now,
            fetchUsage: fetchUsage
        )
        return (ClaudeUsageService(dependencies: dependencies), scheduler)
    }

    private func oauthSequence(
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

    private func oauth429ThenHeaders(
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

    private func oauth403ThenHeaders(
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

    private func makeSuccessPayload(utilization: Double) -> Data {
        let json = """
        {
          "five_hour": {
            "utilization": \(utilization),
            "resets_at": "2099-01-01T01:00:00Z"
          },
          "seven_day": null
        }
        """
        return Data(json.utf8)
    }

    // MARK: - Enterprise Headers Fallback

    func testOAuth403ScopeErrorsDoNotFallbackToHeaders() async throws {
        let cases = [
            "Claude OAuth token does not meet scope requirement 'user:profile'.",
            "OAuth token scope is invalid",
        ]

        for message in cases {
            let recorder = RequestRecorder()
            let (service, scheduler) = makeService(
                fetchUsage: { request in
                    recorder.record(request)
                    return (
                        self.makeAnthropicErrorPayload(
                            type: "permission_error",
                            message: message
                        ),
                        self.makeResponse(statusCode: 403)
                    )
                }
            )

            await service.performFetch(with: "token")

            recorder.assertOAuthOnly()
            XCTAssertEqual(service.error, "Claude authentication needs attention. Tap to reconnect.")
            XCTAssertEqual(service.recoveryAction, .reconnect)
            XCTAssertFalse(service.isConnected)
            XCTAssertTrue(scheduler.intervals.isEmpty)
        }
    }

    func testOAuth403TriggersHeadersFallbackAndSucceeds() async throws {
        let recorder = RequestRecorder()
        let (service, scheduler) = makeService(
            fetchUsage: oauth403ThenHeaders(
                recorder: recorder,
                oauthResponse: { (Data(), self.makeResponse(statusCode: 403)) }
            ) { _, _ in
                (Data(), self.makeHeadersResponse(
                    utilization: "0.42",
                    reset: "2099-01-01T01:00:00Z"
                ))
            }
        )
        await service.performFetch(with: "token")

        recorder.assertMixed(["/api/oauth/usage", "/v1/messages"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 42)
        XCTAssertTrue(service.isConnected)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testOAuth403HeadersFallbackDoesNotPersist429RecoveryState() async throws {
        let scheduler = PollSchedulerSpy()
        var savedSnapshots: [ClaudeUsageRecoverySnapshot] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            saveRecoverySnapshot: { savedSnapshots.append($0) },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                return (Data(), self.makeHeadersResponse(
                    utilization: "0.42",
                    reset: "2099-01-01T01:00:00Z"
                ))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertTrue(savedSnapshots.isEmpty)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 42)
    }

    func testOAuth403WithAmbiguousJSONStillFallsBackToHeaders() async throws {
        let recorder = RequestRecorder()
        let (service, _) = makeService(
            fetchUsage: oauth403ThenHeaders(
                recorder: recorder,
                oauthResponse: {
                    (
                        self.makeAnthropicErrorPayload(
                            type: "permission_error",
                            message: "Your account does not have permission to use this resource."
                        ),
                        self.makeResponse(statusCode: 403)
                    )
                }
            ) { _, _ in
                (Data(), self.makeHeadersResponse(
                    utilization: "0.42",
                    reset: "2099-01-01T01:00:00Z"
                ))
            }
        )
        await service.performFetch(with: "token")

        recorder.assertMixed(["/api/oauth/usage", "/v1/messages"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 42)
        XCTAssertEqual(service.recoveryAction, .none)
    }

    func testOAuth403WithNonPermissionErrorAndScopeTextStillFallsBackToHeaders() async throws {
        let recorder = RequestRecorder()
        let (service, _) = makeService(
            fetchUsage: oauth403ThenHeaders(
                recorder: recorder,
                oauthResponse: {
                    (
                        self.makeAnthropicErrorPayload(
                            type: "invalid_request_error",
                            message: "OAuth token scope is invalid"
                        ),
                        self.makeResponse(statusCode: 403)
                    )
                }
            ) { _, _ in
                (Data(), self.makeHeadersResponse(
                    utilization: "0.42",
                    reset: "2099-01-01T01:00:00Z"
                ))
            }
        )
        await service.performFetch(with: "token")

        recorder.assertMixed(["/api/oauth/usage", "/v1/messages"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 42)
        XCTAssertEqual(service.recoveryAction, .none)
    }

    func testOAuth403WithEmptyBodyStillFallsBackToHeaders() async throws {
        let recorder = RequestRecorder()
        let (service, _) = makeService(
            fetchUsage: oauth403ThenHeaders(
                recorder: recorder,
                oauthResponse: { (Data(), self.makeResponse(statusCode: 403)) }
            ) { _, _ in
                (Data(), self.makeHeadersResponse(
                    utilization: "0.42",
                    reset: "2099-01-01T01:00:00Z"
                ))
            }
        )
        await service.performFetch(with: "token")

        recorder.assertMixed(["/api/oauth/usage", "/v1/messages"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 42)
        XCTAssertEqual(service.recoveryAction, .none)
    }

    func testOAuth403WithEmptyHeadersFallbackRefreshesAndRecovers() async throws {
        let scheduler = PollSchedulerSpy()
        var requestURLs: [String] = []
        var clearCalls = 0
        var refreshCalls = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            refreshAccessTokenSilently: {
                refreshCalls += 1
                return "fresh-token"
            },
            clearCachedOAuthToken: {
                clearCalls += 1
            },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                let auth = request.value(forHTTPHeaderField: "Authorization") ?? "<missing>"
                requestURLs.append("\(path) \(auth)")
                if path == "/api/oauth/usage", auth == "Bearer old-token" {
                    return (
                        self.makeAnthropicErrorPayload(
                            type: "forbidden",
                            message: "Access forbidden"
                        ),
                        self.makeResponse(statusCode: 403)
                    )
                }
                if path == "/v1/messages" {
                    return (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
                }
                return (self.makeSuccessPayload(utilization: 28), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "old-token")

        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(clearCalls, 1)
        XCTAssertEqual(
            requestURLs,
            [
                "/api/oauth/usage Bearer old-token",
                "/v1/messages Bearer old-token",
                "/api/oauth/usage Bearer fresh-token",
            ]
        )
        XCTAssertEqual(service.currentUsage?.usagePercentage, 28)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testOAuth403WithEmptyHeadersFallbackReconnectsWithoutRefreshLoop() async throws {
        let scheduler = PollSchedulerSpy()
        var requestURLs: [String] = []
        var clearCalls = 0
        var refreshCalls = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            refreshAccessTokenSilently: {
                refreshCalls += 1
                return "old-token"
            },
            clearCachedOAuthToken: {
                clearCalls += 1
            },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    return (
                        self.makeAnthropicErrorPayload(
                            type: "forbidden",
                            message: "Access forbidden"
                        ),
                        self.makeResponse(statusCode: 403)
                    )
                }
                return (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "old-token")

        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(clearCalls, 1)
        XCTAssertEqual(requestURLs, ["/api/oauth/usage", "/v1/messages"])
        XCTAssertEqual(service.error, "Claude authentication needs attention. Tap to reconnect.")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testOAuth403ThenHeadersFallbackFailsWithNoHeadersAndReconnects() async throws {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                return (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertNil(service.currentUsage)
        XCTAssertEqual(service.error, "Claude authentication needs attention. Tap to reconnect.")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testOAuth403ThenHeaders401ClearsToken() async throws {
        let scheduler = PollSchedulerSpy()
        var clearCalls = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            clearCachedOAuthToken: { clearCalls += 1 },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                return (Data(), self.makeResponse(statusCode: 401, url: self.messagesURL))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertEqual(clearCalls, 1)
        XCTAssertEqual(service.error, "Token expired. Tap to reconnect.")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertFalse(service.isConnected)
    }

    func testCachedFallbackSkipsOAuth() async throws {
        let scheduler = PollSchedulerSpy()
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                return (Data(), self.makeHeadersResponse(
                    utilization: "0.50",
                    reset: "2099-01-01T01:00:00Z"
                ))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")
        requestURLs.removeAll()
        await service.performFetch(with: "token")

        XCTAssertEqual(requestURLs, ["/v1/messages"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 50)
    }

    func testCachedFallbackWithMissingHeadersKeepsUsageAndShowsUpdatingState() async throws {
        let scheduler = PollSchedulerSpy()
        var requestURLs: [String] = []
        var headersCallCount = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                headersCallCount += 1
                if headersCallCount == 1 {
                    return (Data(), self.makeHeadersResponse(
                        utilization: "0.50",
                        reset: "2099-01-01T01:00:00Z"
                    ))
                }
                return (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")
        XCTAssertEqual(service.currentUsage?.usagePercentage, 50)
        let intervalsAfterFirstFetch = scheduler.intervals.count

        requestURLs.removeAll()
        await service.performFetch(with: "token")

        XCTAssertEqual(requestURLs, ["/v1/messages"])
        XCTAssertNil(service.error)
        XCTAssertEqual(service.statusMessage, "Updating soon")
        XCTAssertTrue(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .retry)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 50)
        XCTAssertGreaterThan(scheduler.intervals.count, intervalsAfterFirstFetch)
    }

    func testActiveHeadersFallbackMissWithExpiredUsageDropsToRetryState() async throws {
        var now = Date(timeIntervalSince1970: 100)
        let recorder = RequestRecorder()
        let (service, scheduler) = makeService(
            now: { now },
            cachedToken: { "token" },
            fetchUsage: oauth429ThenHeaders(recorder: recorder) { call, _ in
                if call == 1 {
                    return (
                        Data(),
                        self.makeHeadersResponse(
                            utilization: "0.42",
                            reset: "1970-01-01T00:02:00Z"
                        )
                    )
                }
                return (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
            }
        )
        service.startPolling()
        await Task.yield()
        await Task.yield()

        recorder.reset()
        now = now.addingTimeInterval(60)
        scheduler.fireLast()
        await Task.yield()
        await Task.yield()

        recorder.assertHeadersOnly()
        XCTAssertNil(service.currentUsage)
        XCTAssertEqual(service.error, "No rate limit headers, retrying in 60s")
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .retry)
        XCTAssertEqual(scheduler.intervals, [60, 60])
    }

    func testOAuthRecheckAfterTenPolls() async throws {
        let scheduler = PollSchedulerSpy()
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                return (Data(), self.makeHeadersResponse(
                    utilization: "0.30",
                    reset: "2099-01-01T01:00:00Z"
                ))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        // First call: OAuth 403 → headers fallback
        await service.performFetch(with: "token")
        requestURLs.removeAll()

        // Polls 2-10: headers only (9 polls, counter goes 1-9)
        for _ in 0..<9 {
            await service.performFetch(with: "token")
        }
        let headerOnlyURLs = requestURLs
        requestURLs.removeAll()

        // Poll 11: counter hits 10, rechecks OAuth
        await service.performFetch(with: "token")

        XCTAssertEqual(headerOnlyURLs, Array(repeating: "/v1/messages", count: 9))
        XCTAssertEqual(requestURLs, ["/api/oauth/usage", "/v1/messages"])
    }

    func testOAuthRecheckSucceedsAfterAccountUpgrade() async throws {
        let scheduler = PollSchedulerSpy()
        var oauthCallCount = 0
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    oauthCallCount += 1
                    if oauthCallCount == 1 {
                        return (Data(), self.makeResponse(statusCode: 403))
                    }
                    return (self.makeSuccessPayload(utilization: 25), self.makeResponse(statusCode: 200))
                }
                return (Data(), self.makeHeadersResponse(
                    utilization: "0.30",
                    reset: "2099-01-01T01:00:00Z"
                ))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        // First call: OAuth 403 → headers fallback
        await service.performFetch(with: "token")

        // 9 more polls (headers only)
        for _ in 0..<9 {
            await service.performFetch(with: "token")
        }

        // Poll 11: recheck OAuth → now succeeds (account upgraded)
        requestURLs.removeAll()
        await service.performFetch(with: "token")

        XCTAssertEqual(requestURLs, ["/api/oauth/usage"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 25)

        // Next poll should go to OAuth directly (preferHeadersFallback cleared)
        requestURLs.removeAll()
        await service.performFetch(with: "token")
        XCTAssertEqual(requestURLs, ["/api/oauth/usage"])
    }

    func testHeadersUtilizationScaling() async throws {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                return (Data(), self.makeHeadersResponse(
                    utilization: "0.75",
                    reset: "2099-01-01T01:00:00Z"
                ))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertEqual(service.currentUsage?.usagePercentage, 75)
    }

    func testOAuth403ThenHeadersNetworkErrorShowsFallbackError() async throws {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                throw URLError(.notConnectedToInternet)
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertEqual(service.error, "Network error, retrying in 60s")
        XCTAssertEqual(service.recoveryAction, .retry)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testMissingResetHeaderHandledGracefully() async throws {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                return (Data(), self.makeHeadersResponse(utilization: "0.60", reset: nil))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertEqual(service.currentUsage?.usagePercentage, 60)
        XCTAssertNil(service.currentUsage?.resetDate)
        XCTAssertTrue(service.isConnected)
    }

    func testHeaders429WithNoRateLimitHeadersShowsRetryableError() async throws {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                return (Data(), self.makeResponse(statusCode: 429, url: self.messagesURL))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertNil(service.currentUsage)
        XCTAssertEqual(service.error, "Claude authentication needs attention. Tap to reconnect.")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testMalformedUtilizationHeaderTreatedAsMissing() async throws {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                return (Data(), self.makeHeadersResponse(utilization: "not-a-number", reset: nil))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertNil(service.currentUsage)
        XCTAssertEqual(service.error, "Claude authentication needs attention. Tap to reconnect.")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    // MARK: - Helpers

    private var messagesURL: URL { URL(string: "https://api.anthropic.com/v1/messages")! }

    private func makeQuotaPeriod(utilization: Double) -> QuotaPeriod {
        QuotaPeriod(utilization: utilization, resetsAt: "2099-01-01T01:00:00Z")
    }

    private func makeRecoverySnapshot(
        oauthBackoffUntil: Date? = nil,
        oauthHeadersFallbackProbeUntil: Date? = nil,
        isHeadersFallbackActive: Bool = false,
        lastGoodUsage: QuotaPeriod? = nil
    ) -> ClaudeUsageRecoverySnapshot {
        ClaudeUsageRecoverySnapshot(
            oauthBackoffUntil: oauthBackoffUntil,
            oauthHeadersFallbackProbeUntil: oauthHeadersFallbackProbeUntil,
            isHeadersFallbackActive: isHeadersFallbackActive,
            lastGoodUsage: lastGoodUsage
        )
    }

    private func makeResponse(statusCode: Int, headers: [String: String] = [:], url: URL? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url ?? URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    private func makeHeadersResponse(utilization: String, reset: String?, statusCode: Int = 200) -> HTTPURLResponse {
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

    private func makeAnthropicErrorPayload(
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

    private func makeCredentials(
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
