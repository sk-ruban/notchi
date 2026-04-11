import AppKit
import os.log
import Sparkle
import SwiftUI

private let logger = Logger(subsystem: "com.ruban.notchi", category: "AppDelegate")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var notchPanel: NotchPanel?
    private let windowHeight: CGFloat = 500

    private var updaterStarted = false
    private var temporarilyRegularForUpdateSession = false
    private lazy var standardUserDriver = SPUStandardUserDriver(
        hostBundle: .main,
        delegate: self
    )
    private lazy var updateUserDriver = NotchiUpdateUserDriver(
        standardUserDriver: standardUserDriver,
        shouldHandleUpdaterErrorsInline: { UpdateManager.shared.shouldHandleUpdaterErrorInline },
        didFinishCustomSession: { [weak self] in
            UpdateManager.shared.finishUpdateSession()
            self?.restoreAccessoryModeIfNeeded()
        }
    )
    private lazy var updater = SPUUpdater(
        hostBundle: .main,
        applicationBundle: .main,
        userDriver: updateUserDriver,
        delegate: self
    )
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else { return }

        NSApplication.shared.setActivationPolicy(.accessory)
        let claudeConfig = ClaudeConfigDirectoryResolver.resolve()
        ConversationParser.configureProjectsRootPath(using: claudeConfig)
        setupNotchWindow()
        observeScreenChanges()
        observeWakeNotifications()
        startHookServices()
        startUsageService()
        startUpdater()
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

    func applicationWillTerminate(_ notification: Notification) {
        SocketServer.shared.stop()
        ClaudeUsageService.shared.stopPolling()
    }

    @MainActor private func setupNotchWindow() {
        ScreenSelector.shared.refreshScreens()
        guard let screen = ScreenSelector.shared.selectedScreen else { return }
        NotchPanelManager.shared.updateGeometry(for: screen)

        let panel = NotchPanel(frame: windowFrame(for: screen))

        let contentView = NotchContentView()
        let hostingView = NSHostingView(rootView: contentView)

        let hitTestView = NotchHitTestView()
        hitTestView.panelManager = NotchPanelManager.shared
        hitTestView.addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: hitTestView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: hitTestView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: hitTestView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: hitTestView.trailingAnchor),
        ])

        panel.contentView = hitTestView
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

    private func observeWakeNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func repositionWindow() {
        MainActor.assumeIsolated {
            guard let panel = notchPanel else { return }
            ScreenSelector.shared.refreshScreens()
            guard let screen = ScreenSelector.shared.selectedScreen else { return }

            NotchPanelManager.shared.updateGeometry(for: screen)
            panel.setFrame(windowFrame(for: screen), display: true)
        }
    }

    @objc private func handleSystemWake() {
        MainActor.assumeIsolated {
            logger.info("System woke, restarting Claude usage polling")
            ClaudeUsageService.shared.startPolling(afterSystemWake: true)
        }
    }

    private func windowFrame(for screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame
        return NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - windowHeight,
            width: screenFrame.width,
            height: windowHeight
        )
    }

    @MainActor private func startUsageService() {
        ClaudeUsageService.shared.startPolling()
    }

    private func startUpdater() {
        guard !updaterStarted else { return }

        UpdateManager.shared.setUpdater(updater)
        do {
            try updater.start()
        } catch {
            logger.error("Failed to start Sparkle updater: \(error.localizedDescription, privacy: .public)")
            return
        }
        updaterStarted = true
    }

    private func presentUpdateUIIfNeeded() {
        guard NSApp.activationPolicy() != .regular else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        temporarilyRegularForUpdateSession = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func restoreAccessoryModeIfNeeded() {
        guard temporarilyRegularForUpdateSession else { return }
        temporarilyRegularForUpdateSession = false
        NSApp.setActivationPolicy(.accessory)
    }

}

// MARK: - SPUUpdaterDelegate

extension AppDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        UpdateManager.shared.updateFound(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        UpdateManager.shared.noUpdateFound()
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMakeChoice choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        UpdateManager.shared.userMadeChoice(
            choice,
            stage: state.stage,
            version: updateItem.displayVersionString
        )
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        UpdateManager.shared.downloadStarted()
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        UpdateManager.shared.readyToInstall(version: item.displayVersionString)
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        UpdateManager.shared.readyToInstall(version: item.displayVersionString)
        return false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError

        if UpdateManager.shouldIgnoreAbortError(nsError) {
            return
        }

        logSparkleAbort(nsError)
        UpdateManager.shared.updateError()
    }

    private func logSparkleAbort(_ error: NSError) {
        let failureReason = error.localizedFailureReason ?? "nil"
        let recoverySuggestion = error.localizedRecoverySuggestion ?? "nil"
        let noUpdateReason = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.stringValue ?? "nil"
        let latestVersion = (error.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem)?.displayVersionString ?? "nil"

        logger.error(
            """
            Sparkle updater aborted. domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public) description=\(error.localizedDescription, privacy: .public) failureReason=\(failureReason, privacy: .public) recoverySuggestion=\(recoverySuggestion, privacy: .public) noUpdateReason=\(noUpdateReason, privacy: .public) latestAppcastVersion=\(latestVersion, privacy: .public)
            """
        )
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension AppDelegate {
    func standardUserDriverWillShowModalAlert() {
        presentUpdateUIIfNeeded()
    }

    func standardUserDriverWillFinishUpdateSession() {
        UpdateManager.shared.finishUpdateSession()
        restoreAccessoryModeIfNeeded()
    }
}
