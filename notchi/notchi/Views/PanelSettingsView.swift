import ServiceManagement
import SwiftUI

private enum HookInstallBadgeState {
    case installed
    case notInstalled
    case providerMissing
    case error

    func text(for provider: AgentProvider) -> String {
        switch self {
        case .installed:
            "Installed"
        case .notInstalled:
            "Not Installed"
        case .providerMissing:
            "\(provider.displayName) Missing"
        case .error:
            "Error"
        }
    }

    var color: Color {
        switch self {
        case .installed:
            TerminalColors.green
        case .providerMissing:
            TerminalColors.amber
        case .notInstalled, .error:
            TerminalColors.red
        }
    }
}

struct PanelSettingsView: View {
    @Binding private var showingEmotionAnalysisSettings: Bool
    @AppStorage(AppSettings.hideSpriteWhenIdleKey) private var hideSpriteWhenIdle = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var claudeHooksInstalled = IntegrationCoordinator.shared.isInstalled(for: .claude)
    @State private var claudeHooksError = false
    @State private var codexHooksInstalled = IntegrationCoordinator.shared.isInstalled(for: .codex)
    @State private var codexHooksError = false
    @ObservedObject private var updateManager = UpdateManager.shared
    private var usageConnected: Bool { ClaudeUsageService.shared.isConnected }

    init(showingEmotionAnalysisSettings: Binding<Bool> = .constant(false)) {
        _showingEmotionAnalysisSettings = showingEmotionAnalysisSettings
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
    }

    private var mainSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                    systemSection
                    Divider().background(Color.white.opacity(0.08))
                    aiSection
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

            SkinPickerRow()

            SoundPickerView()

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
            Button(action: { installHooksIfNeeded(for: .claude) }) {
                SettingsRowView(icon: "terminal", title: "Claude Hooks") {
                    statusBadge(
                        hookStatusText(for: .claude, installed: claudeHooksInstalled, error: claudeHooksError),
                        color: hookStatusColor(for: .claude, installed: claudeHooksInstalled, error: claudeHooksError)
                    )
                }
            }
            .buttonStyle(.plain)

            Button(action: { installHooksIfNeeded(for: .codex) }) {
                SettingsRowView(icon: "terminal", title: "Codex Hooks") {
                    statusBadge(
                        hookStatusText(for: .codex, installed: codexHooksInstalled, error: codexHooksError),
                        color: hookStatusColor(for: .codex, installed: codexHooksInstalled, error: codexHooksError)
                    )
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

            emotionAnalysisRow
        }
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
            print("Failed to toggle launch at login: \(error)")
        }
    }

    private func connectUsage() {
        ClaudeUsageService.shared.connectAndStartPolling()
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

    private func hookStatusText(for provider: AgentProvider, installed: Bool, error: Bool) -> String {
        hookStatus(for: provider, installed: installed, error: error).text(for: provider)
    }

    private func hookStatusColor(for provider: AgentProvider, installed: Bool, error: Bool) -> Color {
        hookStatus(for: provider, installed: installed, error: error).color
    }

    private func hookStatus(for provider: AgentProvider, installed: Bool, error: Bool) -> HookInstallBadgeState {
        guard IntegrationCoordinator.shared.isProviderAvailable(for: provider) else {
            return .providerMissing
        }
        if error { return .error }
        if installed { return .installed }
        return .notInstalled
    }

    private func installHooksIfNeeded(for provider: AgentProvider) {
        switch provider {
        case .claude:
            guard !claudeHooksInstalled else { return }
            claudeHooksError = false
        case .codex:
            guard !codexHooksInstalled else { return }
            codexHooksError = false
        }

        guard IntegrationCoordinator.shared.isProviderAvailable(for: provider) else {
            switch provider {
            case .claude:
                claudeHooksInstalled = false
                claudeHooksError = false
            case .codex:
                codexHooksInstalled = false
                codexHooksError = false
            }
            return
        }

        let success = IntegrationCoordinator.shared.installHooksIfNeeded(for: provider)
        let installed = IntegrationCoordinator.shared.isInstalled(for: provider)

        switch provider {
        case .claude:
            claudeHooksInstalled = installed
            claudeHooksError = !success || !installed
        case .codex:
            codexHooksInstalled = installed
            codexHooksError = !success || !installed
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

    private func emotionAnalysisStatus() -> (text: String, color: Color) {
        let provider = AppSettings.emotionAnalysisProvider
        if hasStoredApiKey(for: provider) {
            return (provider.displayName, TerminalColors.green)
        }

        if provider == .claude,
           ClaudeSettingsConfig.existsAtDefaultLocation() {
            return ("Claude Code", TerminalColors.green)
        }

        return ("No Key", TerminalColors.red)
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
    @State private var isProviderPickerExpanded = false
    @State private var isModelPickerExpanded = false
    @State private var testState: TestState = .idle
    @State private var setupLinkShakePhase: CGFloat = 0
    @FocusState private var isAPIKeyFocused: Bool

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
                testSection
                setupSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear {
            saveApiKey(for: provider)
        }
        .animation(.spring(response: 0.3), value: isProviderPickerExpanded)
        .animation(.spring(response: 0.3), value: isModelPickerExpanded)
        .onChange(of: apiKeyInput) { _, _ in
            resetTestState()
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
                statusBadge("Missing key", color: TerminalColors.red)
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
            testDetailText("Testing \(provider.displayName) with \(model.displayName)...")
        case .success(let result):
            testDetailText("Result: \(testResultText(result))")
        case .failure:
            testDetailText(canTest ? "Could not verify this configuration." : "Add an API key to test this configuration.")
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
        return "Missing"
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
        provider = newProvider
        AppSettings.emotionAnalysisProvider = newProvider
        model = AppSettings.selectedEmotionAnalysisModel(for: newProvider)
        apiKeyInput = AppSettings.apiKey(for: newProvider) ?? ""
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

        Task { @MainActor in
            do {
                let result = try await EmotionAnalyzer.shared.testConfiguration(
                    provider: currentProvider,
                    model: currentModel,
                    apiKey: currentAPIKey
                )
                guard isCurrentTestSnapshot(provider: currentProvider, model: currentModel, apiKey: currentAPIKey) else { return }
                testState = .success(result)
            } catch {
                guard isCurrentTestSnapshot(provider: currentProvider, model: currentModel, apiKey: currentAPIKey) else { return }
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
        apiKey: String
    ) -> Bool {
        self.provider == provider && self.model == model && apiKeyInput == apiKey
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
                return "Offline"
            case .timedOut:
                return "Timeout"
            default:
                return "Failed"
            }
        }

        return "Failed"
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
