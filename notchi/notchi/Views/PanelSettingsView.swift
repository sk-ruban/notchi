import ServiceManagement
import SwiftUI

struct PanelSettingsView: View {
    private let usageService = ClaudeUsageService.shared
    private let codexAuthService = CodexAuthService.shared

    @AppStorage(AppSettings.hideSpriteWhenIdleKey) private var hideSpriteWhenIdle = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hooksInstalled = HookInstaller.isInstalled()
    @State private var hooksError = false
    @State private var emotionAnalysisEnabled = AppSettings.isEmotionAnalysisEnabled
    @State private var apiKeyInput = AppSettings.anthropicApiKey ?? ""
    @State private var customSpriteOverrideCount = 0
    @State private var customSpriteOverrideCountTask: Task<Void, Never>?
    @ObservedObject private var updateManager = UpdateManager.shared

    private var usageConnected: Bool { usageService.isConnected }
    private var codexConnected: Bool { codexAuthService.isConnected }
    private var codexStatusText: String { codexAuthService.statusText }
    private var hasApiKey: Bool { !apiKeyInput.isEmpty }
    private var emotionAnalysisStatusText: String {
        guard emotionAnalysisEnabled else { return "Off" }
        if codexConnected && hasApiKey { return "Codex + Claude" }
        if codexConnected { return "Codex" }
        if hasApiKey { return "Claude" }
        return "Auto"
    }
    private var emotionAnalysisStatusColor: Color {
        guard emotionAnalysisEnabled else { return TerminalColors.dimmedText }
        if codexConnected || hasApiKey { return TerminalColors.green }
        return TerminalColors.amber
    }
    private var customSpriteStatusText: String {
        customSpriteOverrideCount > 0 ? "\(customSpriteOverrideCount) Loaded" : "Defaults"
    }
    private var customSpriteStatusColor: Color {
        customSpriteOverrideCount > 0 ? TerminalColors.green : TerminalColors.dimmedText
    }

    private var hookStatusText: String {
        if hooksError { return "Error" }
        if hooksInstalled { return "Installed" }
        return "Not Installed"
    }

