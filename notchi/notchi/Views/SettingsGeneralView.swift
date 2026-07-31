import ServiceManagement
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "SettingsGeneralView")

struct SettingsGeneralView: View {
    @State private var panelToggleShortcut = AppSettings.panelToggleShortcut
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(AppSettings.expandOnHoverKey) private var expandOnHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
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

            Divider().background(Color.white.opacity(0.08))

            Button(action: { expandOnHover.toggle() }) {
                SettingsRowView(icon: "cursorarrow.motionlines", title: "Expand on Hover") {
                    ToggleSwitch(isOn: expandOnHover)
                }
            }
            .buttonStyle(.plain)

            Button(action: toggleLaunchAtLogin) {
                SettingsRowView(icon: "power", title: "Launch at Login") {
                    ToggleSwitch(isOn: launchAtLogin)
                }
            }
            .buttonStyle(.plain)

            DictationSettingsView()
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
