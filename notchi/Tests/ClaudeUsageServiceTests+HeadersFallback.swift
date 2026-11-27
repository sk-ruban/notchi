import Foundation
import XCTest
@testable import notchi

extension ClaudeUsageServiceTests {
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
            XCTAssertEqual(service.error, "Claude authentication needs attention.")
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

    func testWeeklyUsageIsHeldOverWhileHeadersFallbackIsActive() async throws {
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

        XCTAssertFalse(service.isUsageStale)
        XCTAssertTrue(service.isWeeklyUsageHeldOver)
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

    func testOAuth403NonScopeBodiesStillFallBackToHeaders() async throws {
        let bodies: [(name: String, payload: Data)] = [
            (
                "ambiguous permission error",
                makeAnthropicErrorPayload(
                    type: "permission_error",
                    message: "Your account does not have permission to use this resource."
                )
            ),
            (
                "non-permission error with scope text",
                makeAnthropicErrorPayload(
                    type: "invalid_request_error",
                    message: "OAuth token scope is invalid"
                )
            ),
            ("empty body", Data()),
        ]

        for (name, payload) in bodies {
            let recorder = RequestRecorder()
            let (service, _) = makeService(
                fetchUsage: oauth403ThenHeaders(
                    recorder: recorder,
                    oauthResponse: { (payload, self.makeResponse(statusCode: 403)) }
                ) { _, _ in
                    (Data(), self.makeHeadersResponse(
                        utilization: "0.42",
                        reset: "2099-01-01T01:00:00Z"
                    ))
                }
            )
            await service.performFetch(with: "token")

            recorder.assertMixed(["/api/oauth/usage", "/v1/messages"])
            XCTAssertEqual(service.currentUsage?.usagePercentage, 42, name)
            XCTAssertEqual(service.recoveryAction, .none, name)
        }
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
        XCTAssertEqual(service.error, "Claude authentication needs attention.")
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
        XCTAssertEqual(service.error, "Claude authentication needs attention.")
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
        XCTAssertEqual(service.error, "Token expired.")
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
        XCTAssertEqual(service.statusMessage, "Stale data")
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

    func testOAuthShowsExtraUsageWhenQuotaIsMaxedAndEnabled() async throws {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { _ in
                (
                    self.makeSuccessPayload(
                        utilization: 100,
                        extraUsage: .init(isEnabled: true, monthlyLimit: 2000, usedCredits: 313, utilization: 15.65)
                    ),
                    self.makeResponse(statusCode: 200)
                )
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")
        XCTAssertTrue(service.isUsingExtraUsage)
        XCTAssertEqual(service.currentExtraUsage?.usedCredits, 313)
    }

    func testOAuthExtraUsageLatchResetsWhenUsageWindowChanges() async throws {
        let scheduler = PollSchedulerSpy()
        var call = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { _ in
                call += 1
                let payload: Data
                switch call {
                case 1:
                    payload = self.makeSuccessPayload(
                        utilization: 100,
                        resetAt: "2099-01-01T01:00:00Z",
                        extraUsage: .init(isEnabled: true, monthlyLimit: 2000, usedCredits: 313, utilization: 15.65)
                    )
                case 2:
                    payload = self.makeSuccessPayload(
                        utilization: 100,
                        resetAt: "2099-01-01T01:00:00Z",
                        extraUsage: .init(isEnabled: true, monthlyLimit: 2000, usedCredits: 314, utilization: 15.7)
                    )
                default:
                    payload = self.makeSuccessPayload(
                        utilization: 12,
                        resetAt: "2099-01-01T06:00:00Z",
                        extraUsage: .init(isEnabled: true, monthlyLimit: 2000, usedCredits: 314, utilization: 15.7)
                    )
                }
                return (payload, self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")
        await service.performFetch(with: "token")
        XCTAssertTrue(service.isUsingExtraUsage)

        await service.performFetch(with: "token")
        XCTAssertFalse(service.isUsingExtraUsage)
    }

    func testStartPollingRestoresPersistedExtraUsageObservationForCurrentWindow() async throws {
        let scheduler = PollSchedulerSpy()
        let resetAt = "2099-01-01T01:00:00Z"
        usageSettings.extraUsageObservation = ClaudeExtraUsageObservation(
            extraUsage: .init(isEnabled: true, monthlyLimit: 2000, usedCredits: 313, utilization: 15.65),
            lastObservedExtraUsageCredits: 313,
            extraUsageResetMarker: resetAt,
            isUsingExtraUsage: true
        )

        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { "cached-token" },
            fetchUsage: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cached-token")
                return (
                    self.makeSuccessPayload(
                        utilization: 100,
                        resetAt: resetAt,
                        extraUsage: .init(isEnabled: true, monthlyLimit: 2000, usedCredits: 313, utilization: 15.65)
                    ),
                    self.makeResponse(statusCode: 200)
                )
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        usageSettings.isUsageEnabled = true
        service.startPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(service.currentUsage?.usagePercentage, 100)
        XCTAssertEqual(service.currentExtraUsage?.usedCredits, 313)
        XCTAssertTrue(service.isUsingExtraUsage)
    }

    func testHeadersFallbackClearsExtraUsageLatchWhenUsageDropsBelowQuota() async throws {
        let scheduler = PollSchedulerSpy()
        var oauthCall = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                if path == "/api/oauth/usage" {
                    oauthCall += 1
                    switch oauthCall {
                    case 1:
                        return (
                            self.makeSuccessPayload(
                                utilization: 100,
                                extraUsage: .init(isEnabled: true, monthlyLimit: 2000, usedCredits: 313, utilization: 15.65)
                            ),
                            self.makeResponse(statusCode: 200)
                        )
                    case 2:
                        return (
                            self.makeSuccessPayload(
                                utilization: 100,
                                extraUsage: .init(isEnabled: true, monthlyLimit: 2000, usedCredits: 314, utilization: 15.7)
                            ),
                            self.makeResponse(statusCode: 200)
                        )
                    default:
                        return (Data(), self.makeResponse(statusCode: 403))
                    }
                }

                return (
                    Data(),
                    self.makeHeadersResponse(
                        utilization: "0.60",
                        reset: "2099-01-01T01:00:00Z"
                    )
                )
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")
        await service.performFetch(with: "token")
        XCTAssertTrue(service.isUsingExtraUsage)

        await service.performFetch(with: "token")

        XCTAssertEqual(service.currentUsage?.usagePercentage, 60)
        XCTAssertFalse(service.isUsingExtraUsage)
    }

    func testHeadersFallbackShowsExtraUsageWhenQuotaIsMaxed() async throws {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 429))
                }

                return (
                    Data(),
                    self.makeHeadersResponse(
                        utilization: "1.0",
                        reset: "2099-01-01T01:00:00Z"
                    )
                )
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertEqual(service.currentUsage?.usagePercentage, 100)
        XCTAssertTrue(service.isUsingExtraUsage)
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
        XCTAssertEqual(service.error, "Claude authentication needs attention.")
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
        XCTAssertEqual(service.error, "Claude authentication needs attention.")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }
}
