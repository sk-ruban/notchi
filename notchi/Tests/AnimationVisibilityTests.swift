import AppKit
import XCTest
@testable import notchi

@MainActor
final class AnimationVisibilityTests: XCTestCase {
    private let workspaceNotificationCenter = NotificationCenter()
    private let notificationCenter = NotificationCenter()
    // Never ordered on screen, so AppKit reports it as not visible.
    private let offscreenPanel = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
        styleMask: .borderless,
        backing: .buffered,
        defer: true
    )

    private func startedVisibility() -> AnimationVisibility {
        let visibility = AnimationVisibility()
        visibility.start(
            observing: offscreenPanel,
            workspaceNotificationCenter: workspaceNotificationCenter,
            notificationCenter: notificationCenter
        )
        return visibility
    }

    func testDisplayIsAwakeBeforeAnyScreenSleepNotification() {
        let visibility = startedVisibility()

        XCTAssertFalse(visibility.isDisplayAsleep)
    }

    func testScreensDidSleepMarksDisplayAsleep() {
        let visibility = startedVisibility()

        workspaceNotificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)

        XCTAssertTrue(visibility.isDisplayAsleep)
    }

    func testScreensDidWakeMarksDisplayAwake() {
        let visibility = startedVisibility()
        workspaceNotificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)

        workspaceNotificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        XCTAssertFalse(visibility.isDisplayAsleep)
    }

    func testOffscreenPanelPausesAnimations() {
        let visibility = startedVisibility()

        XCTAssertTrue(visibility.isPaused)
    }

    // AppKit decides real occlusion, so these drive the panel's visibility through the injected check.
    private var isPanelVisible = false

    private func startedVisibilityWithControlledPanel() -> AnimationVisibility {
        let visibility = AnimationVisibility()
        visibility.start(
            observing: offscreenPanel,
            workspaceNotificationCenter: workspaceNotificationCenter,
            notificationCenter: notificationCenter,
            isWindowVisible: { [unowned self] _ in self.isPanelVisible }
        )
        return visibility
    }

    private func setPanelVisible(_ visible: Bool) {
        isPanelVisible = visible
        notificationCenter.post(name: NSWindow.didChangeOcclusionStateNotification, object: offscreenPanel)
    }

    func testPanelBecomingVisibleResumesAnimations() {
        let visibility = startedVisibilityWithControlledPanel()
        XCTAssertTrue(visibility.isPaused, "precondition: a hidden panel pauses animations")

        setPanelVisible(true)

        XCTAssertFalse(visibility.isPaused)
    }

    func testPanelBecomingHiddenPausesAnimations() {
        isPanelVisible = true
        let visibility = startedVisibilityWithControlledPanel()
        XCTAssertFalse(visibility.isPaused, "precondition: a visible panel animates")

        setPanelVisible(false)

        XCTAssertTrue(visibility.isPaused)
    }

    func testWakingWithThePanelVisibleResumesAnimations() {
        isPanelVisible = true
        let visibility = startedVisibilityWithControlledPanel()
        workspaceNotificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertTrue(visibility.isPaused, "precondition: a sleeping display pauses animations")

        workspaceNotificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        XCTAssertFalse(visibility.isPaused)
    }

    func testWakingWhileThePanelIsHiddenKeepsAnimationsPaused() {
        let visibility = startedVisibilityWithControlledPanel()
        workspaceNotificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)

        workspaceNotificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        XCTAssertTrue(visibility.isPaused)
    }
}
