import XCTest
@testable import notchi

final class ExpandedPanelModeTests: XCTestCase {
    func testHideGrassIslandForcesCompactMode() {
        XCTAssertEqual(
            NotchContentView.panelMode(showGrassIsland: false, isActivityCollapsed: false),
            .compact
        )
        XCTAssertEqual(
            NotchContentView.panelMode(showGrassIsland: false, isActivityCollapsed: true),
            .compact
        )
    }

    func testChevronCollapseTogglesFullAndIslandOnlyWhenGrassShown() {
        XCTAssertEqual(
            NotchContentView.panelMode(showGrassIsland: true, isActivityCollapsed: false),
            .full
        )
        XCTAssertEqual(
            NotchContentView.panelMode(showGrassIsland: true, isActivityCollapsed: true),
            .islandOnly
        )
    }
}
