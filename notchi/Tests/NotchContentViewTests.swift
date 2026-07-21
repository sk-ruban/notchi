import XCTest
@testable import notchi

final class NotchContentViewTests: XCTestCase {
    func testSameNonNothingContentsConflict() {
        XCTAssertTrue(NotchSlotContent.conflict(.ring, .ring))
        XCTAssertTrue(NotchSlotContent.conflict(.latest, .latest))
        XCTAssertTrue(NotchSlotContent.conflict(.claude, .claude))
        XCTAssertTrue(NotchSlotContent.conflict(.codex, .codex))
    }

    func testNothingNeverConflicts() {
        XCTAssertFalse(NotchSlotContent.conflict(.nothing, .nothing))
        XCTAssertFalse(NotchSlotContent.conflict(.nothing, .claude))
        XCTAssertFalse(NotchSlotContent.conflict(.latest, .nothing))
    }

    func testLatestSessionConflictsWithAnySprite() {
        XCTAssertTrue(NotchSlotContent.conflict(.latest, .claude))
        XCTAssertTrue(NotchSlotContent.conflict(.codex, .latest))
    }

    func testTwoDistinctProvidersDoNotConflict() {
        XCTAssertFalse(NotchSlotContent.conflict(.claude, .codex))
    }

    func testUsageRingDoesNotConflictWithASprite() {
        XCTAssertFalse(NotchSlotContent.conflict(.ring, .claude))
        XCTAssertFalse(NotchSlotContent.conflict(.ring, .latest))
    }

    func testRingProviderFollowsDisplayedSpriteSessionOverSelectedSession() {
        let claudeSpriteSession = SessionData(sessionId: "claude-session", provider: .claude, cwd: "/tmp/project")
        let codexSelectedSession = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")

        XCTAssertEqual(
            NotchContentView.collapsedRingProvider(
                spriteSession: claudeSpriteSession,
                effectiveSession: codexSelectedSession,
                lastUsedProvider: .codex
            ),
            .claude
        )
    }

    func testRingProviderFallsBackToEffectiveSessionWithoutDisplayedSprite() {
        let codexSelectedSession = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")

        XCTAssertEqual(
            NotchContentView.collapsedRingProvider(
                spriteSession: nil,
                effectiveSession: codexSelectedSession,
                lastUsedProvider: .claude
            ),
            .codex
        )
    }

    func testRingProviderFallsBackToLastUsedProviderWhenIdle() {
        XCTAssertEqual(
            NotchContentView.collapsedRingProvider(
                spriteSession: nil,
                effectiveSession: nil,
                lastUsedProvider: .codex
            ),
            .codex
        )
    }

    func testGrassIslandRendersOnlyForExpandedActivityView() {
        XCTAssertTrue(
            NotchContentView.shouldRenderGrassIsland(
                isExpanded: true,
                showingPanelSettings: false,
                mode: .full
            )
        )
    }

    func testGrassIslandStaysRenderedDuringCollapseHandoff() {
        XCTAssertTrue(
            NotchContentView.shouldRenderGrassIsland(
                isExpanded: false,
                showingPanelSettings: false,
                mode: .full,
                keepsGrassIslandRenderedForHandoff: true
            )
        )
    }

    func testGrassIslandDoesNotRenderWhenCollapsedWithoutHandoffOrShowingSettings() {
        XCTAssertFalse(
            NotchContentView.shouldRenderGrassIsland(
                isExpanded: false,
                showingPanelSettings: false,
                mode: .full
            )
        )
        XCTAssertFalse(
            NotchContentView.shouldRenderGrassIsland(
                isExpanded: true,
                showingPanelSettings: true,
                mode: .full
            )
        )
    }

    func testGrassIslandHiddenInCompactMode() {
        XCTAssertFalse(
            NotchContentView.shouldShowGrassIsland(
                isExpanded: true,
                showingPanelSettings: false,
                mode: .compact
            )
        )
        XCTAssertTrue(
            NotchContentView.shouldShowGrassIsland(
                isExpanded: true,
                showingPanelSettings: false,
                mode: .full
            )
        )
        XCTAssertTrue(
            NotchContentView.shouldShowGrassIsland(
                isExpanded: true,
                showingPanelSettings: false,
                mode: .islandOnly
            )
        )
    }

    func testPanelSettingsHidesGrassInEveryMode() {
        for mode in ExpandedPanelMode.allCases {
            XCTAssertFalse(
                NotchContentView.shouldShowGrassIsland(
                    isExpanded: true,
                    showingPanelSettings: true,
                    mode: mode
                )
            )
        }
    }

    func testExpandedPanelHeightPerMode() {
        let notchHeight: CGFloat = 38
        let fullHeight = NotchConstants.expandedPanelSize.height - notchHeight - 24
        XCTAssertEqual(
            NotchContentView.expandedPanelHeight(mode: .full, notchHeight: notchHeight),
            fullHeight
        )
        XCTAssertEqual(
            NotchContentView.expandedPanelHeight(mode: .compact, notchHeight: notchHeight),
            fullHeight
        )
        XCTAssertEqual(
            NotchContentView.expandedPanelHeight(mode: .islandOnly, notchHeight: notchHeight),
            NotchContentView.islandOnlyPanelHeight
        )
    }
}
