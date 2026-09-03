import XCTest
@testable import notchi

private enum VisibleScreenHeight {
    static let macBookAir15: CGFloat = 918
    static let studioDisplay: CGFloat = 1415
    static let lgSDQHD: CGFloat = 2855
}

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

    func testRingUsageFallsBackToCodexWeeklyQuotaWhenSessionQuotaMissing() {
        let weekly = QuotaPeriod(utilization: 40, resetsAt: nil)

        XCTAssertEqual(
            NotchContentView.collapsedRingUsage(
                provider: .codex,
                claudeUsage: nil,
                codexSessionUsage: nil,
                codexWeeklyUsage: weekly
            ),
            weekly
        )
    }

    func testRingUsagePrefersCodexSessionQuotaOverWeekly() {
        let session = QuotaPeriod(utilization: 62, resetsAt: nil)
        let weekly = QuotaPeriod(utilization: 40, resetsAt: nil)

        XCTAssertEqual(
            NotchContentView.collapsedRingUsage(
                provider: .codex,
                claudeUsage: nil,
                codexSessionUsage: session,
                codexWeeklyUsage: weekly
            ),
            session
        )
    }

    func testRingUsageUsesClaudeQuotaForClaudeProviderWithoutWeeklyFallback() {
        let claude = QuotaPeriod(utilization: 55, resetsAt: nil)
        let codexWeekly = QuotaPeriod(utilization: 40, resetsAt: nil)

        XCTAssertEqual(
            NotchContentView.collapsedRingUsage(
                provider: .claude,
                claudeUsage: claude,
                codexSessionUsage: nil,
                codexWeeklyUsage: codexWeekly
            ),
            claude
        )

        XCTAssertNil(
            NotchContentView.collapsedRingUsage(
                provider: .claude,
                claudeUsage: nil,
                codexSessionUsage: nil,
                codexWeeklyUsage: codexWeekly
            )
        )
    }

    func testCollapsedRingPercentageReturnsNonzeroUsage() {
        XCTAssertEqual(
            NotchContentView.collapsedRingPercentage(
                isUsageEnabled: true,
                provider: .claude,
                claudeUsage: QuotaPeriod(utilization: 42, resetsAt: nil),
                codexSessionUsage: nil,
                codexWeeklyUsage: nil
            ),
            42
        )
    }

    func testCollapsedRingPercentageHidesZeroUsage() {
        XCTAssertNil(
            NotchContentView.collapsedRingPercentage(
                isUsageEnabled: true,
                provider: .claude,
                claudeUsage: QuotaPeriod(utilization: 0, resetsAt: nil),
                codexSessionUsage: nil,
                codexWeeklyUsage: nil
            )
        )
    }

    func testCollapsedRingPercentageHidesUsageWhenDisabled() {
        XCTAssertNil(
            NotchContentView.collapsedRingPercentage(
                isUsageEnabled: false,
                provider: .claude,
                claudeUsage: QuotaPeriod(utilization: 42, resetsAt: nil),
                codexSessionUsage: nil,
                codexWeeklyUsage: nil
            )
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

    func testTextIsUnscaledWhenPanelIsNotEnlarged() {
        XCTAssertEqual(PanelTypography.fontScale(panelScale: 1), 1)
    }

    func testTextGrowsMoreGentlyThanThePanelSoLargeFitsMoreContent() {
        let panelScale: CGFloat = 1.25
        let fontScale = PanelTypography.fontScale(panelScale: panelScale)

        XCTAssertLessThan(fontScale, panelScale)
        XCTAssertEqual(13 * fontScale, 14.625, accuracy: 0.001)
    }

    func testFeedGrowsWithPanelSoTheGapAboveTheSpinnerStaysProportional() {
        let standard = ExpandedPanelView.feedMaxHeight(mode: .full, panelScale: 1)
        let large = ExpandedPanelView.feedMaxHeight(mode: .full, panelScale: 1.25)

        XCTAssertEqual(standard, ExpandedPanelView.defaultFeedMaxHeight)
        XCTAssertEqual(large, 250)
    }

    func testCompactFeedAlsoGrowsWithPanel() {
        XCTAssertEqual(
            ExpandedPanelView.feedMaxHeight(mode: .compact, panelScale: 1.25),
            400
        )
    }

    func testUsageRowsStackInOneColumnWhenPanelIsEnlarged() {
        XCTAssertFalse(
            UsageDetailView.usesTwoColumnLayout(rowCount: 3, showGrassIsland: true, panelScale: 1.25)
        )
    }

    func testUsageRowsUseTwoColumnsAtStandardScaleToFitThreeRows() {
        XCTAssertTrue(
            UsageDetailView.usesTwoColumnLayout(rowCount: 3, showGrassIsland: true, panelScale: 1)
        )
        XCTAssertFalse(
            UsageDetailView.usesTwoColumnLayout(rowCount: 2, showGrassIsland: true, panelScale: 1)
        )
        XCTAssertFalse(
            UsageDetailView.usesTwoColumnLayout(rowCount: 3, showGrassIsland: false, panelScale: 1)
        )
    }

    func testAutomaticPicksStandardOnBuiltInLaptopHeights() {
        XCTAssertEqual(
            ExpandedPanelScale.automatic.resolved(visibleScreenHeight: VisibleScreenHeight.macBookAir15),
            .standard
        )
    }

    func testAutomaticPicksLargeOnTallExternalDisplays() {
        XCTAssertEqual(
            ExpandedPanelScale.automatic.resolved(visibleScreenHeight: VisibleScreenHeight.studioDisplay),
            .large
        )
    }

    func testAutomaticTurnsLargeExactlyAtTheThreshold() {
        let threshold = ExpandedPanelScale.automaticLargeMinimumHeight

        XCTAssertEqual(ExpandedPanelScale.automatic.resolved(visibleScreenHeight: threshold), .large)
        XCTAssertEqual(ExpandedPanelScale.automatic.resolved(visibleScreenHeight: threshold - 1), .standard)
    }

    func testExplicitChoiceOverridesScreenHeightInBothDirections() {
        XCTAssertEqual(
            ExpandedPanelScale.standard.resolved(visibleScreenHeight: VisibleScreenHeight.lgSDQHD),
            .standard
        )
        XCTAssertEqual(
            ExpandedPanelScale.large.resolved(visibleScreenHeight: VisibleScreenHeight.macBookAir15),
            .large
        )
    }

    func testAutomaticMultiplierFollowsTheResolvedChoice() {
        XCTAssertEqual(
            ExpandedPanelScale.automatic.resolved(visibleScreenHeight: VisibleScreenHeight.macBookAir15).multiplier,
            1
        )
        XCTAssertEqual(
            ExpandedPanelScale.automatic.resolved(visibleScreenHeight: VisibleScreenHeight.lgSDQHD).multiplier,
            1.25
        )
    }

    func testSpritesStayAtNativeSizeWhenPanelIsNotEnlarged() {
        XCTAssertEqual(SpriteLayout.spriteScale(panelScale: 1), 1)
    }

    func testEnlargedSpriteSizeLandsOnWholePointsOnBothBackingScales() {
        let size = SpriteLayout.size * SpriteLayout.spriteScale(panelScale: 1.25)

        XCTAssertEqual(size, 72)
        XCTAssertEqual(size.truncatingRemainder(dividingBy: 1), 0)
        XCTAssertEqual((size * 2).truncatingRemainder(dividingBy: 1), 0)
    }

    func testHeaderRowIsTallEnoughForTheButtonItContains() {
        XCTAssertEqual(
            NotchContentView.expandedHeaderRowHeight,
            PanelHeaderButton.baseSize + NotchContentView.expandedHeaderTopPadding
        )
        XCTAssertGreaterThanOrEqual(NotchContentView.expandedHeaderRowHeight, PanelHeaderButton.baseSize)
    }

    func testPanelSizeAtStandardScaleMatchesLegacyFixedSize() {
        let size = NotchConstants.panelSize(scale: 1)

        XCTAssertEqual(size.height, NotchConstants.expandedPanelSize.height)
        XCTAssertEqual(
            size.width,
            NotchConstants.expandedPanelSize.width + NotchConstants.expandedPanelHorizontalPadding
        )
    }

    func testPanelSizeScalesEverythingExceptTheOuterChrome() {
        let scale = ExpandedPanelScale.large.multiplier

        let size = NotchConstants.panelSize(scale: scale)

        XCTAssertEqual(size.height, (450 - 24) * scale + 24, accuracy: 0.001)
        XCTAssertEqual(
            size.width,
            (450 - NotchConstants.expandedPanelContentInset) * scale
                + NotchConstants.expandedPanelHorizontalPadding
                + NotchConstants.expandedPanelHitTestSlack,
            accuracy: 0.001
        )
    }

    func testShortPickerIsUnconstrainedSoItDoesNotReserveEmptySpace() {
        XCTAssertNil(
            SettingsLayout.pickerViewportHeight(rowCount: NotchSlotContent.allCases.count, scale: 1)
        )
        XCTAssertNil(
            SettingsLayout.pickerViewportHeight(rowCount: SettingsLayout.pickerMaxVisibleRows, scale: 1)
        )
    }

    func testOverlongPickerIsCappedToTheVisibleRowLimit() throws {
        let capped = try XCTUnwrap(SettingsLayout.pickerViewportHeight(rowCount: 20, scale: 1))
        let firstOverflowing = try XCTUnwrap(SettingsLayout.pickerViewportHeight(rowCount: 7, scale: 1))

        XCTAssertEqual(capped, 6 * SettingsLayout.basePickerRowHeight + 5 * SettingsLayout.basePickerRowSpacing)
        XCTAssertEqual(capped, firstOverflowing)
    }

    func testCappedPickerViewportGrowsWithThePanel() throws {
        let largeScale = ExpandedPanelScale.large.multiplier
        let standard = try XCTUnwrap(SettingsLayout.pickerViewportHeight(rowCount: 20, scale: 1))
        let large = try XCTUnwrap(SettingsLayout.pickerViewportHeight(rowCount: 20, scale: largeScale))

        XCTAssertEqual(large, standard * largeScale, accuracy: 0.001)
    }



}
