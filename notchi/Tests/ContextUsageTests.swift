import XCTest
@testable import notchi

final class ContextUsageTests: XCTestCase {
    func testContextIsNearlyFullAtEightyPercent() {
        XCTAssertTrue(ContextUsage(usedTokens: 160_000, windowTokens: 200_000).isNearlyFull)
    }

    func testContextIsNotNearlyFullJustBelowEightyPercent() {
        XCTAssertFalse(ContextUsage(usedTokens: 159_999, windowTokens: 200_000).isNearlyFull)
    }

    func testFractionIsCappedAtFullWhenUsageExceedsTheWindow() {
        XCTAssertEqual(ContextUsage(usedTokens: 250_000, windowTokens: 200_000).fraction, 1)
    }

    func testFractionIsUsedOverWindow() {
        XCTAssertEqual(ContextUsage(usedTokens: 250_000, windowTokens: 1_000_000).fraction, 0.25)
    }
}
