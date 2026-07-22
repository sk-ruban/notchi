import ServiceManagement
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "PanelSettingsView")

private struct StatusBadge {
    let text: String
    let color: Color
}

enum PanelUsageBadgeState: Equatable {
    case connected
    case setup

    var text: String {
        switch self {
        case .connected:
            String(localized: "Connected")
        case .setup:
            String(localized: "Set Up")
        }
    }

    var color: Color {
        switch self {
        case .connected:
            TerminalColors.green
        case .setup:
            TerminalColors.amber
        }
    }

    static func resolve(
        isClaudeUsageConnected: Bool,
        hasActiveClaudeSession: Bool,
        hasActiveCodexSession: Bool,
        codexHooksInstalled: Bool
    ) -> PanelUsageBadgeState {
        if isClaudeUsageConnected {
            return .connected
        }

        if hasActiveClaudeSession {
            return .setup
        }

        if hasActiveCodexSession, codexHooksInstalled {
            return .connected
        }

        return .setup
    }
}

struct PanelSettingsView: View {
    @Binding private var showingEmotionAnalysisSettings: Bool
    private let sessionStore: SessionStore
    @AppStorage(AppSettings.hideSpriteWhenIdleKey) private var hideSpriteWhenIdle = false
    @AppStorage(AppSettings.hideGrassIslandKey) private var hideGrassIsland = false
    @AppStorage(AppSettings.expandOnHoverKey) private var expandOnHover = false
    @State private var panelToggleShortcut = AppSettings.panelToggleShortcut
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var claudeHooksStatus = IntegrationCoordinator.shared.installStatus(for: .claude)
    @State private var codexHooksStatus = IntegrationCoordinator.shared.installStatus(for: .codex)
    @State private var claudeHooksEnabled = AppSettings.areHooksEnabled(for: .claude)
    @State private var codexHooksEnabled = AppSettings.areHooksEnabled(for: .codex)
    @State private var areHooksExpanded = false
    @ObservedObject private var updateManager = UpdateManager.shared
    private var usageConnected: Bool { ClaudeUsageService.shared.isConnected }

    init(
        showingEmotionAnalysisSettings: Binding<Bool> = .constant(false),
        sessionStore: SessionStore? = nil
    ) {
        _showingEmotionAnalysisSettings = showingEmotionAnalysisSettings
        self.sessionStore = sessionStore ?? .shared
    }

