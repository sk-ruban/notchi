import XCTest
@testable import notchi

@MainActor
final class ModeBadgeViewTests: XCTestCase {
    func testPlanBadgeColorComesFromRawModeNotDisplayText() {
        let badge = ModeBadgeView(mode: "플랜 모드", rawMode: "plan")
        XCTAssertEqual(badge.color, TerminalColors.planMode)
    }

    func testAcceptEditsBadgeColorComesFromRawModeNotDisplayText() {
        let badge = ModeBadgeView(mode: "編集を許可", rawMode: "acceptEdits")
        XCTAssertEqual(badge.color, TerminalColors.acceptEdits)
    }

    func testUnknownRawModeFallsBackToSecondaryTextColor() {
        let badge = ModeBadgeView(mode: "Bypass", rawMode: "bypassPermissions")
        XCTAssertEqual(badge.color, TerminalColors.secondaryText)
    }
}
