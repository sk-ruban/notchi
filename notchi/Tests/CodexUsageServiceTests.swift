import XCTest
@testable import notchi

@MainActor
final class CodexUsageServiceTests: XCTestCase {
    func testRefreshPublishesWeeklyOnlySnapshot() async {
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            loadAuth: { .authenticated(CodexAPIAuth(accessToken: "token", accountId: "account")) },
            fetchAPIUsage: { _ in
                CodexAPIUsage(
                    session: nil,
                    weekly: QuotaPeriod(utilization: 22, resetDate: Date(timeIntervalSince1970: 2_000))
                )
            },
            now: { Date(timeIntervalSince1970: 1_010) }
        ))

        await service.refreshFromAPI()

        XCTAssertNil(service.currentUsage)
        XCTAssertEqual(service.currentWeeklyUsage?.usagePercentage, 22)
        XCTAssertTrue(service.hasUsageData)
    }

    func testRefreshDropsExpiredSessionQuotaWhenWeeklyQuotaStillValid() async {
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            loadAuth: { .authenticated(CodexAPIAuth(accessToken: "token", accountId: "account")) },
            fetchAPIUsage: { _ in
                CodexAPIUsage(
                    session: QuotaPeriod(utilization: 61, resetDate: Date(timeIntervalSince1970: 1_000)),
                    weekly: QuotaPeriod(utilization: 22, resetDate: Date(timeIntervalSince1970: 5_000))
                )
            },
            now: { Date(timeIntervalSince1970: 1_010) }
        ))

        await service.refreshFromAPI()

        XCTAssertNil(service.currentUsage)
        XCTAssertEqual(service.currentWeeklyUsage?.usagePercentage, 22)
        XCTAssertEqual(service.displayUsage?.usagePercentage, 22)
    }

    func testRefreshDropsExpiredWeeklyQuotaWhenSessionQuotaStillValid() async {
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            loadAuth: { .authenticated(CodexAPIAuth(accessToken: "token", accountId: "account")) },
            fetchAPIUsage: { _ in
                CodexAPIUsage(
                    session: QuotaPeriod(utilization: 61, resetDate: Date(timeIntervalSince1970: 1_500)),
                    weekly: QuotaPeriod(utilization: 22, resetDate: Date(timeIntervalSince1970: 1_000))
                )
            },
            now: { Date(timeIntervalSince1970: 1_010) }
        ))

        await service.refreshFromAPI()

        XCTAssertEqual(service.currentUsage?.usagePercentage, 61)
        XCTAssertNil(service.currentWeeklyUsage)
    }

    func testDisplayUsageFallsBackToWeeklyWhenSessionQuotaMissing() async {
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            loadAuth: { .authenticated(CodexAPIAuth(accessToken: "token", accountId: "account")) },
            fetchAPIUsage: { _ in
                CodexAPIUsage(
                    session: nil,
                    weekly: QuotaPeriod(utilization: 22, resetDate: Date(timeIntervalSince1970: 2_000))
                )
            },
            now: { Date(timeIntervalSince1970: 1_010) }
        ))

        await service.refreshFromAPI()

        XCTAssertEqual(service.displayUsage?.usagePercentage, 22)
    }

    func testDisplayUsagePrefersSessionQuotaWhenPresent() async {
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            loadAuth: { .authenticated(CodexAPIAuth(accessToken: "token", accountId: "account")) },
            fetchAPIUsage: { _ in
                CodexAPIUsage(
                    session: QuotaPeriod(utilization: 61, resetDate: Date(timeIntervalSince1970: 1_500)),
                    weekly: QuotaPeriod(utilization: 22, resetDate: Date(timeIntervalSince1970: 2_000))
                )
            },
            now: { Date(timeIntervalSince1970: 1_010) }
        ))

        await service.refreshFromAPI()

        XCTAssertEqual(service.displayUsage?.usagePercentage, 61)
    }

    func testRefreshClearsExpiredUsage() async {
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            loadAuth: { .authenticated(CodexAPIAuth(accessToken: "token", accountId: "account")) },
            fetchAPIUsage: { _ in
                CodexAPIUsage(
                    session: QuotaPeriod(utilization: 11, resetDate: Date(timeIntervalSince1970: 900)),
                    weekly: nil
                )
            },
            now: { Date(timeIntervalSince1970: 1_000) }
        ))

        await service.refreshFromAPI()

        XCTAssertNil(service.currentUsage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertNil(service.lastObservedAt)
    }
}
