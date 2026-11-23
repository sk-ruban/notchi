import SwiftUI
import XCTest
@testable import notchi

@MainActor
final class ModeBadgeViewTests: XCTestCase {
    /// Narrower than "Bypass" at the panel's 11pt font, like a header row squeezed by a hovered context ring.
    private static let squeezedWidth: CGFloat = 10

    func testModeBadgeKeepsItsFullSizeWhenTheHeaderRowIsSqueezed() {
        let badge = NSHostingController(rootView: ModeBadgeView(mode: "Bypass", rawMode: "bypassPermissions"))
        let fullSize = badge.sizeThatFits(in: CGSize(width: CGFloat.infinity, height: .infinity))

        let squeezedSize = badge.sizeThatFits(in: CGSize(width: Self.squeezedWidth, height: .infinity))

        XCTAssertEqual(squeezedSize, fullSize)
    }

    func testPlanBadgeColorComesFromRawModeNotDisplayText() {
        let badge = ModeBadgeView(mode: "플랜 모드", rawMode: "plan")
        XCTAssertEqual(badge.color, TerminalColors.planMode)
    }

    func testAcceptEditsBadgeColorComesFromRawModeNotDisplayText() {
        let badge = ModeBadgeView(mode: "編集を許可", rawMode: "acceptEdits")
        XCTAssertEqual(badge.color, TerminalColors.acceptEdits)
    }

    func testAutoBadgeColorComesFromRawModeNotDisplayText() {
        let badge = ModeBadgeView(mode: "自動", rawMode: "auto")
        XCTAssertEqual(badge.color, TerminalColors.autoMode)
    }

    func testBypassBadgeUsesBypassPermissionsColor() {
        let badge = ModeBadgeView(mode: "Bypass", rawMode: "bypassPermissions")
        XCTAssertEqual(badge.color, TerminalColors.bypassPermissions)
    }

    func testDontAskBadgeSharesBypassPermissionsColor() {
        let badge = ModeBadgeView(mode: "Don't Ask", rawMode: "dontAsk")
        XCTAssertEqual(badge.color, TerminalColors.bypassPermissions)
    }

    func testCodexReadOnlyUsesSecondaryTextColor() {
        let badge = ModeBadgeView(mode: "Read Only", rawMode: CodexPermissionMode.readOnly)
        XCTAssertEqual(badge.color, TerminalColors.secondaryText)
    }

    func testCodexDefaultSharesAcceptEditsColor() {
        let badge = ModeBadgeView(mode: "Default", rawMode: CodexPermissionMode.standard)
        XCTAssertEqual(badge.color, TerminalColors.acceptEdits)
    }

    func testCodexFullAccessSharesBypassColor() {
        let badge = ModeBadgeView(mode: "Full Access", rawMode: CodexPermissionMode.fullAccess)
        XCTAssertEqual(badge.color, TerminalColors.bypassPermissions)
    }

    func testUnknownRawModeFallsBackToSecondaryTextColor() {
        let badge = ModeBadgeView(mode: "Mystery", rawMode: "somethingNew")
        XCTAssertEqual(badge.color, TerminalColors.secondaryText)
    }
}
