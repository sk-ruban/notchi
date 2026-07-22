import AppKit
import XCTest
@testable import notchi

@MainActor
final class NotchPanelManagerTests: XCTestCase {
    private final class SessionCountBox {
        var value: Int

        init(_ value: Int) {
            self.value = value
        }
    }

    private final class MouseLocationBox {
        var value: CGPoint

        init(_ value: CGPoint) {
            self.value = value
        }
    }

    private final class HoverFeedbackBox {
        var count = 0
    }

    private final class PinFeedbackBox {
        var count = 0
    }

    private final class NotificationCountBox {
        var value = 0
    }

    private final class TextEditingBox {
        var value = false
    }

    private var defaultsSuiteNames: [String] = []

    override func tearDown() {
        for suiteName in defaultsSuiteNames {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        defaultsSuiteNames.removeAll()
        super.tearDown()
    }

    func testHideSpriteWhenIdleOffKeepsNormalCollapsedWithNoSessions() async {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppSettings.hideSpriteWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)

        XCTAssertEqual(manager.collapsedMode, .normalCollapsed)
        XCTAssertEqual(manager.activeCollapsedRect.width, manager.notchRect.width, accuracy: 0.5)
    }

    func testHideSpriteWhenIdleOnWithNoSessionsEntersCompactIdle() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.hideSpriteWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)

        XCTAssertEqual(manager.collapsedMode, .compactIdle)
        XCTAssertEqual(manager.compactNotchRect.width, manager.notchSize.width + 16, accuracy: 0.5)
        XCTAssertEqual(manager.activeCollapsedRect.width, manager.compactNotchRect.width, accuracy: 0.5)
    }

    func testFirstSessionStartExitsCompactIdle() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.hideSpriteWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)
        XCTAssertEqual(manager.collapsedMode, .compactIdle)

        sessionCount.value = 1
        manager.refreshIdleMode()

        XCTAssertEqual(manager.collapsedMode, .normalCollapsed)
        XCTAssertEqual(manager.activeCollapsedRect.width, manager.notchRect.width, accuracy: 0.5)
    }

    func testLastSessionEndReturnsToCompactIdleWhenCollapsed() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.hideSpriteWhenIdleKey)
        let sessionCount = SessionCountBox(1)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)
        XCTAssertEqual(manager.collapsedMode, .normalCollapsed)

        sessionCount.value = 0
        manager.refreshIdleMode()

        XCTAssertEqual(manager.collapsedMode, .compactIdle)
    }

    func testLastSessionEndWhileExpandedLeavesPanelOpenUntilCollapse() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.hideSpriteWhenIdleKey)
        let sessionCount = SessionCountBox(1)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)
        manager.expand()
        XCTAssertTrue(manager.isExpanded)

        sessionCount.value = 0
        manager.refreshIdleMode()

        XCTAssertTrue(manager.isExpanded)
        XCTAssertEqual(manager.collapsedMode, .compactIdle)

        manager.collapse()

        XCTAssertFalse(manager.isExpanded)
        XCTAssertEqual(manager.collapsedMode, .compactIdle)
    }

    func testCompactHoverExpansionStartsImmediatelyAndReturnsAfterDelay() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.hideSpriteWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(
            sessionCount: sessionCount,
            defaults: defaults,
            hoverExitDelay: .milliseconds(10)
        )

        configureGeometry(for: manager)
        XCTAssertEqual(manager.collapsedMode, .compactIdle)
        XCTAssertFalse(manager.isCollapsedHovered)

        manager.handleMouseLocationChanged(compactHoverPoint(for: manager))
        XCTAssertEqual(manager.collapsedMode, .compactIdle)
        XCTAssertTrue(manager.isCollapsedHovered)
        XCTAssertEqual(
            manager.activeCollapsedRect.width,
            manager.compactNotchRect.width + (NotchPanelManager.collapsedHoverHorizontalInset * 2),
            accuracy: 0.5
        )
        XCTAssertEqual(
            manager.activeCollapsedRect.height,
            manager.compactNotchRect.height + NotchPanelManager.collapsedHoverBottomInset,
            accuracy: 0.5
        )

        manager.handleMouseLocationChanged(outsideNotchPoint(for: manager))
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(manager.collapsedMode, .compactIdle)
        XCTAssertFalse(manager.isCollapsedHovered)
        XCTAssertEqual(manager.activeCollapsedRect.width, manager.compactNotchRect.width, accuracy: 0.5)
        XCTAssertEqual(manager.activeCollapsedRect.height, manager.compactNotchRect.height, accuracy: 0.5)
    }

    func testMouseMovementOutsideCompactIdleDoesNotEnterHoverExpansion() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.hideSpriteWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)
        XCTAssertEqual(manager.collapsedMode, .compactIdle)

        manager.handleMouseLocationChanged(CGPoint(x: 0, y: 0))

        XCTAssertEqual(manager.collapsedMode, .compactIdle)
        XCTAssertFalse(manager.isCollapsedHovered)
        XCTAssertEqual(manager.activeCollapsedRect.width, manager.compactNotchRect.width, accuracy: 0.5)
    }

    func testNormalCollapsedHoverExpansionStartsImmediatelyAndReturnsAfterDelay() async {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppSettings.hideSpriteWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(
            sessionCount: sessionCount,
            defaults: defaults,
            hoverExitDelay: .milliseconds(10)
        )

        configureGeometry(for: manager)
        XCTAssertEqual(manager.collapsedMode, .normalCollapsed)
        XCTAssertFalse(manager.isCollapsedHovered)

        manager.handleMouseLocationChanged(CGPoint(x: manager.notchRect.midX, y: manager.notchRect.midY))

        XCTAssertEqual(manager.collapsedMode, .normalCollapsed)
        XCTAssertTrue(manager.isCollapsedHovered)
        XCTAssertEqual(
            manager.activeCollapsedRect.width,
            manager.notchRect.width + (NotchPanelManager.collapsedHoverHorizontalInset * 2),
            accuracy: 0.5
        )
        XCTAssertEqual(
            manager.activeCollapsedRect.height,
            manager.notchRect.height + NotchPanelManager.collapsedHoverBottomInset,
            accuracy: 0.5
        )

        manager.handleMouseLocationChanged(outsideNotchPoint(for: manager))
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(manager.collapsedMode, .normalCollapsed)
        XCTAssertFalse(manager.isCollapsedHovered)
        XCTAssertEqual(manager.activeCollapsedRect.width, manager.notchRect.width, accuracy: 0.5)
        XCTAssertEqual(manager.activeCollapsedRect.height, manager.notchRect.height, accuracy: 0.5)
    }

    func testDisablingHideSpriteWhenIdleFromCollapsedHoverReturnsToNormalCollapsed() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.hideSpriteWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let mouseLocation = MouseLocationBox(.zero)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults, mouseLocation: mouseLocation)

        configureGeometry(for: manager)
        mouseLocation.value = compactHoverPoint(for: manager)
        manager.handleMouseLocationChanged(mouseLocation.value)
        XCTAssertEqual(manager.collapsedMode, .compactIdle)
        XCTAssertTrue(manager.isCollapsedHovered)

        defaults.set(false, forKey: AppSettings.hideSpriteWhenIdleKey)
        manager.refreshIdleMode()

        XCTAssertEqual(manager.collapsedMode, .normalCollapsed)
        XCTAssertTrue(manager.isCollapsedHovered)
        XCTAssertEqual(
            manager.activeCollapsedRect.width,
            manager.notchRect.width + (NotchPanelManager.collapsedHoverHorizontalInset * 2),
            accuracy: 0.5
        )
        XCTAssertEqual(
            manager.activeCollapsedRect.height,
            manager.notchRect.height + NotchPanelManager.collapsedHoverBottomInset,
            accuracy: 0.5
        )
    }

    func testDisablingHideSpriteWhenIdleClearsHoverIfMouseAlreadyLeftNotch() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.hideSpriteWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let mouseLocation = MouseLocationBox(.zero)
        let manager = makeManager(
            sessionCount: sessionCount,
            defaults: defaults,
            hoverExitDelay: .zero,
            mouseLocation: mouseLocation
        )

        configureGeometry(for: manager)
        mouseLocation.value = compactHoverPoint(for: manager)
        manager.handleMouseLocationChanged(mouseLocation.value)
        XCTAssertTrue(manager.isCollapsedHovered)

        mouseLocation.value = outsideNotchPoint(for: manager)
        defaults.set(false, forKey: AppSettings.hideSpriteWhenIdleKey)
        manager.refreshIdleMode()

        XCTAssertEqual(manager.collapsedMode, .normalCollapsed)
        XCTAssertFalse(manager.isCollapsedHovered)
        XCTAssertEqual(manager.activeCollapsedRect.width, manager.notchRect.width, accuracy: 0.5)
    }

    func testExpandFromCompactHoverKeepsPanelOpenAndReturnsToCompactIdleOnCollapse() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.hideSpriteWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)
        manager.handleMouseLocationChanged(compactHoverPoint(for: manager))
        XCTAssertEqual(manager.collapsedMode, .compactIdle)
        XCTAssertTrue(manager.isCollapsedHovered)

        manager.expand()

        XCTAssertTrue(manager.isExpanded)
        XCTAssertEqual(manager.collapsedMode, .compactIdle)
        XCTAssertFalse(manager.isCollapsedHovered)

        manager.collapse()

        XCTAssertFalse(manager.isExpanded)
        XCTAssertEqual(manager.collapsedMode, .compactIdle)
        XCTAssertFalse(manager.isCollapsedHovered)
    }

    func testCollapsedHoverEnterFeedbackFiresOnlyOnDistinctEntries() async {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppSettings.hideSpriteWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let feedback = HoverFeedbackBox()
        let manager = makeManager(
            sessionCount: sessionCount,
            defaults: defaults,
            hoverExitDelay: .zero,
            hoverFeedback: feedback
        )

        configureGeometry(for: manager)

        let insidePoint = CGPoint(x: manager.notchRect.midX, y: manager.notchRect.midY)
        let deeperInsidePoint = CGPoint(x: manager.notchRect.midX + 10, y: manager.notchRect.midY)

        manager.handleMouseLocationChanged(insidePoint)
        manager.handleMouseLocationChanged(deeperInsidePoint)

        XCTAssertEqual(feedback.count, 1)

        manager.handleMouseLocationChanged(outsideNotchPoint(for: manager))
        manager.handleMouseLocationChanged(insidePoint)

        XCTAssertEqual(feedback.count, 2)
    }

    func testPinToggleFeedbackFiresForEachToggle() async {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppSettings.hideSpriteWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let feedback = PinFeedbackBox()
        let manager = makeManager(
            sessionCount: sessionCount,
            defaults: defaults,
            pinFeedback: feedback
        )

        manager.togglePin()
        XCTAssertTrue(manager.isPinned)
        XCTAssertEqual(feedback.count, 1)

        manager.togglePin()
        XCTAssertFalse(manager.isPinned)
        XCTAssertEqual(feedback.count, 2)
    }

    func testHandleMouseDownUsesProvidedClickLocationToExpand() async {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppSettings.hideSpriteWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let mouseLocation = MouseLocationBox(CGPoint(x: 0, y: 0))
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults, mouseLocation: mouseLocation)

        configureGeometry(for: manager)

        manager.handleMouseDownForTesting(at: CGPoint(x: manager.notchRect.midX, y: manager.notchRect.midY))

        XCTAssertTrue(manager.isExpanded)
    }

    func testHandleMouseDownUsesProvidedClickLocationToCollapse() async {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppSettings.hideSpriteWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let mouseLocation = MouseLocationBox(CGPoint(x: 0, y: 0))
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults, mouseLocation: mouseLocation)

        configureGeometry(for: manager)
        manager.expand()

        manager.handleMouseDownForTesting(
            at: CGPoint(x: manager.panelRect.maxX + 20, y: manager.panelRect.maxY + 20)
        )

        XCTAssertFalse(manager.isExpanded)
    }

    func testCollapsedTrackingRectCoversHoverCompactAndHoveredRects() async {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppSettings.hideSpriteWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)

        let expectedTrackingRect = CGRect(x: 92.5, y: -5, width: 289, height: 43)
        XCTAssertEqual(manager.collapsedTrackingRect, expectedTrackingRect)
        XCTAssertTrue(manager.collapsedTrackingRect.contains(manager.compactNotchRect))

        manager.handleMouseLocationChanged(CGPoint(x: manager.notchRect.midX, y: manager.notchRect.midY))
        XCTAssertTrue(manager.isCollapsedHovered)
        XCTAssertTrue(manager.collapsedTrackingRect.contains(manager.activeCollapsedRect))
    }

    func testHandleCollapsedHoverExitedClearsHoverAfterDelay() async {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppSettings.hideSpriteWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(
            sessionCount: sessionCount,
            defaults: defaults,
            hoverExitDelay: .milliseconds(10)
        )

        configureGeometry(for: manager)
        manager.handleMouseLocationChanged(CGPoint(x: manager.notchRect.midX, y: manager.notchRect.midY))
        XCTAssertTrue(manager.isCollapsedHovered)

        manager.handleCollapsedHoverExited()
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertFalse(manager.isCollapsedHovered)
    }

    func testHideSpritePreferenceGateSkipsRedundantIdleRefresh() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.hideSpriteWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)
        XCTAssertEqual(manager.collapsedMode, .compactIdle)

        sessionCount.value = 1
        manager.refreshIdleModeIfHideSpritePreferenceChanged()
        XCTAssertEqual(manager.collapsedMode, .compactIdle)

        defaults.set(false, forKey: AppSettings.hideSpriteWhenIdleKey)
        manager.refreshIdleModeIfHideSpritePreferenceChanged()
        XCTAssertEqual(manager.collapsedMode, .normalCollapsed)
    }

    func testExpandOnHoverExpandsWhenCursorRestsOnNotch() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.expandOnHoverKey)
        let sessionCount = SessionCountBox(0)
        let mouseLocation = MouseLocationBox(.zero)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults, mouseLocation: mouseLocation)

        configureGeometry(for: manager)
        let insidePoint = CGPoint(x: manager.notchRect.midX, y: manager.notchRect.midY)
        mouseLocation.value = insidePoint

        manager.handleMouseLocationChanged(insidePoint)

        XCTAssertTrue(manager.isExpanded)
    }

    func testExpandOnHoverDoesNotExpandWhenSettingOff() async {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppSettings.expandOnHoverKey)
        let sessionCount = SessionCountBox(0)
        let mouseLocation = MouseLocationBox(.zero)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults, mouseLocation: mouseLocation)

        configureGeometry(for: manager)
        let insidePoint = CGPoint(x: manager.notchRect.midX, y: manager.notchRect.midY)
        mouseLocation.value = insidePoint

        manager.handleMouseLocationChanged(insidePoint)

        XCTAssertFalse(manager.isExpanded)
        XCTAssertTrue(manager.isCollapsedHovered)
    }

    func testExpandOnHoverCancelsWhenCursorLeavesBeforeDwellElapses() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.expandOnHoverKey)
        let sessionCount = SessionCountBox(0)
        let mouseLocation = MouseLocationBox(.zero)
        let manager = makeManager(
            sessionCount: sessionCount,
            defaults: defaults,
            hoverExitDelay: .zero,
            hoverExpandDelay: .milliseconds(20),
            mouseLocation: mouseLocation
        )

        configureGeometry(for: manager)
        let insidePoint = CGPoint(x: manager.notchRect.midX, y: manager.notchRect.midY)
        mouseLocation.value = insidePoint
        manager.handleMouseLocationChanged(insidePoint)
        XCTAssertFalse(manager.isExpanded)

        mouseLocation.value = outsideNotchPoint(for: manager)
        manager.handleMouseLocationChanged(outsideNotchPoint(for: manager))
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertFalse(manager.isExpanded)
    }

    func testExpandOnHoverExpandsAfterNonzeroDwellDelay() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.expandOnHoverKey)
        let sessionCount = SessionCountBox(0)
        let mouseLocation = MouseLocationBox(.zero)
        let manager = makeManager(
            sessionCount: sessionCount,
            defaults: defaults,
            hoverExpandDelay: .milliseconds(10),
            mouseLocation: mouseLocation
        )

        configureGeometry(for: manager)
        let insidePoint = CGPoint(x: manager.notchRect.midX, y: manager.notchRect.midY)
        mouseLocation.value = insidePoint
        manager.handleMouseLocationChanged(insidePoint)
        XCTAssertFalse(manager.isExpanded)

        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(manager.isExpanded)
    }

    func testExpandOnHoverAbortsWhenCursorAlreadyLeftAtFireTime() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.expandOnHoverKey)
        let sessionCount = SessionCountBox(0)
        let mouseLocation = MouseLocationBox(.zero)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults, mouseLocation: mouseLocation)

        configureGeometry(for: manager)
        mouseLocation.value = outsideNotchPoint(for: manager)

        manager.handleMouseLocationChanged(CGPoint(x: manager.notchRect.midX, y: manager.notchRect.midY))

        XCTAssertFalse(manager.isExpanded)
        XCTAssertTrue(manager.isCollapsedHovered)
    }

    func testExpandedPanelHoverExitCollapsesAfterGrace() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.expandOnHoverKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)
        manager.expand()
        manager.handleExpandedPanelHoverEntered()

        manager.handleExpandedPanelHoverExited()

        XCTAssertFalse(manager.isExpanded)
    }

    func testExpandedPanelHoverExitWithoutPriorEntryDoesNotCollapse() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.expandOnHoverKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)
        manager.expand()

        manager.handleExpandedPanelHoverExited()

        XCTAssertTrue(manager.isExpanded)
    }

    func testExpandedPanelHoverExitDoesNotCollapseWhenSettingOff() async {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppSettings.expandOnHoverKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)
        manager.expand()
        manager.handleExpandedPanelHoverEntered()

        manager.handleExpandedPanelHoverExited()

        XCTAssertTrue(manager.isExpanded)
    }

    func testPinBlocksHoverCollapse() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.expandOnHoverKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)
        manager.expand()
        manager.handleExpandedPanelHoverEntered()
        manager.togglePin()

        manager.handleExpandedPanelHoverExited()

        XCTAssertTrue(manager.isExpanded)
    }

    func testReEnterCancelsPendingHoverCollapse() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.expandOnHoverKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(
            sessionCount: sessionCount,
            defaults: defaults,
            hoverCollapseDelay: .milliseconds(20)
        )

        configureGeometry(for: manager)
        manager.expand()
        manager.handleExpandedPanelHoverEntered()

        manager.handleExpandedPanelHoverExited()
        manager.handleExpandedPanelHoverEntered()
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertTrue(manager.isExpanded)
    }

    func testTextEditingBlocksHoverCollapse() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.expandOnHoverKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(
            sessionCount: sessionCount,
            defaults: defaults,
            isTextEditingActive: { true }
        )

        configureGeometry(for: manager)
        manager.expand()
        manager.handleExpandedPanelHoverEntered()

        manager.handleExpandedPanelHoverExited()

        XCTAssertTrue(manager.isExpanded)
    }

    func testHoverCollapseResumesAfterTextEditingEnds() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.expandOnHoverKey)
        let sessionCount = SessionCountBox(0)
        let editing = TextEditingBox()
        editing.value = true
        let manager = makeManager(
            sessionCount: sessionCount,
            defaults: defaults,
            hoverCollapseDelay: .milliseconds(10),
            isTextEditingActive: { editing.value }
        )

        configureGeometry(for: manager)
        manager.expand()
        manager.handleExpandedPanelHoverEntered()
        manager.handleExpandedPanelHoverExited()

        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(manager.isExpanded)

        editing.value = false
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(manager.isExpanded)
    }

    func testExpandAndCollapsePostExpansionChangeNotification() async {
        let defaults = makeDefaults()
        let sessionCount = SessionCountBox(0)
        let center = NotificationCenter()
        let received = NotificationCountBox()
        let token = center.addObserver(
            forName: .notchiPanelExpansionDidChange,
            object: nil,
            queue: nil
        ) { _ in
            received.value += 1
        }
        defer { center.removeObserver(token) }
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults, notificationCenter: center)

        configureGeometry(for: manager)
        manager.expand()
        manager.collapse()

        XCTAssertEqual(received.value, 2)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "NotchPanelManagerTests-\(UUID().uuidString)"
        defaultsSuiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func configureGeometry(for manager: NotchPanelManager) {
        manager.setGeometryForTesting(
            notchSize: CGSize(width: 224, height: 38),
            notchRect: CGRect(x: 100, y: 0, width: 274, height: 38),
            panelRect: CGRect(x: 40, y: 0, width: 450, height: 450)
        )
    }

    private func compactHoverPoint(for manager: NotchPanelManager) -> CGPoint {
        CGPoint(x: manager.compactNotchRect.midX, y: manager.compactNotchRect.midY)
    }

    private func outsideNotchPoint(for manager: NotchPanelManager) -> CGPoint {
        CGPoint(x: manager.notchRect.maxX + 20, y: manager.notchRect.maxY + 20)
    }

    private func makeManager(
        sessionCount: SessionCountBox,
        defaults: UserDefaults,
        hoverExitDelay: Duration = .milliseconds(10),
        hoverExpandDelay: Duration = .zero,
        hoverCollapseDelay: Duration = .zero,
        notificationCenter: NotificationCenter = NotificationCenter(),
        mouseLocation: MouseLocationBox? = nil,
        hoverFeedback: HoverFeedbackBox? = nil,
        pinFeedback: PinFeedbackBox? = nil,
        isTextEditingActive: @escaping @MainActor () -> Bool = { false }
    ) -> NotchPanelManager {
        NotchPanelManager(
            notificationCenter: notificationCenter,
            userDefaults: defaults,
            hoverExitDelay: hoverExitDelay,
            hoverExpandDelay: hoverExpandDelay,
            hoverCollapseDelay: hoverCollapseDelay,
            activeSessionCountProvider: { sessionCount.value },
            mouseLocationProvider: { mouseLocation?.value ?? .zero },
            isTextEditingActive: isTextEditingActive,
            collapsedHoverEnterFeedback: {
                hoverFeedback?.count += 1
            },
            pinToggleFeedback: {
                pinFeedback?.count += 1
            },
            startEventMonitors: false,
            observeExternalState: false
        )
    }
}
