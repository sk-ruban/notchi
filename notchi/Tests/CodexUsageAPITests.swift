import XCTest
@testable import notchi

final class CodexUsageAPITests: XCTestCase {
    private func makeJWT(exp: Double) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["exp": exp])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }

    func testAuthLoadReadsAccessTokenAndAccountId() throws {
        let data = Data("""
        { "tokens": { "access_token": "tok-123", "account_id": "acc-9", "refresh_token": "r" } }
        """.utf8)

        let auth = try XCTUnwrap(CodexAPIAuth.load(from: data))

        XCTAssertEqual(auth.accessToken, "tok-123")
        XCTAssertEqual(auth.accountId, "acc-9")
    }

    func testAuthLoadReturnsNilWhenAccessTokenMissing() {
        let data = Data(#"{ "tokens": { "account_id": "acc-9" } }"#.utf8)
        XCTAssertNil(CodexAPIAuth.load(from: data))
    }

    func testAccessTokenExpiryParsesJWTExp() throws {
        let token = makeJWT(exp: 1_777_000_000)
        let expiry = try XCTUnwrap(CodexUsageAPI.accessTokenExpiry(token))
        XCTAssertEqual(expiry.timeIntervalSince1970, 1_777_000_000, accuracy: 0.001)
    }

    func testIsAccessTokenExpiredTrueForPastExpiry() {
        let token = makeJWT(exp: 1_000)
        XCTAssertTrue(CodexUsageAPI.isAccessTokenExpired(token, now: Date(timeIntervalSince1970: 2_000)))
    }

    func testIsAccessTokenExpiredFalseForFutureExpiry() {
        let token = makeJWT(exp: 9_000)
        XCTAssertFalse(CodexUsageAPI.isAccessTokenExpired(token, now: Date(timeIntervalSince1970: 2_000)))
    }

    func testUnparseableTokenIsTreatedAsUsable() {
        XCTAssertFalse(CodexUsageAPI.isAccessTokenExpired("not-a-jwt", now: Date()))
    }

    func testRequestCarriesBearerTokenAndAccountHeader() {
        let request = CodexUsageAPI.makeRequest(auth: CodexAPIAuth(accessToken: "tok-123", accountId: "acc-9"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acc-9")
        XCTAssertEqual(request.url, CodexUsageAPI.usageURL)
    }

    func testUsageParsesReviewsWindowAndCreditsBalance() throws {
        let data = Data("""
        {
          "code_review_rate_limit": { "primary_window": { "used_percent": 42.0, "reset_at": 1777621726 } },
          "credits": { "balance": 310 }
        }
        """.utf8)
        let response = try JSONDecoder().decode(CodexUsageAPIResponse.self, from: data)

        let usage = CodexUsageAPI.usage(from: response, now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(usage.reviews?.usagePercentage, 42)
        let reviewReset = try XCTUnwrap(usage.reviews?.resetDate)
        XCTAssertEqual(reviewReset.timeIntervalSince1970, 1_777_621_726, accuracy: 0.001)
        XCTAssertEqual(usage.creditsBalance, 310)
    }

    func testUsageUsesResetAfterSecondsWhenAbsoluteResetMissing() throws {
        let data = Data("""
        { "code_review_rate_limit": { "primary_window": { "used_percent": 10.0, "reset_after_seconds": 3600 } } }
        """.utf8)
        let response = try JSONDecoder().decode(CodexUsageAPIResponse.self, from: data)

        let usage = CodexUsageAPI.usage(from: response, now: Date(timeIntervalSince1970: 1_000))

        let reviewReset = try XCTUnwrap(usage.reviews?.resetDate)
        XCTAssertEqual(reviewReset.timeIntervalSince1970, 4_600, accuracy: 0.001)
    }

    func testUsageParsesStringCreditsBalance() throws {
        let data = Data(#"{ "credits": { "has_credits": true, "balance": "1250" } }"#.utf8)
        let response = try JSONDecoder().decode(CodexUsageAPIResponse.self, from: data)

        XCTAssertEqual(CodexUsageAPI.usage(from: response, now: Date()).creditsBalance, 1250)
    }

    func testUsageParsesSessionAndWeeklyFromRateLimit() throws {
        let data = Data("""
        {
          "rate_limit": {
            "primary_window": { "used_percent": 27.0, "reset_at": 1777103326 },
            "secondary_window": { "used_percent": 9.0, "reset_at": 1777621726 }
          }
        }
        """.utf8)
        let response = try JSONDecoder().decode(CodexUsageAPIResponse.self, from: data)

        let usage = CodexUsageAPI.usage(from: response, now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(usage.session?.usagePercentage, 27)
        XCTAssertEqual(usage.weekly?.usagePercentage, 9)
    }

    func testUsageClassifiesSizedAndSingleWindows() throws {
        let cases: [(String, Int?, Int?)] = [
            (#"{"primary_window":{"used_percent":11,"window_minutes":300,"reset_at":5000},"secondary_window":{"used_percent":27,"window_minutes":10080,"reset_at":8000}}"#, 11, 27),
            (#"{"primary_window":{"used_percent":22,"window_minutes":10080,"reset_at":8000}}"#, nil, 22),
            (#"{"primary_window":{"used_percent":22,"reset_at":8000}}"#, nil, 22),
            (#"{"primary_window":{"used_percent":11,"window_minutes":300,"reset_at":5000}}"#, 11, nil)
        ]
        for (windows, session, weekly) in cases {
            let data = Data("{\"rate_limit\":\(windows)}".utf8)
            let response = try JSONDecoder().decode(CodexUsageAPIResponse.self, from: data)
            let usage = CodexUsageAPI.usage(from: response, now: Date(timeIntervalSince1970: 1_000))
            XCTAssertEqual(usage.session?.usagePercentage, session)
            XCTAssertEqual(usage.weekly?.usagePercentage, weekly)
        }
    }

    @MainActor
    func testRefreshFromAPIPopulatesSessionWeeklyAndCredits() async throws {
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            loadAuth: { .authenticated(CodexAPIAuth(accessToken: "token", accountId: "account")) },
            fetchAPIUsage: { _ in
                CodexAPIUsage(
                    session: QuotaPeriod(utilization: 40, resetDate: Date(timeIntervalSince1970: 9_999_999_999)),
                    weekly: QuotaPeriod(utilization: 12, resetDate: Date(timeIntervalSince1970: 9_999_999_999)),
                    creditsBalance: 100
                )
            },
            now: { Date(timeIntervalSince1970: 1_000) }
        ))

        await service.refreshFromAPI()

        XCTAssertEqual(service.currentUsage?.usagePercentage, 40)
        XCTAssertEqual(service.currentWeeklyUsage?.usagePercentage, 12)
        let credits = try XCTUnwrap(service.currentExtraCreditsUSD)
        XCTAssertEqual(credits, 100 * CodexUsageAPI.creditUSDRate, accuracy: 0.0001)
    }

    func testUsageTreatsHasCreditsFalseAsZeroBalance() throws {
        let data = Data(#"{ "credits": { "has_credits": false } }"#.utf8)
        let response = try JSONDecoder().decode(CodexUsageAPIResponse.self, from: data)

        XCTAssertEqual(CodexUsageAPI.usage(from: response, now: Date()).creditsBalance, 0)
    }

    func testUsageLeavesReviewsAndCreditsNilWhenAbsent() throws {
        let response = try JSONDecoder().decode(CodexUsageAPIResponse.self, from: Data("{}".utf8))
        let usage = CodexUsageAPI.usage(from: response, now: Date())
        XCTAssertNil(usage.reviews)
        XCTAssertNil(usage.creditsBalance)
    }

    @MainActor
    func testRefreshPublishesReviewsAndCreditsFromAPI() async throws {
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            loadAuth: { .authenticated(CodexAPIAuth(accessToken: "token", accountId: "account")) },
            fetchAPIUsage: { _ in
                CodexAPIUsage(
                    reviews: QuotaPeriod(utilization: 42, resetDate: Date(timeIntervalSince1970: 9_999_999_999)),
                    creditsBalance: 310
                )
            },
            now: { Date(timeIntervalSince1970: 9_000_000_000) }
        ))

        await service.refreshFromAPI()

        XCTAssertEqual(service.currentReviewsUsage?.usagePercentage, 42)
        let credits = try XCTUnwrap(service.currentExtraCreditsUSD)
        XCTAssertEqual(credits, 310 * CodexUsageAPI.creditUSDRate, accuracy: 0.0001)
    }

    @MainActor
    func testTransientAPIFailureRetainsLastGoodValues() async throws {
        let state = MutableFetchState(now: Date(timeIntervalSince1970: 1_000))
        state.result = CodexAPIUsage(
            session: QuotaPeriod(utilization: 55, resetDate: Date(timeIntervalSince1970: 5_000)),
            reviews: QuotaPeriod(utilization: 30, resetDate: Date(timeIntervalSince1970: 9_999_999_999)),
            creditsBalance: 100
        )
        let counter = CallCounter()
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            loadAuth: { .authenticated(CodexAPIAuth(accessToken: "token", accountId: "account")) },
            fetchAPIUsage: { _ in
                await counter.bump()
                return state.result
            },
            now: { state.now }
        ))

        await service.refreshFromAPI()
        let firstCredits = try XCTUnwrap(service.currentExtraCreditsUSD)
        XCTAssertEqual(firstCredits, 100 * CodexUsageAPI.creditUSDRate, accuracy: 0.0001)

        state.now = Date(timeIntervalSince1970: 1_000 + 120)
        state.result = nil
        await service.refreshFromAPI()

        XCTAssertEqual(service.currentReviewsUsage?.usagePercentage, 30)
        let retainedCredits = try XCTUnwrap(service.currentExtraCreditsUSD)
        XCTAssertEqual(retainedCredits, 100 * CodexUsageAPI.creditUSDRate, accuracy: 0.0001)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 55)
        XCTAssertEqual(service.lastObservedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(service.isUsageStale)

        state.result = CodexAPIUsage(session: QuotaPeriod(
            utilization: 99, resetDate: Date(timeIntervalSince1970: 5_000)
        ))
        await service.refreshFromAPI()
        let fetchCount = await counter.count
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 55)
        XCTAssertTrue(service.isUsageStale)
        XCTAssertEqual(service.lastObservedAt, Date(timeIntervalSince1970: 1_000))
    }

    @MainActor
    func testIdleRefreshAppliesCachedSessionWeeklyWhenThrottled() async {
        let counter = CallCounter()
        let now = Date(timeIntervalSince1970: 1_000)
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            loadAuth: { .authenticated(CodexAPIAuth(accessToken: "token", accountId: "account")) },
            fetchAPIUsage: { _ in
                await counter.bump()
                return CodexAPIUsage(
                    session: QuotaPeriod(utilization: 73, resetDate: Date(timeIntervalSince1970: 9_999_999_999)),
                    weekly: QuotaPeriod(utilization: 8, resetDate: Date(timeIntervalSince1970: 9_999_999_999)),
                    reviews: nil,
                    creditsBalance: nil
                )
            },
            now: { now }
        ))

        // Active refresh uses the authenticated account, independent of old transcripts.
        await service.refreshFromAPI()
        XCTAssertEqual(service.currentUsage?.usagePercentage, 73)

        // Session ends within the throttle window: retain the same API observation.
        await service.refreshFromAPI()

        let fetchCount = await counter.count
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 73)
        XCTAssertEqual(service.currentWeeklyUsage?.usagePercentage, 8)
    }

    @MainActor
    func testRapidRefreshesThrottleTheNetworkedAPIFetch() async {
        let counter = CallCounter()
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            loadAuth: { .authenticated(CodexAPIAuth(accessToken: "token", accountId: "account")) },
            fetchAPIUsage: { _ in
                await counter.bump()
                return CodexAPIUsage(reviews: nil, creditsBalance: nil)
            },
            now: { Date(timeIntervalSince1970: 9_000_000_000) }
        ))

        await service.refreshFromAPI()
        await service.refreshFromAPI()

        let count = await counter.count
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testAccountSwitchBypassesThrottleAndClearsPreviousAccountOnFailure() async {
        let state = MutableFetchState(now: Date(timeIntervalSince1970: 1_000))
        state.auth = CodexAPIAuth(accessToken: "old", accountId: "old-account")
        state.result = CodexAPIUsage(
            session: QuotaPeriod(utilization: 85, resetDate: Date(timeIntervalSince1970: 5_000)),
            weekly: QuotaPeriod(utilization: 95, resetDate: Date(timeIntervalSince1970: 8_000)),
            creditsBalance: 100
        )
        let counter = CallCounter()
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            loadAuth: { state.auth.map(CodexAuthRead.authenticated) ?? state.missingAuth },
            fetchAPIUsage: { _ in
                await counter.bump()
                return state.result
            },
            now: { state.now }
        ))
        await service.refreshFromAPI()
        XCTAssertEqual(service.currentUsage?.usagePercentage, 85)

        state.auth = CodexAPIAuth(accessToken: "new", accountId: "new-account")
        state.result = nil
        await service.refreshFromAPI()
        let count = await counter.count
        XCTAssertEqual(count, 2)
        XCTAssertNil(service.currentUsage)
        XCTAssertNil(service.currentWeeklyUsage)
        XCTAssertNil(service.currentExtraCreditsUSD)
        XCTAssertNil(service.lastObservedAt)
    }

    @MainActor
    func testAccountSwitchAndLogoutWithoutAnySession() async {
        let state = MutableFetchState(now: Date(timeIntervalSince1970: 1_000))
        state.auth = CodexAPIAuth(accessToken: "old", accountId: "old-account")
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            loadAuth: { state.auth.map(CodexAuthRead.authenticated) ?? state.missingAuth },
            fetchAPIUsage: { auth in
                CodexAPIUsage(session: QuotaPeriod(
                    utilization: auth.accountId == "old-account" ? 85 : 12,
                    resetDate: Date(timeIntervalSince1970: 5_000)
                ))
            },
            now: { state.now }
        ))
        await service.refreshFromAPI()
        state.auth = CodexAPIAuth(accessToken: "new", accountId: "new-account")
        await service.refreshFromAPI()
        XCTAssertEqual(service.currentUsage?.usagePercentage, 12)
        state.auth = nil
        state.missingAuth = .signedOut
        await service.refreshFromAPI()
        XCTAssertFalse(service.hasUsageData)
        XCTAssertNil(service.lastObservedAt)
    }

    @MainActor
    func testLateOldAccountResponseCannotOverwriteNewAccount() async {
        let state = MutableFetchState(now: Date(timeIntervalSince1970: 1_000))
        state.auth = CodexAPIAuth(accessToken: "old", accountId: "old-account")
        let gate = UsageResponseGate()
        let started = expectation(description: "Old account request started")
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            loadAuth: { state.auth.map(CodexAuthRead.authenticated) ?? state.missingAuth },
            fetchAPIUsage: { auth in
                if auth.accountId == "old-account" { return await gate.wait { started.fulfill() } }
                return CodexAPIUsage(session: QuotaPeriod(
                    utilization: 12, resetDate: Date(timeIntervalSince1970: 5_000)
                ))
            },
            now: { state.now }
        ))
        let oldRequest = Task { await service.refreshFromAPI() }
        await fulfillment(of: [started], timeout: 2)
        guard await gate.isWaiting else {
            oldRequest.cancel()
            return
        }
        state.auth = CodexAPIAuth(accessToken: "new", accountId: "new-account")
        await service.refreshFromAPI()
        await gate.resume(CodexAPIUsage(session: QuotaPeriod(
            utilization: 85, resetDate: Date(timeIntervalSince1970: 5_000)
        )))
        await oldRequest.value
        XCTAssertEqual(service.currentUsage?.usagePercentage, 12)
    }

    @MainActor
    func testCredentialChangeDuringRequestDiscardsResponseBeforeNextPoll() async {
        let state = MutableFetchState(now: Date(timeIntervalSince1970: 1_000))
        state.auth = CodexAPIAuth(accessToken: "old", accountId: "old-account")
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            loadAuth: { state.auth.map(CodexAuthRead.authenticated) ?? state.missingAuth },
            fetchAPIUsage: { auth in
                if auth.accountId == "new-account" {
                    return CodexAPIUsage(session: QuotaPeriod(
                        utilization: 12, resetDate: Date(timeIntervalSince1970: 5_000)
                    ))
                }
                state.auth = CodexAPIAuth(accessToken: "new", accountId: "new-account")
                return CodexAPIUsage(
                    session: QuotaPeriod(utilization: 85, resetDate: Date(timeIntervalSince1970: 5_000)),
                    weekly: QuotaPeriod(utilization: 95, resetDate: Date(timeIntervalSince1970: 8_000)),
                    reviews: QuotaPeriod(utilization: 75, resetDate: Date(timeIntervalSince1970: 8_000)),
                    creditsBalance: 100
                )
            },
            now: { state.now }
        ))
        await service.refreshFromAPI()
        XCTAssertFalse(service.hasUsageData)
        XCTAssertNil(service.currentUsage)
        XCTAssertNil(service.currentWeeklyUsage)
        XCTAssertNil(service.currentReviewsUsage)
        XCTAssertNil(service.currentExtraCreditsUSD)
        XCTAssertNil(service.lastObservedAt)
        await service.refreshFromAPI()
        XCTAssertEqual(service.currentUsage?.usagePercentage, 12)
        XCTAssertEqual(service.lastObservedAt, state.now)
    }

    func testAuthReadDistinguishesIncompleteDataFromExplicitSignOut() {
        XCTAssertEqual(CodexUsageAPI.authRead(from: Data(#"{"tokens":"#.utf8)), .unavailable)
        XCTAssertEqual(CodexUsageAPI.authRead(from: Data(#"{"tokens":{}}"#.utf8)), .unavailable)
        XCTAssertEqual(CodexUsageAPI.authRead(from: Data(#"{"tokens":null}"#.utf8)), .signedOut)
        XCTAssertEqual(CodexUsageAPI.authRead(from: Data(#"{"auth_mode":"apikey"}"#.utf8)), .signedOut)
        XCTAssertEqual(CodexUsageAPI.authRead(from: Data(#"{"tokens":{"access_token":"new","account_id":"account"}}"#.utf8)),
                       .authenticated(CodexAPIAuth(accessToken: "new", accountId: "account")))
    }

    @MainActor
    func testTokenRotationAndUnavailableCredentialsPreserveSameAccountUsage() async {
        let state = MutableFetchState(now: Date(timeIntervalSince1970: 1_000))
        state.auth = CodexAPIAuth(accessToken: "old-token", accountId: "account")
        state.result = CodexAPIUsage(
            session: QuotaPeriod(utilization: 55, resetDate: Date(timeIntervalSince1970: 5_000)),
            weekly: QuotaPeriod(utilization: 65, resetDate: Date(timeIntervalSince1970: 8_000)),
            reviews: QuotaPeriod(utilization: 75, resetDate: Date(timeIntervalSince1970: 8_000)),
            creditsBalance: 100
        )
        let counter = CallCounter()
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            loadAuth: { state.auth.map(CodexAuthRead.authenticated) ?? .unavailable },
            fetchAPIUsage: { auth in
                await counter.bump()
                if state.now.timeIntervalSince1970 > 1_000 {
                    XCTAssertEqual(auth.accessToken, "rotated-token")
                }
                return state.result
            },
            now: { state.now }
        ))
        await service.refreshFromAPI()
        state.auth = CodexAPIAuth(accessToken: "rotated-token", accountId: "account")
        state.result = nil
        await service.refreshFromAPI()
        let count = await counter.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 55)
        state.auth = nil
        await service.refreshFromAPI()
        XCTAssertEqual(service.currentUsage?.usagePercentage, 55)
        XCTAssertTrue(service.isUsageStale)
        state.auth = CodexAPIAuth(accessToken: "rotated-token", accountId: "account")
        state.now = Date(timeIntervalSince1970: 1_060)
        await service.refreshFromAPI()
        XCTAssertEqual(service.currentUsage?.usagePercentage, 55)
        XCTAssertEqual(service.currentWeeklyUsage?.usagePercentage, 65)
        XCTAssertEqual(service.currentReviewsUsage?.usagePercentage, 75)
        XCTAssertEqual(service.currentExtraCreditsUSD, 4)
        XCTAssertEqual(service.lastObservedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(service.isUsageStale)
    }

    @MainActor
    func testTokenRotationOrUnavailableReadDuringRequestKeepsResponse() async {
        for unavailable in [false, true] {
            let state = MutableFetchState(now: Date(timeIntervalSince1970: 1_000))
            state.auth = CodexAPIAuth(accessToken: "old-token", accountId: "account")
            let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
                loadAuth: { state.auth.map(CodexAuthRead.authenticated) ?? .unavailable },
                fetchAPIUsage: { _ in
                    state.auth = unavailable ? nil : CodexAPIAuth(accessToken: "rotated-token", accountId: "account")
                    return CodexAPIUsage(session: QuotaPeriod(
                        utilization: 55, resetDate: Date(timeIntervalSince1970: 5_000)
                    ))
                },
                now: { state.now }
            ))
            await service.refreshFromAPI()
            XCTAssertEqual(service.currentUsage?.usagePercentage, 55)
            XCTAssertEqual(service.lastObservedAt, state.now)
        }
    }

    @MainActor
    func testPollingUsesMinuteIntervalAndStopsTimer() async {
        let state = MutableFetchState(now: Date(timeIntervalSince1970: 1_000))
        let firstFetch = expectation(description: "Initial fetch")
        let secondFetch = expectation(description: "Scheduled fetch")
        var scheduledAction: (@MainActor () -> Void)?
        let timer = TestCodexUsagePollTimer()
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            loadAuth: { .authenticated(CodexAPIAuth(accessToken: "token", accountId: "account")) },
            fetchAPIUsage: { _ in
                if state.now.timeIntervalSince1970 == 1_000 { firstFetch.fulfill() }
                else { secondFetch.fulfill() }
                return CodexAPIUsage()
            },
            now: { state.now },
            schedulePoll: { interval, action in
                XCTAssertEqual(interval, 60)
                scheduledAction = action
                return timer
            }
        ))
        service.startPolling()
        await fulfillment(of: [firstFetch], timeout: 2)
        state.now = Date(timeIntervalSince1970: 1_060)
        scheduledAction?()
        await fulfillment(of: [secondFetch], timeout: 2)
        service.stopPolling()
        XCTAssertTrue(timer.invalidated)
    }

}

private actor CallCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

private final class MutableFetchState: @unchecked Sendable {
    var now: Date
    var result: CodexAPIUsage?
    var auth: CodexAPIAuth?
    var missingAuth: CodexAuthRead = .unavailable
    init(now: Date) { self.now = now }
}

private actor UsageResponseGate {
    private var continuation: CheckedContinuation<CodexAPIUsage?, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait(onStart: @Sendable () -> Void) async -> CodexAPIUsage? {
        await withCheckedContinuation {
            continuation = $0
            onStart()
        }
    }

    func resume(_ usage: CodexAPIUsage) {
        continuation?.resume(returning: usage)
        continuation = nil
    }
}

@MainActor
private final class TestCodexUsagePollTimer: CodexUsagePollTimer {
    var invalidated = false
    func invalidate() { invalidated = true }
}
