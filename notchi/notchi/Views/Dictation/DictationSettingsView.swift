import AppKit
import AVFoundation
import SwiftUI

enum DictationPermission {
    static func accessibilityGranted() -> Bool { AXIsProcessTrusted() }

    /// Triggers the system Accessibility prompt, which registers this binary in
    /// the Accessibility list (opening System Settings alone never adds it).
    static func requestAccessibility() {
        // Raw value of kAXTrustedCheckOptionPrompt — avoids CFString import churn.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct DictationSettingsView: View {
    @AppStorage(AppSettings.dictationEnabledRawKey) private var enabled = false
    @State private var pushToTalk = AppSettings.dictationPushToTalkShortcut
    @State private var modelId = AppSettings.dictationModelId
    private let modelStore = WhisperModelStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            Button(action: { enabled.toggle() }) {
                SettingsRowView(icon: "mic", title: "Voice Dictation") { ToggleSwitch(isOn: enabled) }
            }
            .buttonStyle(.plain)

            if enabled {
                SettingsRowView(icon: "keyboard", title: "Push-to-Talk") {
                    ShortcutRecorderView(
                        shortcut: pushToTalk,
                        onReset: { update(.defaultDictationPushToTalk) },
                        onShortcutChange: { update($0) }
                    )
                }
                modelRow

                Button(action: { DictationPermission.requestAccessibility() }) {
                    SettingsRowView(icon: "hand.raised", title: "Accessibility") {
                        Text(DictationPermission.accessibilityGranted() ? String(localized: "Granted") : String(localized: "Enable"))
                            .font(.system(size: 11))
                            .foregroundColor(DictationPermission.accessibilityGranted() ? TerminalColors.green : TerminalColors.amber)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        let model = WhisperCatalog.model(id: modelId) ?? WhisperCatalog.models[1]
        // Reading downloadProgress (observable) drives the row to re-render as the
        // download starts and finishes, at which point isDownloaded flips to true.
        let progress = modelStore.downloadProgress[model.id]
        SettingsRowView(icon: "cpu", title: "Model") {
            HStack(spacing: 6) {
                if let progress, progress < 1 {
                    ProgressView().controlSize(.mini)
                } else if !modelStore.isDownloaded(model) {
                    Text(String(localized: "\(model.approxMB) MB"))
                        .font(.system(size: 10))
                        .foregroundColor(TerminalColors.amber)
                }
                Menu {
                    ForEach(WhisperCatalog.models) { candidate in
                        Button {
                            select(candidate)
                        } label: {
                            Text((candidate.id == model.id ? "✓ " : "") + menuLabel(candidate))
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.displayName)
                            .font(.system(size: 11))
                            .foregroundColor(TerminalColors.secondaryText)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(TerminalColors.dimmedText)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func menuLabel(_ model: WhisperModel) -> String {
        modelStore.isDownloaded(model) ? model.displayName : "\(model.displayName) • \(model.approxMB) MB"
    }

    private func update(_ shortcut: GlobalShortcut) {
        pushToTalk = shortcut
        AppSettings.dictationPushToTalkShortcut = shortcut
    }

    // Switch the active dictation model; download it first if it isn't cached yet.
    private func select(_ model: WhisperModel) {
        modelId = model.id
        AppSettings.dictationModelId = model.id
        if !modelStore.isDownloaded(model) {
            download(model)
        }
    }

    private func download(_ model: WhisperModel) {
        Task { try? await modelStore.download(model) }
    }
}
