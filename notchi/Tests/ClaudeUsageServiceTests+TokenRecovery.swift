import Foundation
import XCTest
@testable import notchi

extension ClaudeUsageServiceTests {
    func testReconnectStateSchedulesSelfHealRetryThatResumesPolling() async throws {
        let scheduler = PollSchedulerSpy()
        var credentialsAvailable = false
        var serveSuccess = false
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { _ in nil },
            getOAuthCredentials: { _ in
                credentialsAvailable
                    ? self.makeCredentials(accessToken: "fresh-token", scopes: ["user:profile"])
                    : nil
            },
            fetchUsage: { _ in
                serveSuccess
                    ? (self.makeSuccessPayload(utilization: 30), self.makeResponse(statusCode: 200))
                    : (Data(), self.makeResponse(statusCode: 401))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        AppSettings.isUsageEnabled = true
        service.currentUsage = makeQuotaPeriod(utilization: 18)

        await service.performFetch(with: "old-token", consultCredentialMetadata: false)

        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.contains(300))

        credentialsAvailable = true
        serveSuccess = true
        scheduler.fireLast()
        for _ in 0..<6 { await Task.yield() }

        XCTAssertEqual(service.currentUsage?.usagePercentage, 30)
        XCTAssertEqual(service.recoveryAction, .none)
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
        XCTAssertEqual(service.error, "Claude authentication needs attention.")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.isEmpty)
        XCTAssertFalse(AppSettings.isUsageEnabled)
    }

    func testConnectAndStartPollingKeepsUsageEnabledWhenUsageIsVisible() async throws {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { _ in nil },
            getOAuthCredentials: { _ in nil },
            fetchUsage: { _ in
                XCTFail("fetchUsage should not run without a token")
                return (Data(), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.currentUsage = makeQuotaPeriod(utilization: 42)
        AppSettings.isUsageEnabled = true

        service.connectAndStartPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(AppSettings.isUsageEnabled)
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 42)
        XCTAssertEqual(scheduler.intervals, [300])
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

    func testSystemWakeKeepsUsageEnabledWhenKeychainBrieflyUnavailable() async throws {
        let scheduler = PollSchedulerSpy()
        var keychainAvailable = true
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { _ in keychainAvailable ? "token" : nil },
            getOAuthCredentials: { _ in nil },
            fetchUsage: { _ in
                (self.makeSuccessPayload(utilization: 42), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        AppSettings.isUsageEnabled = true

        service.startPolling()
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(service.currentUsage?.usagePercentage, 42)

        keychainAvailable = false
        service.startPolling(afterSystemWake: true)
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(AppSettings.isUsageEnabled)
        XCTAssertTrue(service.isConnected)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 42)
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

        XCTAssertTrue(AppSettings.isUsageEnabled)
        XCTAssertFalse(service.isConnected)
        XCTAssertNil(service.error)
        XCTAssertEqual(service.statusMessage, "Claude authentication needs attention.")
        XCTAssertTrue(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 42)
        XCTAssertTrue(scheduler.intervals.contains(300))
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
        XCTAssertEqual(service.error, "Start a Claude Code session to track usage")
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
        XCTAssertEqual(service.statusMessage, "Start a Claude Code session to track usage")
        XCTAssertTrue(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .waitForClaudeCode)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 55)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testHandleClaudeResumeTriggerSchedulesDelayedReconnect() async throws {
        for trigger in [ClaudeUsageResumeTrigger.sessionStart, .userPromptSubmit] {
            let scheduler = PollSchedulerSpy()
            var fetchCount = 0
            let fetchExpectation = expectation(description: "\(trigger.rawValue) triggers delayed usage reconnect")
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
            service.error = "Start a Claude Code session to track usage"

            service.handleClaudeResumeTrigger(trigger)

            XCTAssertEqual(fetchCount, 0, trigger.rawValue)
            XCTAssertEqual(scheduler.intervals, [2], trigger.rawValue)

            scheduler.fireLast()
            await fulfillment(of: [fetchExpectation], timeout: 1)

            XCTAssertEqual(fetchCount, 1, trigger.rawValue)
            XCTAssertEqual(service.currentUsage?.usagePercentage, 29, trigger.rawValue)
            XCTAssertEqual(service.recoveryAction, .none, trigger.rawValue)
            XCTAssertEqual(scheduler.intervals, [2, 60], trigger.rawValue)
        }
    }

    func testHandleClaudeResumeTriggerCoalescesMixedTriggersIntoOneReconnect() async throws {
        let triggerOrders: [[ClaudeUsageResumeTrigger]] = [
            [.sessionStart, .userPromptSubmit],
            [.userPromptSubmit, .sessionStart],
        ]

        for triggerOrder in triggerOrders {
            let orderName = triggerOrder.map(\.rawValue).joined(separator: " then ")
            let scheduler = PollSchedulerSpy()
            var fetchCount = 0
            let fetchExpectation = expectation(description: "\(orderName) coalesces into one reconnect")
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

            for trigger in triggerOrder {
                service.handleClaudeResumeTrigger(trigger)
            }

            XCTAssertEqual(fetchCount, 0, orderName)
            XCTAssertEqual(scheduler.intervals, [2], orderName)

            scheduler.fireLast()
            await fulfillment(of: [fetchExpectation], timeout: 1)

            XCTAssertEqual(fetchCount, 1, orderName)
            XCTAssertEqual(scheduler.intervals, [2, 60], orderName)
        }
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
        service.error = "Start a Claude Code session to track usage"

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
        XCTAssertEqual(service.error, "Start a Claude Code session to track usage")
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
        XCTAssertEqual(service.error, "Claude authentication needs attention.")
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
        XCTAssertEqual(service.error, "Start a Claude Code session to track usage")
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
}
