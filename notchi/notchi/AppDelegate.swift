import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchPanel: NotchPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        setupNotchWindow()
        observeScreenChanges()
        startHookServices()
    }

    private func startHookServices() {
        HookInstaller.installIfNeeded()
        SocketServer.shared.start { event in
            Task { @MainActor in
                NotchiStateMachine.shared.handleEvent(event)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func setupNotchWindow() {
        let screen = NSScreen.builtInOrMain
        let notchSize = screen.notchSize
        let screenFrame = screen.frame

        // Full-width window at top of screen
        let windowHeight: CGFloat = 500
        let frame = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - windowHeight,
            width: screenFrame.width,
            height: windowHeight
        )

        let panel = NotchPanel(frame: frame)

        // Configure panel manager with hit areas (in screen coordinates)
        let notchCenterX = screenFrame.origin.x + screenFrame.width / 2
        let sideWidth = max(0, notchSize.height - 12) + 24
        let notchTotalWidth = notchSize.width + sideWidth

        // Notch clickable area (screen coordinates)
        let notchRect = CGRect(
            x: notchCenterX - notchTotalWidth / 2,
            y: screenFrame.maxY - notchSize.height,
            width: notchTotalWidth,
            height: notchSize.height
        )

        // Expanded panel area (screen coordinates)
        let panelWidth: CGFloat = 420
        let panelHeight: CGFloat = 450
        let panelRect = CGRect(
            x: notchCenterX - panelWidth / 2,
            y: screenFrame.maxY - panelHeight,
            width: panelWidth,
            height: panelHeight
        )

        NotchPanelManager.shared.configure(
            notchRect: notchRect,
            panelRect: panelRect,
            screenHeight: screenFrame.height
        )
        NotchPanelManager.shared.panel = panel

        let contentView = NotchContentView(notchSize: notchSize)
        let hostingView = NSHostingView(rootView: contentView)
        panel.contentView = hostingView
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
        let screenFrame = screen.frame
        let windowHeight: CGFloat = 500
        let frame = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - windowHeight,
            width: screenFrame.width,
            height: windowHeight
        )
        panel.setFrame(frame, display: true)
    }
}
