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
        let frame = screen.notchWindowFrame
        let notchSize = screen.notchSize

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
        let frame = screen.notchWindowFrame
        panel.setFrame(frame, display: true)
    }
}
