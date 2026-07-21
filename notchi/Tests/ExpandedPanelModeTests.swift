import XCTest
@testable import notchi

final class ExpandedPanelModeTests: XCTestCase {
    func testHideGrassIslandForcesCompactMode() {
        XCTAssertEqual(
            NotchContentView.panelMode(hideGrassIsland: true, isActivityCollapsed: false),
            .compact
        )
        XCTAssertEqual(
            NotchContentView.panelMode(hideGrassIsland: true, isActivityCollapsed: true),
            .compact
        )
    }

    func testChevronCollapseTogglesFullAndIslandOnlyWhenGrassShown() {
        XCTAssertEqual(
            NotchContentView.panelMode(hideGrassIsland: false, isActivityCollapsed: false),
            .full
        )
        XCTAssertEqual(
            NotchContentView.panelMode(hideGrassIsland: false, isActivityCollapsed: true),
            .islandOnly
        )
    }
}
