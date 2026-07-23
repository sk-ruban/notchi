import ServiceManagement
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "SettingsGeneralView")

struct SettingsGeneralView: View {
    @State private var panelToggleShortcut = AppSettings.panelToggleShortcut
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            ScreenPickerRow(screenSelector: ScreenSelector.shared)

            SoundPickerView()

            SettingsRowView(icon: "keyboard", title: "Toggle Panel") {
                ShortcutRecorderView(
                    shortcut: panelToggleShortcut,
                    onBeginRecording: beginPanelShortcutRecording,
                    onCancelRecording: endPanelShortcutRecording,
                    onReset: resetPanelToggleShortcut,
                    onShortcutChange: updatePanelToggleShortcut
                )
            }

            Button(action: toggleLaunchAtLogin) {
                SettingsRowView(icon: "power", title: "Launch at Login") {
                    ToggleSwitch(isOn: launchAtLogin)
                }
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            panelToggleShortcut = AppSettings.panelToggleShortcut
        }
    }

    private func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            logger.error("Failed to toggle launch at login: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func beginPanelShortcutRecording() {
        GlobalShortcutService.shared.suspendShortcut()
    }

    private func endPanelShortcutRecording() {
        GlobalShortcutService.shared.reloadShortcut()
    }

    private func updatePanelToggleShortcut(_ shortcut: GlobalShortcut) {
        panelToggleShortcut = shortcut
        AppSettings.panelToggleShortcut = shortcut
        GlobalShortcutService.shared.reloadShortcut()
    }

    private func resetPanelToggleShortcut() {
        updatePanelToggleShortcut(.defaultTogglePanel)
    }
}
