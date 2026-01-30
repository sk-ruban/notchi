import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchPanel: NotchPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        setupNotchWindow()
        observeScreenChanges()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func setupNotchWindow() {
        let screen = NSScreen.builtInOrMain
        let notchSize = screen.notchSize
        let frame = notchPanelFrame(baseFrame: screen.notchWindowFrame, notchSize: notchSize)

        let panel = NotchPanel(frame: frame)
        let contentView = NotchContentView(notchSize: notchSize)
        panel.contentView = NSHostingView(rootView: contentView)
        panel.orderFrontRegardless()

        self.notchPanel = panel
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(repositionWindow),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func repositionWindow() {
        guard let panel = notchPanel else { return }
        let screen = NSScreen.builtInOrMain
        let frame = notchPanelFrame(baseFrame: screen.notchWindowFrame, notchSize: screen.notchSize)
        panel.setFrame(frame, display: true)
    }

    private func notchPanelFrame(baseFrame: CGRect, notchSize: CGSize) -> CGRect {
        let sideWidth = max(0, notchSize.height - 12) + 10
        let expandBuffer: CGFloat = 50
        return CGRect(
            x: baseFrame.origin.x,
            y: baseFrame.origin.y - expandBuffer,
            width: baseFrame.width + sideWidth,
            height: notchSize.height + expandBuffer
        )
    }
}