    private var hookStatusColor: Color {
        hooksInstalled && !hooksError ? TerminalColors.green : TerminalColors.red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                    systemSection
                    Divider().background(Color.white.opacity(0.08))
                    aiSection
                    Divider().background(Color.white.opacity(0.08))
                    aboutSection
                }
                .padding(.top, SettingsLayout.topPadding)
            }
            .scrollIndicators(.hidden)

            Spacer()

            quitSection
        }
        .padding(.horizontal, SettingsLayout.panelHorizontalPadding)
        .padding(.top, SettingsLayout.topPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            emotionAnalysisEnabled = AppSettings.isEmotionAnalysisEnabled
            refreshCustomSpriteOverrideCount()
        }
        .onDisappear {
            customSpriteOverrideCountTask?.cancel()
        }
    }

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            ScreenPickerRow(screenSelector: ScreenSelector.shared)

            SoundPickerView()

            Button(action: openCustomSpriteFolder) {
                SettingsRowView(icon: "photo.stack", title: "Custom Sprites") {
                    statusBadge(customSpriteStatusText, color: customSpriteStatusColor)
                }
            }
            .buttonStyle(.plain)

            Button(action: toggleLaunchAtLogin) {
                SettingsRowView(icon: "power", title: "Launch at Login") {
                    ToggleSwitch(isOn: launchAtLogin)
                }
            }
            .buttonStyle(.plain)

            Button(action: toggleHideSpriteWhenIdle) {
                SettingsRowView(icon: "pip.exit", title: "Hide Sprite When Idle") {
                    ToggleSwitch(isOn: hideSpriteWhenIdle)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            Button(action: installHooksIfNeeded) {
                SettingsRowView(icon: "terminal", title: "Claude Hooks") {
                    statusBadge(hookStatusText, color: hookStatusColor)
                }
            }
            .buttonStyle(.plain)

            Button(action: connectUsage) {
                SettingsRowView(icon: "gauge.with.dots.needle.33percent", title: "Claude Usage") {
                    statusBadge(
                        usageConnected ? "Connected" : "Not Connected",
                        color: usageConnected ? TerminalColors.green : TerminalColors.red
                    )
                }
            }
            .buttonStyle(.plain)

            Button(action: connectCodex) {
                SettingsRowView(icon: "sparkles.rectangle.stack", title: "Codex Auth") {
                    statusBadge(
                        codexStatusText,
                        color: codexConnected ? TerminalColors.green : TerminalColors.red
                    )
                }
            }
            .buttonStyle(.plain)

            apiKeyRow
        }
    }

    private var apiKeyRow: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.apiKeySpacing) {
            Button(action: toggleEmotionAnalysis) {
                SettingsRowView(icon: "brain", title: "Emotion Analysis") {
                    HStack(spacing: 8) {
                        statusBadge(
                            emotionAnalysisStatusText,
                            color: emotionAnalysisStatusColor
                        )
                        ToggleSwitch(isOn: emotionAnalysisEnabled)
                    }
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                SecureField("", text: $apiKeyInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(TerminalColors.primaryText)
                    .padding(.horizontal, SettingsLayout.fieldHorizontalPadding)
                    .padding(.vertical, SettingsLayout.fieldVerticalPadding)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(6)
                    .onSubmit { saveApiKey() }
                    .overlay(alignment: .leading) {
                        if apiKeyInput.isEmpty {
                            Text("Anthropic API Key (Claude only)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(TerminalColors.dimmedText)
                                .padding(.leading, SettingsLayout.fieldHorizontalPadding)
                                .allowsHitTesting(false)
                        }
                    }

                Button(action: saveApiKey) {
                    Image(systemName: hasApiKey ? "checkmark.circle.fill" : "arrow.right.circle")
                        .font(.system(size: 14))
                        .foregroundColor(hasApiKey ? TerminalColors.green : TerminalColors.dimmedText)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, SettingsLayout.fieldLeadingInset)

            Text("Codex sessions use local Codex auth. Claude sessions use this key or `~/.claude/settings.json`.")
                .font(.system(size: 10))
                .foregroundColor(TerminalColors.dimmedText)
                .padding(.leading, SettingsLayout.fieldLeadingInset)
        }
    }

    private func saveApiKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.anthropicApiKey = trimmed.isEmpty ? nil : trimmed
    }

    private func toggleEmotionAnalysis() {
        emotionAnalysisEnabled.toggle()
        AppSettings.isEmotionAnalysisEnabled = emotionAnalysisEnabled
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            Button(action: handleUpdatesAction) {
                SettingsRowView(icon: "arrow.triangle.2.circlepath", title: "Check for Updates") {
                    updateStatusView
                }
            }
            .buttonStyle(.plain)

            Button(action: openGitHubRepo) {
                SettingsRowView(icon: "star", title: "Star on GitHub") {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10))
                        .foregroundColor(TerminalColors.dimmedText)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func openGitHubRepo() {
        NSWorkspace.shared.open(URL(string: "https://github.com/sk-ruban/notchi")!)
    }

    private func openLatestReleasePage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/sk-ruban/notchi/releases/latest")!)
    }

    private func openCustomSpriteFolder() {
        SpriteOverrideStore.openDirectoryInFinder()
        refreshCustomSpriteOverrideCount()
    }

    private func refreshCustomSpriteOverrideCount() {
        customSpriteOverrideCountTask?.cancel()
        customSpriteOverrideCountTask = Task { @MainActor in
            let overrideCount = await SpriteOverrideStore.installedOverrideCountAsync()
            guard !Task.isCancelled else { return }
            customSpriteOverrideCount = overrideCount
        }
    }

    private var quitSection: some View {
        Button(action: {
            NSApplication.shared.terminate(nil)
        }) {
            HStack {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 13))
                Text("Quit Notchi")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(TerminalColors.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, SettingsLayout.quitButtonVerticalPadding)
            .padding(.horizontal, SettingsLayout.quitButtonHorizontalPadding)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(TerminalColors.red.opacity(0.1))
                    .padding(.horizontal, -SettingsLayout.quitButtonHorizontalPadding)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            print("Failed to toggle launch at login: \(error)")
        }
    }

    private func connectUsage() {
        usageService.connectAndStartPolling()
    }

    private func connectCodex() {
        codexAuthService.handleAction()
    }

    private func toggleHideSpriteWhenIdle() {
        hideSpriteWhenIdle.toggle()
    }

    private func handleUpdatesAction() {
        if case .upToDate = updateManager.state {
            openLatestReleasePage()
        } else {
            updateManager.checkForUpdates()
        }
    }

    private func installHooksIfNeeded() {
        guard !hooksInstalled else { return }
        hooksError = false
        let success = HookInstaller.installIfNeeded()
        if success {
            hooksInstalled = HookInstaller.isInstalled()
        } else {
            hooksError = true
        }
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
            .frame(maxWidth: 160, alignment: .trailing)
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateManager.state {
        case .checking:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Checking...")
                    .font(.system(size: 10))
                    .foregroundColor(TerminalColors.dimmedText)
            }
        case .upToDate:
            statusBadge("Up to date", color: TerminalColors.green)
        case .updateAvailable:
            statusBadge("Update available", color: TerminalColors.amber)
        case .downloading:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Downloading...")
                    .font(.system(size: 10))
                    .foregroundColor(TerminalColors.dimmedText)
            }
        case .readyToInstall:
            statusBadge("Ready to install", color: TerminalColors.green)
        case .error(let failure):
            statusBadge(failure.label, color: TerminalColors.red)
        case .idle:
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .font(.system(size: 10))
                .foregroundColor(TerminalColors.dimmedText)
        }
    }
}

struct SettingsRowView<Trailing: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(TerminalColors.secondaryText)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 12))
                .foregroundColor(TerminalColors.primaryText)

            Spacer()

            trailing()
        }
        .padding(.vertical, SettingsLayout.rowVerticalPadding)
        .contentShape(Rectangle())
    }
}

struct ToggleSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? TerminalColors.green : Color.white.opacity(0.15))
                .frame(width: 32, height: 18)

            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .padding(2)
        }
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }
}

#Preview {
    PanelSettingsView()
        .frame(width: 402, height: 400)
        .background(Color.black)
}