    var body: some View {
        ZStack {
            if !showingEmotionAnalysisSettings {
                mainSettings
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }

            if showingEmotionAnalysisSettings {
                EmotionAnalysisSettingsView()
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingEmotionAnalysisSettings)
        .padding(.horizontal, SettingsLayout.panelHorizontalPadding)
        .padding(.top, SettingsLayout.topPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            refreshHookStatuses()
            panelToggleShortcut = AppSettings.panelToggleShortcut
        }
    }

    private var mainSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                    systemSection
                    Divider().background(Color.white.opacity(0.08))
                    integrationsSection
                    Divider().background(Color.white.opacity(0.08))
                    aboutSection
                }
            }
            .scrollIndicators(.hidden)

            Spacer()

            quitSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var systemSection: some View {
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

            Button(action: toggleHideSpriteWhenIdle) {
                SettingsRowView(icon: "pip.exit", title: "Hide Sprite When Idle") {
                    ToggleSwitch(isOn: hideSpriteWhenIdle)
                }
            }
            .buttonStyle(.plain)

            Button(action: toggleHideGrassIsland) {
                SettingsRowView(icon: "leaf", title: "Hide Grass Island") {
                    ToggleSwitch(isOn: hideGrassIsland)
                }
            }
            .buttonStyle(.plain)

            Button(action: toggleExpandOnHover) {
                SettingsRowView(icon: "cursorarrow.motionlines", title: "Expand on Hover") {
                    ToggleSwitch(isOn: expandOnHover)
                }
            }
            .buttonStyle(.plain)

            NotchLayoutSettingsView()
        }
    }

    private var integrationsSection: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            Button(action: toggleHooksExpanded) {
                SettingsRowView(icon: "terminal", title: "Agent Hooks") {
                    HStack(spacing: 6) {
                        if !areHooksExpanded {
                            let status = hooksSummaryStatus()
                            statusBadge(status)
                        }
                        Image(systemName: areHooksExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(TerminalColors.dimmedText)
                    }
                }
            }
            .buttonStyle(.plain)

            if areHooksExpanded {
                hooksProviderList
            }

            Button(action: connectUsage) {
                SettingsRowView(icon: "gauge.with.dots.needle.33percent", title: "Usage") {
                    let status = usageStatus()
                    statusBadge(status)
                }
            }
            .buttonStyle(.plain)

            emotionAnalysisRow
        }
    }

    private var hooksProviderList: some View {
        VStack(alignment: .leading, spacing: 4) {
            hookProviderRow(for: .claude, status: claudeHooksStatus)
            hookProviderRow(for: .codex, status: codexHooksStatus)
        }
        .padding(.vertical, SettingsLayout.pickerInset)
        .background(TerminalColors.subtleBackground)
        .cornerRadius(8)
    }

    private func hookProviderRow(for provider: AgentProvider, status: AgentHookInstallStatus) -> some View {
        Button(action: { toggleHooks(for: provider) }) {
            HStack(spacing: 8) {
                Text(provider.displayName)
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.primaryText)

                Spacer()

                statusBadge(hookProviderStatus(status))

                ToggleSwitch(isOn: hooksEnabled(for: provider))
            }
            .padding(.horizontal, SettingsLayout.pickerOptionHorizontalPadding)
            .padding(.vertical, SettingsLayout.pickerOptionVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(status == .providerUnavailable)
    }

    private var emotionAnalysisRow: some View {
        Button(action: { showingEmotionAnalysisSettings = true }) {
            SettingsRowView(icon: "brain", title: "Emotion Analysis") {
                HStack(spacing: 6) {
                    let status = emotionAnalysisStatus()
                    statusBadge(status.text, color: status.color)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(TerminalColors.dimmedText)
                }
            }
        }
        .buttonStyle(.plain)
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
            logger.error("Failed to toggle launch at login: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func connectUsage() {
        ClaudeUsageService.shared.connectAndStartPolling()
    }

    private func toggleHideSpriteWhenIdle() {
        hideSpriteWhenIdle.toggle()
    }

    private func toggleHideGrassIsland() {
        hideGrassIsland.toggle()
    }

    private func toggleExpandOnHover() {
        expandOnHover.toggle()
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

    private func toggleHooksExpanded() {
        withAnimation(.spring(response: 0.3)) {
            areHooksExpanded.toggle()
        }
        if areHooksExpanded {
            refreshHookStatuses()
        }
    }

    private func handleUpdatesAction() {
        if case .upToDate = updateManager.state {
            openLatestReleasePage()
        } else {
            updateManager.checkForUpdates()
        }
    }

    private func hooksSummaryStatus() -> StatusBadge {
        let states = availableHookStates()

        guard !states.isEmpty else {
            return StatusBadge(text: String(localized: "Unavailable"), color: TerminalColors.amber)
        }

        let enabledStates = states.filter { $0 != .disabled }
        guard !enabledStates.isEmpty else {
            return StatusBadge(text: String(localized: "Off"), color: TerminalColors.dimmedText)
        }

        if enabledStates.contains(.failed) {
            return StatusBadge(text: String(localized: "Error"), color: TerminalColors.red)
        }

        let installedCount = enabledStates.filter { $0 == .installed }.count
        if installedCount == enabledStates.count {
            return StatusBadge(text: String(localized: "Installed"), color: TerminalColors.green)
        }

        if installedCount > 0 {
            return StatusBadge(text: String(localized: "Partial"), color: TerminalColors.amber)
        }

        return StatusBadge(text: String(localized: "Set Up"), color: TerminalColors.amber)
    }

    private func availableHookStates() -> [AgentHookInstallStatus] {
        [claudeHooksStatus, codexHooksStatus].filter { status in
            status != .providerUnavailable
        }
    }

    private func hookProviderStatus(_ status: AgentHookInstallStatus) -> StatusBadge {
        switch status {
        case .installed:
            StatusBadge(text: String(localized: "Installed"), color: TerminalColors.green)
        case .notInstalled:
            StatusBadge(text: String(localized: "Install"), color: TerminalColors.amber)
        case .providerUnavailable:
            StatusBadge(text: String(localized: "Not Found"), color: TerminalColors.amber)
        case .failed:
            StatusBadge(text: String(localized: "Error"), color: TerminalColors.red)
        case .disabled:
            StatusBadge(text: String(localized: "Off"), color: TerminalColors.dimmedText)
        }
    }

    private func usageStatus() -> StatusBadge {
        let sessions = sessionStore.sortedSessions
        let state = PanelUsageBadgeState.resolve(
            isClaudeUsageConnected: usageConnected,
            hasActiveClaudeSession: sessions.contains { $0.provider == .claude },
            hasActiveCodexSession: sessions.contains { $0.provider == .codex },
            codexHooksInstalled: codexHooksStatus == .installed
        )
        return StatusBadge(text: state.text, color: state.color)
    }

    private func hooksEnabled(for provider: AgentProvider) -> Bool {
        switch provider {
        case .claude:
            claudeHooksEnabled
        case .codex:
            codexHooksEnabled
        }
    }

    private func toggleHooks(for provider: AgentProvider) {
        let requestedEnabled = !hooksEnabled(for: provider)
        let status = IntegrationCoordinator.shared.setHooksEnabled(requestedEnabled, for: provider)
        // Enabling can fail (provider missing, install error), in which case the
        // preference is not persisted — read it back instead of assuming.
        let enabled = AppSettings.areHooksEnabled(for: provider)

        switch provider {
        case .claude:
            claudeHooksEnabled = enabled
            claudeHooksStatus = status
        case .codex:
            codexHooksEnabled = enabled
            codexHooksStatus = status
        }
    }

    private func refreshHookStatuses() {
        claudeHooksStatus = IntegrationCoordinator.shared.installStatus(for: .claude)
        codexHooksStatus = IntegrationCoordinator.shared.installStatus(for: .codex)
        claudeHooksEnabled = AppSettings.areHooksEnabled(for: .claude)
        codexHooksEnabled = AppSettings.areHooksEnabled(for: .codex)
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

    private func statusBadge(_ status: StatusBadge) -> some View {
        statusBadge(status.text, color: status.color)
    }

    private func emotionAnalysisStatus() -> (text: String, color: Color) {
        let provider = AppSettings.emotionAnalysisProvider
        if hasStoredApiKey(for: provider) {
            return (provider.displayName, TerminalColors.green)
        }

        if provider == .claude,
           ClaudeSettingsConfig.existsAtDefaultLocation() {
            return ("Claude Code", TerminalColors.green)
        }

        return (String(localized: "No Key"), TerminalColors.red)
    }

    private func hasStoredApiKey(for provider: EmotionAnalysisProvider) -> Bool {
        AppSettings.apiKey(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
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
            statusBadge(String(localized: "Up to date"), color: TerminalColors.green)
        case .updateAvailable:
            statusBadge(String(localized: "Update available"), color: TerminalColors.amber)
        case .downloading:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Downloading...")
                    .font(.system(size: 10))
                    .foregroundColor(TerminalColors.dimmedText)
            }
        case .readyToInstall:
            statusBadge(String(localized: "Ready to install"), color: TerminalColors.green)
        case .error(let failure):
            statusBadge(failure.label, color: TerminalColors.red)
        case .idle:
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .font(.system(size: 10))
                .foregroundColor(TerminalColors.dimmedText)
        }
    }
}

private struct EmotionAnalysisSettingsView: View {
    private enum TestState {
        case idle
        case testing
        case success(EmotionAnalysisTestResult)
        case failure(String)
    }

    @State private var provider = AppSettings.emotionAnalysisProvider
    @State private var model = AppSettings.selectedEmotionAnalysisModel(for: AppSettings.emotionAnalysisProvider)
    @State private var apiKeyInput = AppSettings.apiKey(for: AppSettings.emotionAnalysisProvider) ?? ""
    @State private var baseURLInput = AppSettings.apiBaseURL(for: AppSettings.emotionAnalysisProvider) ?? ""
    @State private var isProviderPickerExpanded = false
    @State private var isModelPickerExpanded = false
    @State private var testState: TestState = .idle
    @State private var setupLinkShakePhase: CGFloat = 0
    @FocusState private var isAPIKeyFocused: Bool
    @FocusState private var isBaseURLFocused: Bool

    private var hasApiKey: Bool {
        !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                descriptionSection
                providerSection
                modelSection
                apiKeySection
                baseURLSection
                testSection
                setupSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear {
            saveApiKey(for: provider)
            saveBaseURL(for: provider)
        }
        .animation(.spring(response: 0.3), value: isProviderPickerExpanded)
        .animation(.spring(response: 0.3), value: isModelPickerExpanded)
        .onChange(of: apiKeyInput) { _, _ in
            resetTestState()
        }
        .onChange(of: baseURLInput) { _, _ in
            resetTestState()
        }
        .onChange(of: isBaseURLFocused) { _, focused in
            guard !focused else { return }
            saveBaseURL(for: provider)
        }
        .onChange(of: isAPIKeyFocused) { _, focused in
            guard focused else { return }
            withAnimation(.linear(duration: 0.28)) {
                setupLinkShakePhase += 1
            }
        }
    }

    private var descriptionSection: some View {
        Text("Prompts are sent to the selected provider for emotion classification.")
            .font(.system(size: 11))
            .foregroundColor(TerminalColors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                blurAPIKeyField()
                isProviderPickerExpanded.toggle()
            }) {
                SettingsRowView(icon: "switch.2", title: "Provider") {
                    HStack(spacing: 4) {
                        Text(provider.displayName)
                            .font(.system(size: 11))
                            .foregroundColor(TerminalColors.secondaryText)
                        Image(systemName: isProviderPickerExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(TerminalColors.dimmedText)
                    }
                }
            }
            .buttonStyle(.plain)

            if isProviderPickerExpanded {
                providerPicker
            }
        }
    }

    private var providerPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(EmotionAnalysisProvider.allCases) { option in
                    providerRow(option)
                }
            }
            .padding(.vertical, SettingsLayout.pickerInset)
        }
        .frame(height: pickerHeight(optionCount: EmotionAnalysisProvider.allCases.count))
        .background(TerminalColors.subtleBackground)
        .cornerRadius(8)
        .padding(.top, SettingsLayout.pickerInset)
    }

    private func providerRow(_ option: EmotionAnalysisProvider) -> some View {
        Button(action: { selectProvider(option) }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(provider == option ? TerminalColors.green : Color.clear)
                    .frame(width: 6, height: 6)

                Text(option.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(provider == option ? TerminalColors.primaryText : TerminalColors.secondaryText)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, SettingsLayout.pickerOptionHorizontalPadding)
            .padding(.vertical, SettingsLayout.pickerOptionVerticalPadding)
            .background(provider == option ? TerminalColors.hoverBackground : Color.clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var apiKeySection: some View {
        HStack {
            Image(systemName: "key")
                .font(.system(size: 12))
                .foregroundColor(TerminalColors.secondaryText)
                .frame(width: 20)

            Text("API Key")
                .font(.system(size: 12))
                .foregroundColor(TerminalColors.primaryText)
                .layoutPriority(1)

            Spacer(minLength: 12)

            apiKeyStatusView
            apiKeyField
        }
        .padding(.vertical, SettingsLayout.rowVerticalPadding)
    }

    @ViewBuilder
    private var apiKeyStatusView: some View {
        if !hasApiKey, provider == .claude, hasClaudeCodeFallback {
            statusBadge("Claude Code", color: TerminalColors.green)
        }
    }

    private var apiKeyField: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                SecureField("", text: $apiKeyInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(TerminalColors.primaryText)
                    .padding(.horizontal, SettingsLayout.fieldHorizontalPadding)
                    .padding(.vertical, SettingsLayout.fieldVerticalPadding)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(6)
                    .focused($isAPIKeyFocused)
                    .onSubmit { saveApiKey(for: provider) }

                if apiKeyInput.isEmpty {
                    Text(provider.apiKeyPlaceholder)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(TerminalColors.dimmedText)
                        .padding(.leading, SettingsLayout.fieldHorizontalPadding)
                        .allowsHitTesting(false)
                }
            }
            .frame(minWidth: 220, maxWidth: 300)

            Button(action: {
                blurAPIKeyField()
                saveApiKey(for: provider)
            }) {
                Image(systemName: hasApiKey ? "checkmark.circle.fill" : "arrow.right.circle")
                    .font(.system(size: 14))
                    .foregroundColor(hasApiKey ? TerminalColors.green : TerminalColors.dimmedText)
            }
            .buttonStyle(.plain)
        }
    }

    private var baseURLSection: some View {
        HStack {
            Image(systemName: "link")
                .font(.system(size: 12))
                .foregroundColor(TerminalColors.secondaryText)
                .frame(width: 20)

            Text("Base URL")
                .font(.system(size: 12))
                .foregroundColor(TerminalColors.primaryText)
                .layoutPriority(1)

            Spacer(minLength: 12)

            baseURLField
        }
        .padding(.vertical, SettingsLayout.rowVerticalPadding)
    }

    private var baseURLField: some View {
        ZStack(alignment: .leading) {
            TextField("", text: $baseURLInput)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(TerminalColors.primaryText)
                .padding(.horizontal, SettingsLayout.fieldHorizontalPadding)
                .padding(.vertical, SettingsLayout.fieldVerticalPadding)
                .background(Color.white.opacity(0.06))
                .cornerRadius(6)
                .focused($isBaseURLFocused)
                .onSubmit { saveBaseURL(for: provider) }

            if baseURLInput.isEmpty {
                Text(provider.apiBaseURLPlaceholder)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(TerminalColors.dimmedText)
                    .padding(.leading, SettingsLayout.fieldHorizontalPadding)
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 220, maxWidth: 300)
    }

    private var setupSection: some View {
        Button(action: openAPIKeyPage) {
            SettingsRowView(icon: "arrow.up.right.square", title: "Get API Key") {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundColor(TerminalColors.dimmedText)
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isAPIKeyFocused ? TerminalColors.hoverBackground : Color.clear)
                    .padding(.horizontal, -4)
                    .padding(.vertical, -2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isAPIKeyFocused ? Color.white.opacity(0.08) : Color.clear, lineWidth: 1)
                    .padding(.horizontal, -4)
                    .padding(.vertical, -2)
            )
        }
        .buttonStyle(.plain)
        .modifier(HorizontalShake(animatableData: setupLinkShakePhase))
        .animation(.easeInOut(duration: 0.15), value: isAPIKeyFocused)
    }

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: testEmotionAnalysis) {
                SettingsRowView(icon: "bolt.horizontal", title: "Test") {
                    testStatusView
                }
            }
            .buttonStyle(.plain)
            .disabled(isTesting || !canTest)

            testDetailView
        }
    }

    @ViewBuilder
    private var testStatusView: some View {
        switch testState {
        case .idle:
            if canTest {
                Image(systemName: "play.circle")
                    .font(.system(size: 13))
                    .foregroundColor(TerminalColors.dimmedText)
            } else {
                statusBadge(String(localized: "Missing key"), color: TerminalColors.red)
            }
        case .testing:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 16, height: 16)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(TerminalColors.green)
        case .failure(let message):
            statusBadge(message, color: TerminalColors.red)
        }
    }

    @ViewBuilder
    private var testDetailView: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            testDetailText(String(localized: "Testing \(provider.displayName) with \(model.displayName)..."))
        case .success(let result):
            testDetailText(String(localized: "Result: \(testResultText(result))"))
        case .failure:
            testDetailText(canTest ? String(localized: "Could not verify this configuration.") : String(localized: "Add an API key to test this configuration."))
        }
    }

    private func testDetailText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(TerminalColors.dimmedText)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, 28)
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                blurAPIKeyField()
                isModelPickerExpanded.toggle()
            }) {
                SettingsRowView(icon: "cpu", title: "Model") {
                    HStack(spacing: 4) {
                        Text(model.displayName)
                            .font(.system(size: 11))
                            .foregroundColor(TerminalColors.secondaryText)
                        Image(systemName: isModelPickerExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(TerminalColors.dimmedText)
                    }
                }
            }
            .buttonStyle(.plain)

            if isModelPickerExpanded {
                modelPicker
            }
        }
    }

    private var modelPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(EmotionAnalysisModel.models(for: provider)) { option in
                    modelRow(option)
                }
            }
            .padding(.vertical, SettingsLayout.pickerInset)
        }
        .frame(height: pickerHeight(optionCount: EmotionAnalysisModel.models(for: provider).count))
        .background(TerminalColors.subtleBackground)
        .cornerRadius(8)
        .padding(.top, SettingsLayout.pickerInset)
    }

    private func modelRow(_ option: EmotionAnalysisModel) -> some View {
        Button(action: { selectModel(option) }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model == option ? TerminalColors.green : Color.clear)
                    .frame(width: 6, height: 6)

                Text(option.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(model == option ? TerminalColors.primaryText : TerminalColors.secondaryText)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, SettingsLayout.pickerOptionHorizontalPadding)
            .padding(.vertical, SettingsLayout.pickerOptionVerticalPadding)
            .background(model == option ? TerminalColors.hoverBackground : Color.clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pickerHeight(optionCount: Int) -> CGFloat {
        let rowHeight: CGFloat = 28
        let rowSpacing: CGFloat = 4
        let visibleCount = min(optionCount, 6)
        return CGFloat(visibleCount) * rowHeight + CGFloat(max(visibleCount - 1, 0)) * rowSpacing
    }

    private var fallbackStatusText: String {
        if provider == .claude, hasClaudeCodeFallback {
            return "Claude Code"
        }
        return String(localized: "Missing")
    }

    private var fallbackStatusColor: Color {
        provider == .claude && hasClaudeCodeFallback ? TerminalColors.green : TerminalColors.red
    }

    private var hasClaudeCodeFallback: Bool {
        ClaudeSettingsConfig.existsAtDefaultLocation()
    }

    private var canTest: Bool {
        hasApiKey || (provider == .claude && hasClaudeCodeFallback)
    }

    private var isTesting: Bool {
        if case .testing = testState {
            return true
        }
        return false
    }

    private func selectProvider(_ newProvider: EmotionAnalysisProvider) {
        blurAPIKeyField()
        guard newProvider != provider else { return }
        saveApiKey(for: provider)
        saveBaseURL(for: provider)
        provider = newProvider
        AppSettings.emotionAnalysisProvider = newProvider
        model = AppSettings.selectedEmotionAnalysisModel(for: newProvider)
        apiKeyInput = AppSettings.apiKey(for: newProvider) ?? ""
        baseURLInput = AppSettings.apiBaseURL(for: newProvider) ?? ""
        resetTestState()
    }

    private func selectModel(_ newModel: EmotionAnalysisModel) {
        blurAPIKeyField()
        guard newModel != model else { return }
        model = newModel
        AppSettings.setEmotionAnalysisModel(newModel, for: provider)
        resetTestState()
    }

    private func saveApiKey(for provider: EmotionAnalysisProvider) {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.setApiKey(trimmed.isEmpty ? nil : trimmed, for: provider)
    }

    private func saveBaseURL(for provider: EmotionAnalysisProvider) {
        AppSettings.setApiBaseURL(baseURLInput, for: provider)
    }

    private func openAPIKeyPage() {
        blurAPIKeyField()
        NSWorkspace.shared.open(provider.apiKeyURL)
    }

    private func testEmotionAnalysis() {
        blurAPIKeyField()
        guard !isTesting else { return }
        testState = .testing

        let currentProvider = provider
        let currentModel = model
        let currentAPIKey = apiKeyInput
        let currentBaseURL = baseURLInput

        Task { @MainActor in
            do {
                let result = try await EmotionAnalyzer.shared.testConfiguration(
                    provider: currentProvider,
                    model: currentModel,
                    apiKey: currentAPIKey,
                    baseURL: currentBaseURL
                )
                guard isCurrentTestSnapshot(provider: currentProvider, model: currentModel, apiKey: currentAPIKey, baseURL: currentBaseURL) else { return }
                testState = .success(result)
            } catch {
                guard isCurrentTestSnapshot(provider: currentProvider, model: currentModel, apiKey: currentAPIKey, baseURL: currentBaseURL) else { return }
                testState = .failure(testErrorText(error))
            }
        }
    }

    private func resetTestState() {
        testState = .idle
    }

    private func isCurrentTestSnapshot(
        provider: EmotionAnalysisProvider,
        model: EmotionAnalysisModel,
        apiKey: String,
        baseURL: String
    ) -> Bool {
        self.provider == provider && self.model == model && apiKeyInput == apiKey && baseURLInput == baseURL
    }

    private func blurAPIKeyField() {
        isAPIKeyFocused = false
    }

    private func testResultText(_ result: EmotionAnalysisTestResult) -> String {
        "\(result.emotion.capitalized) \(String(format: "%.2f", result.intensity)) - \(result.latencyMilliseconds)ms"
    }

    private func testErrorText(_ error: Error) -> String {
        if let requestError = error as? EmotionAnalysisRequestError {
            return requestError.shortLabel
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return String(localized: "Offline")
            case .timedOut:
                return String(localized: "Timeout")
            default:
                return String(localized: "Failed")
            }
        }

        return String(localized: "Failed")
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
}

private struct HorizontalShake: GeometryEffect {
    var travelDistance: CGFloat = 3
    var cyclesPerUnit: CGFloat = 1
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(
                translationX: travelDistance * sin(animatableData * .pi * 2 * cyclesPerUnit),
                y: 0
            )
        )
    }
}

