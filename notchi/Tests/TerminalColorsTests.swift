import SwiftUI
import XCTest
@testable import notchi

@MainActor
final class TerminalColorsTests: XCTestCase {
    func testUsageColorIsGreenBelowFiftyPercent() {
        XCTAssertEqual(TerminalColors.usageColor(forPercentUsed: 0), TerminalColors.green)
        XCTAssertEqual(TerminalColors.usageColor(forPercentUsed: 49), TerminalColors.green)
    }

    func testUsageColorIsAmberFromFiftyToBelowEightyPercent() {
        XCTAssertEqual(TerminalColors.usageColor(forPercentUsed: 50), TerminalColors.amber)
        XCTAssertEqual(TerminalColors.usageColor(forPercentUsed: 79), TerminalColors.amber)
    }

    func testUsageColorIsRedFromEightyPercent() {
        XCTAssertEqual(TerminalColors.usageColor(forPercentUsed: 80), TerminalColors.red)
        XCTAssertEqual(TerminalColors.usageColor(forPercentUsed: 100), TerminalColors.red)
    }
}
