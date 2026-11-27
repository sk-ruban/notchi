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

            ScreenPickerRow(screenSelector: ScreenSelector.shared)

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

            SleepRetirementSettingsView()
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

private struct SleepRetirementSettingsView: View {
    @AppStorage(AppSettings.sleepRetirementKey) private var retirementRaw = SleepRetirement.fiveHours.rawValue

    private static let chipSpacing: CGFloat = 6
    private static let chipCornerRadius: CGFloat = 6
    private static let chipMinimumTextScale: CGFloat = 0.7

    private var retirement: SleepRetirement { AppSettings.sleepRetirement(fromRaw: retirementRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.pickerInset) {
            SettingsRowView(icon: "moon.zzz", title: "Retire Sleeping Sessions") {
                Text(retirement.displayName)
                    .panelFont(size: 11)
                    .foregroundColor(TerminalColors.secondaryText)
                    .lineLimit(1)
            }

            HStack(spacing: Self.chipSpacing) {
                ForEach(SleepRetirement.allCases) { option in
                    chip(option)
                }
            }
        }
    }

    private func chip(_ option: SleepRetirement) -> some View {
        let isSelected = retirement == option
        return Button(action: { AppSettings.sleepRetirement = option }) {
            Text(option.shortName)
                .panelFont(size: 11, weight: .medium)
                .foregroundColor(isSelected ? TerminalColors.primaryText : TerminalColors.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(Self.chipMinimumTextScale)
                .padding(.vertical, SettingsLayout.pickerOptionVerticalPadding)
                .frame(maxWidth: .infinity)
                .background(TerminalColors.subtleBackground)
                .clipShape(RoundedRectangle(cornerRadius: Self.chipCornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.chipCornerRadius)
                        .stroke(isSelected ? TerminalColors.green : .clear, lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(option.displayName)
        .accessibilityLabel(option.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