private struct NotchLayoutSettingsView: View {
    private enum Side { case left, right }

    @AppStorage(AppSettings.notchLeftContentKey) private var leftRaw = NotchSlotContent.ring.rawValue
    @AppStorage(AppSettings.notchRightContentKey) private var rightRaw = NotchSlotContent.latest.rawValue
    @State private var isLeftExpanded = false
    @State private var isRightExpanded = false

    private var left: NotchSlotContent { NotchSlotContent(rawValue: leftRaw) ?? .ring }
    private var right: NotchSlotContent { NotchSlotContent(rawValue: rightRaw) ?? .latest }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            sideRow(.left, icon: "rectangle.lefthalf.filled", title: "Notch Left", isExpanded: $isLeftExpanded)
            sideRow(.right, icon: "rectangle.righthalf.filled", title: "Notch Right", isExpanded: $isRightExpanded)
        }
        .animation(.spring(response: 0.3), value: isLeftExpanded)
        .animation(.spring(response: 0.3), value: isRightExpanded)
    }

    @ViewBuilder
    private func sideRow(_ side: Side, icon: String, title: LocalizedStringKey, isExpanded: Binding<Bool>) -> some View {
        let selection = side == .left ? left : right
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { isExpanded.wrappedValue.toggle() }) {
                SettingsRowView(icon: icon, title: title) {
                    HStack(spacing: 4) {
                        Text(selection.displayName)
                            .font(.system(size: 11))
                            .foregroundColor(TerminalColors.secondaryText)
                        Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(TerminalColors.dimmedText)
                    }
                }
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                picker(side)
            }
        }
    }

    private func picker(_ side: Side) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(NotchSlotContent.allCases) { option in
                    optionRow(side, option: option)
                }
            }
            .padding(.vertical, SettingsLayout.pickerInset)
        }
        .frame(height: pickerHeight(optionCount: NotchSlotContent.allCases.count))
        .background(TerminalColors.subtleBackground)
        .cornerRadius(8)
        .padding(.top, SettingsLayout.pickerInset)
    }

    private func optionRow(_ side: Side, option: NotchSlotContent) -> some View {
        let selection = side == .left ? left : right
        let other = side == .left ? right : left
        let isSelected = selection == option
        let hint = pickHint(option: option, isSelected: isSelected, other: other)
        return Button(action: { select(option, for: side) }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Color.clear)
                    .frame(width: 6, height: 6)
                Text(option.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? TerminalColors.primaryText : TerminalColors.secondaryText)
                    .lineLimit(1)
                Spacer()
                if let hint {
                    Text(hint)
                        .font(.system(size: 9))
                        .foregroundColor(TerminalColors.dimmedText)
                }
            }
            .padding(.horizontal, SettingsLayout.pickerOptionHorizontalPadding)
            .padding(.vertical, SettingsLayout.pickerOptionVerticalPadding)
            .background(isSelected ? TerminalColors.hoverBackground : Color.clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pickHint(option: NotchSlotContent, isSelected: Bool, other: NotchSlotContent) -> String? {
        guard !isSelected else { return nil }
        if option == other, other != .nothing { return String(localized: "swap") }
        if NotchSlotContent.conflict(option, other) { return String(localized: "replace") }
        return nil
    }

    private func select(_ option: NotchSlotContent, for side: Side) {
        switch side {
        case .left:
            AppSettings.notchLeftContent = option
            isLeftExpanded = false
        case .right:
            AppSettings.notchRightContent = option
            isRightExpanded = false
        }
    }

    private func pickerHeight(optionCount: Int) -> CGFloat {
        let rowHeight: CGFloat = 28
        let rowSpacing: CGFloat = 4
        let visibleCount = min(optionCount, 6)
        return CGFloat(visibleCount) * rowHeight + CGFloat(max(visibleCount - 1, 0)) * rowSpacing
    }
}

struct SettingsRowView<Trailing: View>: View {
    let icon: String
    let title: LocalizedStringKey
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
