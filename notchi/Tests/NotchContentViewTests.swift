import XCTest
@testable import notchi

final class NotchContentViewTests: XCTestCase {
    func testCollapsedHeaderStateUsesIdleFallbackWhenCompactIdleIsDisabled() {
        XCTAssertEqual(
            NotchContentView.collapsedHeaderState(activeSessionState: nil, isCompactIdle: false),
            .idle
        )
    }

    func testCollapsedHeaderStateOmitsSpriteInCompactIdleMode() {
        XCTAssertNil(
            NotchContentView.collapsedHeaderState(activeSessionState: nil, isCompactIdle: true)
        )
    }

    func testCollapsedHeaderStatePrefersActiveSessionState() {
        XCTAssertEqual(
            NotchContentView.collapsedHeaderState(activeSessionState: .working, isCompactIdle: false),
            .working
        )
    }
}
