import Foundation
import XCTest
@testable import notchi

extension ClaudeUsageServiceTests {
    func testSuccessfulFetchPublishesWeeklyUsageFromSevenDay() async throws {
        let dependencies = makeDependencies(
            scheduler: PollSchedulerSpy(),
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { _ in
                (self.makeSuccessPayload(utilization: 42, weeklyUtilization: 58), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)

        await service.performFetch(with: "token")

        XCTAssertEqual(service.currentUsage?.usagePercentage, 42)
        XCTAssertEqual(service.currentWeeklyUsage?.usagePercentage, 58)
    }

    func testFailedRefreshMarksWeeklyOnlyUsageAsStaleInsteadOfFresh() async throws {
        var calls = 0
        let (service, _) = makeService(fetchUsage: { _ in
            calls += 1
            if calls == 1 {
                let weeklyOnly = try JSONSerialization.data(withJSONObject: [
                    "seven_day": ["utilization": 58.0, "resets_at": "2099-01-08T01:00:00Z"]
                ])
                return (weeklyOnly, self.makeResponse(statusCode: 200))
            }
            throw URLError(.notConnectedToInternet)
        })

        await service.performFetch(with: "token")
        XCTAssertNil(service.currentUsage)
        XCTAssertEqual(service.currentWeeklyUsage?.usagePercentage, 58)

        await service.performFetch(with: "token")

        XCTAssertEqual(service.recoveryAction, .retry)
        XCTAssertNil(service.error)
        XCTAssertNotNil(service.statusMessage)
        XCTAssertTrue(service.isUsageStale)
        XCTAssertTrue(service.isWeeklyUsageHeldOver)
    }

    func testFailedRefreshMarksModelOnlyUsageAsStaleInsteadOfFresh() async throws {
        var calls = 0
        let (service, _) = makeService(fetchUsage: { _ in
            calls += 1
            if calls == 1 {
                let modelOnly = try JSONSerialization.data(withJSONObject: [
                    "seven_day_sonnet": ["utilization": 63.0]
                ])
                return (modelOnly, self.makeResponse(statusCode: 200))
            }
            throw URLError(.notConnectedToInternet)
        })

        await service.performFetch(with: "token")
        XCTAssertNil(service.currentUsage)
        XCTAssertNil(service.currentWeeklyUsage)
        XCTAssertEqual(service.currentModelUsage?.usagePercentage, 63)

        await service.performFetch(with: "token")

        XCTAssertNil(service.error)
        XCTAssertNotNil(service.statusMessage)
        XCTAssertTrue(service.isUsageStale)
    }

    func testSuccessfulFetchReenablesUsageFlag() async throws {
        AppSettings.isUsageEnabled = false
        let dependencies = makeDependencies(
            scheduler: PollSchedulerSpy(),
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { _ in
                (self.makeSuccessPayload(utilization: 42, weeklyUtilization: 58), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)

        await service.performFetch(with: "token")

        XCTAssertTrue(AppSettings.isUsageEnabled)
    }

    func testSuccessfulFetchPublishesModelUsageFromSevenDaySonnet() async throws {
        let dependencies = makeDependencies(
            scheduler: PollSchedulerSpy(),
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { _ in
                (self.makeSuccessPayload(utilization: 42, weeklyUtilization: 58, sonnetUtilization: 22), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)

        await service.performFetch(with: "token")

        XCTAssertEqual(service.currentModelUsage?.usagePercentage, 22)
        XCTAssertEqual(service.currentModelUsageName, "Sonnet")
    }

    func testSuccessfulFetchPublishesModelUsageFromScopedWeeklyLimit() async throws {
        let dependencies = makeDependencies(
            scheduler: PollSchedulerSpy(),
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { _ in
                (
                    self.makeSuccessPayload(
                        utilization: 42,
                        weeklyUtilization: 58,
                        scopedWeeklyLimit: (modelName: "Fable", percent: 59)
                    ),
                    self.makeResponse(statusCode: 200)
                )
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)

        await service.performFetch(with: "token")

        XCTAssertEqual(service.currentModelUsage?.usagePercentage, 59)
        XCTAssertEqual(service.currentModelUsageName, "Fable")
    }

    func testSevenDayOpusTakesPrecedenceOverSevenDaySonnet() async throws {
        let dependencies = makeDependencies(
            scheduler: PollSchedulerSpy(),
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { _ in
                (
                    self.makeSuccessPayload(
                        utilization: 42,
                        weeklyUtilization: 58,
                        sonnetUtilization: 22,
                        opusUtilization: 31
                    ),
                    self.makeResponse(statusCode: 200)
                )
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)

        await service.performFetch(with: "token")

        XCTAssertEqual(service.currentModelUsage?.usagePercentage, 31)
        XCTAssertEqual(service.currentModelUsageName, "Opus")
    }

    func testScopedWeeklyLimitTakesPrecedenceOverSevenDaySonnet() async throws {
        let dependencies = makeDependencies(
            scheduler: PollSchedulerSpy(),
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { _ in
                (
                    self.makeSuccessPayload(
                        utilization: 42,
                        weeklyUtilization: 58,
                        sonnetUtilization: 22,
                        scopedWeeklyLimit: (modelName: "Fable", percent: 59)
                    ),
                    self.makeResponse(statusCode: 200)
                )
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)

        await service.performFetch(with: "token")

        XCTAssertEqual(service.currentModelUsage?.usagePercentage, 59)
        XCTAssertEqual(service.currentModelUsageName, "Fable")
    }

    func testSuccessfulFetchWithoutModelBucketLeavesModelUsageNil() async throws {
        let dependencies = makeDependencies(
            scheduler: PollSchedulerSpy(),
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { _ in
                (self.makeSuccessPayload(utilization: 42, weeklyUtilization: 58), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)

        await service.performFetch(with: "token")

        XCTAssertNil(service.currentModelUsage)
        XCTAssertNil(service.currentModelUsageName)
    }

    func testSuccessfulFetchWithoutSevenDayLeavesWeeklyUsageNil() async throws {
        let dependencies = makeDependencies(
            scheduler: PollSchedulerSpy(),
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { _ in
                (self.makeSuccessPayload(utilization: 42), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)

        await service.performFetch(with: "token")

        XCTAssertEqual(service.currentUsage?.usagePercentage, 42)
        XCTAssertNil(service.currentWeeklyUsage)
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

    func testUserAgentIsResolvedOnceAndCachedAcrossFetches() async throws {
        let scheduler = PollSchedulerSpy()
        var resolveCalls = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: {
                resolveCalls += 1
                return "claude-code/2.1.77"
            },
            fetchUsage: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "claude-code/2.1.77")
                return (self.makeSuccessPayload(utilization: 42), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")
        await service.performFetch(with: "token")

        XCTAssertEqual(resolveCalls, 1)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 42)
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
            getCachedOAuthToken: { "token" },
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
            getCachedOAuthToken: { "token" },
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

    func testStoppedPollingDropsAlreadyFiredTimerCallbackBeforeFetchStarts() async throws {
        let scheduler = PollSchedulerSpy()
        let recorder = RequestRecorder()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { "token" },
            fetchUsage: { request in
                recorder.record(request)
                return (self.makeSuccessPayload(utilization: 42), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()

        recorder.reset()
        scheduler.fireLast()
        service.stopPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(recorder.paths.isEmpty)
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
            getCachedOAuthToken: { "token" },
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
            getCachedOAuthToken: { "token" },
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
            getCachedOAuthToken: { "token" },
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

    func testRateLimitWithoutCachedUsageShowsRetryStateUsingRetryAfterBackoff() async throws {
        let cases: [(retryAfter: String, expectedError: String, expectedInterval: TimeInterval)] = [
            ("0", "Rate limited, retrying in 120s", 120),
            ("300", "Rate limited, retrying in 300s", 300),
        ]

        for (retryAfter, expectedError, expectedInterval) in cases {
            let recorder = RequestRecorder()
            let (service, scheduler) = makeService(
                fetchUsage: oauth429ThenHeaders(recorder: recorder, retryAfter: retryAfter) { _, _ in
                    (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
                }
            )
            await service.performFetch(with: "token")

            recorder.assertMixed(["/api/oauth/usage", "/v1/messages"])
            XCTAssertNil(service.currentUsage, "Retry-After \(retryAfter)")
            XCTAssertEqual(service.error, expectedError, "Retry-After \(retryAfter)")
            XCTAssertNil(service.statusMessage, "Retry-After \(retryAfter)")
            XCTAssertFalse(service.isUsageStale, "Retry-After \(retryAfter)")
            XCTAssertEqual(service.recoveryAction, .retry, "Retry-After \(retryAfter)")
            XCTAssertEqual(scheduler.intervals, [expectedInterval], "Retry-After \(retryAfter)")
        }
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
            getCachedOAuthToken: { "token" },
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
}
