import Foundation
import XCTest
@testable import notchi

@MainActor
final class DevinUsageServiceTests: XCTestCase {
    private static let observedAt = Date(timeIntervalSince1970: 1_790_490_000)
    private static let dailyUsage = QuotaPeriod(utilization: 1, resetDate: Date(timeIntervalSince1970: 1_790_496_000))
    private static let weeklyUsage = QuotaPeriod(utilization: 40, resetDate: Date(timeIntervalSince1970: 1_790_928_000))

    func testRefreshPublishesDailyAndWeeklyUsage() async {
        let service = DevinUsageService(
            readUsage: { _ in DevinUsage(daily: Self.dailyUsage, weekly: Self.weeklyUsage) },
            now: { Self.observedAt }
        )

        await service.refresh()

        XCTAssertEqual(service.currentUsage, Self.dailyUsage)
        XCTAssertEqual(service.currentWeeklyUsage, Self.weeklyUsage)
        XCTAssertEqual(service.lastObservedAt, Self.observedAt)
    }

    func testRefreshClearsUsageWhenDevinStateBecomesUnavailable() async {
        let reads = UsageReadSequence([DevinUsage(daily: Self.dailyUsage, weekly: Self.weeklyUsage), nil])
        let service = DevinUsageService(readUsage: { _ in reads.next() }, now: { Self.observedAt })

        await service.refresh()
        await service.refresh()

        XCTAssertNil(service.currentUsage)
        XCTAssertNil(service.currentWeeklyUsage)
        XCTAssertNil(service.lastObservedAt)
    }

    func testUsageIsStaleWhenDevinDesktopIsNotRunning() async {
        let service = DevinUsageService(
            readUsage: { _ in DevinUsage(daily: Self.dailyUsage, weekly: Self.weeklyUsage) },
            now: { Self.observedAt },
            isDesktopRunning: { false }
        )

        await service.refresh()

        XCTAssertTrue(service.isUsageStale)
    }

    func testUsageIsFreshWhileDevinDesktopIsRunning() async {
        let service = DevinUsageService(
            readUsage: { _ in DevinUsage(daily: Self.dailyUsage, weekly: Self.weeklyUsage) },
            now: { Self.observedAt },
            isDesktopRunning: { true }
        )

        await service.refresh()

        XCTAssertFalse(service.isUsageStale)
    }
}

private nonisolated final class UsageReadSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [DevinUsage?]

    init(_ reads: [DevinUsage?]) {
        remaining = reads
    }

    func next() -> DevinUsage? {
        lock.lock()
        defer { lock.unlock() }
        return remaining.isEmpty ? nil : remaining.removeFirst()
    }
}
