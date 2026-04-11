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
        mouseLocation: MouseLocationBox? = nil,
        hoverFeedback: HoverFeedbackBox? = nil,
        pinFeedback: PinFeedbackBox? = nil
    ) -> NotchPanelManager {
        NotchPanelManager(
            notificationCenter: NotificationCenter(),
            userDefaults: defaults,
            hoverExitDelay: hoverExitDelay,
            activeSessionCountProvider: { sessionCount.value },
            mouseLocationProvider: { mouseLocation?.value ?? .zero },
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
