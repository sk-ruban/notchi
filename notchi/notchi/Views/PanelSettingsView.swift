import SwiftUI

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
    @Binding private var path: [SettingsScreen]
    private let sessionStore: SessionStore
    @State private var claudeHooksStatus = IntegrationCoordinator.shared.installStatus(for: .claude)
    @State private var codexHooksStatus = IntegrationCoordinator.shared.installStatus(for: .codex)
    @State private var claudeHooksEnabled = AppSettings.areHooksEnabled(for: .claude)
    @State private var codexHooksEnabled = AppSettings.areHooksEnabled(for: .codex)
    @State private var areHooksExpanded = false
    @State private var codexSetup: CodexHookSetup?
    @State private var isCheckingCodex = false
    @State private var codexCheckRevision = 0
    @ObservedObject private var updateManager = UpdateManager.shared
    private var usageConnected: Bool { ClaudeUsageService.shared.isConnected }

    init(
        path: Binding<[SettingsScreen]> = .constant([]),
        sessionStore: SessionStore? = nil
    ) {
        _path = path
        self.sessionStore = sessionStore ?? .shared
    }

    var body: some View {
        ZStack {
            if path.isEmpty {
                mainSettings
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }

            if let screen = path.last {
                subScreen(for: screen)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: path)
        .padding(.horizontal, SettingsLayout.panelHorizontalPadding)
        .padding(.top, SettingsLayout.topPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            refreshHookStatuses()
        }
        .task(id: codexCheckRevision) {
            await checkCodexSetup()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if areHooksExpanded { refreshHookStatuses() }
        }
    }

    @ViewBuilder
    private func subScreen(for screen: SettingsScreen) -> some View {
        switch screen {
        case .general:
            SettingsGeneralView()
        case .appearance:
            SettingsAppearanceView()
        case .emotionAnalysis:
            EmotionAnalysisSettingsView()
        }
    }

    private var mainSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                    navigationRow(icon: "gearshape", title: "General", screen: .general)
                    navigationRow(icon: "paintbrush", title: "Appearance", screen: .appearance)
                    Divider().background(Color.white.opacity(0.08))
                    integrationsSection
                    Divider().background(Color.white.opacity(0.08))
                    aboutSection
                }
            }
            .scrollIndicators(.never)

            Spacer()

            quitSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func navigationRow(icon: String, title: LocalizedStringKey, screen: SettingsScreen) -> some View {
        Button(action: { path.append(screen) }) {
            SettingsRowView(icon: icon, title: title) {
                Image(systemName: "chevron.right")
                    .panelFont(size: 9, weight: .semibold)
                    .foregroundColor(TerminalColors.dimmedText)
            }
        }
        .buttonStyle(.plain)
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
                            .panelFont(size: 9, weight: .semibold)
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
            if codexHooksStatus == .installed, codexSetup?.readiness != .approved {
                CodexHookSetupView(
                    setup: codexSetup,
                    isChecking: isCheckingCodex,
                    hasSession: hasCodexSession,
                    recheck: refreshHookStatuses
                )
            }
        }
        .padding(.vertical, SettingsLayout.pickerInset)
        .background(TerminalColors.subtleBackground)
        .cornerRadius(8)
    }

    private func hookProviderRow(for provider: AgentProvider, status: AgentHookInstallStatus) -> some View {
        Button(action: { toggleHooks(for: provider) }) {
            HStack(spacing: 8) {
                Text(provider.displayName)
                    .panelFont(size: 11)
                    .foregroundColor(TerminalColors.primaryText)

                Spacer()

                statusBadge(provider == .codex && status == .installed ? codexSetupBadge() : hookProviderStatus(status))

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
        Button(action: { path.append(.emotionAnalysis) }) {
            SettingsRowView(icon: "brain", title: "Emotion Analysis") {
                HStack(spacing: 6) {
                    let status = emotionAnalysisStatus()
                    statusBadge(status.text, color: status.color)
                    Image(systemName: "chevron.right")
                        .panelFont(size: 9, weight: .semibold)
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

            externalLinkRow(icon: "ladybug", title: "Report an Issue", action: openIssueTracker)

            externalLinkRow(icon: "star", title: "Star on GitHub", action: openGitHubRepo)

            externalLinkRow(icon: "heart", title: "Sponsor", action: openSponsorPage)
        }
    }

    private func externalLinkRow(
        icon: String,
        title: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            SettingsRowView(icon: icon, title: title) {
                Image(systemName: "arrow.up.right")
                    .panelFont(size: 10)
                    .foregroundColor(TerminalColors.dimmedText)
            }
        }
        .buttonStyle(.plain)
    }

    private var reportedAgent: String {
        switch (claudeHooksStatus != .providerUnavailable, codexHooksStatus != .providerUnavailable) {
        case (true, true): "Both"
        case (true, false): "Claude Code"
        case (false, true): "Codex"
        case (false, false): "Not sure"
        }
    }

    private func openIssueTracker() {
        guard var components = URLComponents(string: "https://github.com/sk-ruban/notchi/issues/new") else { return }
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let agent = reportedAgent
        components.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "app-version", value: appVersion),
            URLQueryItem(name: "macos-version", value: osVersion),
            URLQueryItem(name: "agent", value: agent),
            URLQueryItem(name: "body", value: """
            **What went wrong?**


            **Notchi version:** \(appVersion)
            **macOS version:** \(osVersion)
            **Agent:** \(agent)
            """)
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func openGitHubRepo() {
        NSWorkspace.shared.open(URL(string: "https://github.com/sk-ruban/notchi")!)
    }

    private func openSponsorPage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/sponsors/sk-ruban")!)
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
                    .panelFont(size: 13)
                Text("Quit Notchi")
                    .panelFont(size: 12, weight: .medium)
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

    private func connectUsage() {
        ClaudeUsageService.shared.connectAndStartPolling()
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

        if codexHooksStatus == .installed, codexSetup?.readiness != .approved {
            return codexSetupBadge(includeProvider: true)
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

    private var hasCodexSession: Bool {
        sessionStore.sortedSessions.contains { $0.provider == .codex }
    }

    private func codexSetupBadge(includeProvider: Bool = false) -> StatusBadge {
        guard let codexSetup else {
            return StatusBadge(text: String(localized: "Checking…"), color: TerminalColors.dimmedText)
        }
        switch codexSetup.readiness {
        case .approved:
            return StatusBadge(text: hasCodexSession ? String(localized: "Connected") : String(localized: "Approved"), color: TerminalColors.green)
        case .needsApproval:
            return StatusBadge(
                text: includeProvider ? String(localized: "Codex Needs Approval") : String(localized: "Needs Approval"),
                color: TerminalColors.amber
            )
        case .disabled:
            return StatusBadge(text: String(localized: "Disabled in Codex"), color: TerminalColors.amber)
        case .notRegistered:
            return StatusBadge(text: String(localized: "Set Up"), color: TerminalColors.amber)
        case .unverified:
            return StatusBadge(text: String(localized: "Not Verified"), color: TerminalColors.amber)
        }
    }

    private func checkCodexSetup() async {
        guard codexHooksStatus == .installed else {
            codexSetup = nil
            isCheckingCodex = false
            return
        }
        isCheckingCodex = true
        let applicationURLs = ["com.openai.codex", "com.openai.chat"].compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
        let result = await Task.detached(priority: .utility) {
            CodexHookStatusService.check(applicationURLs: applicationURLs)
        }.value
        guard !Task.isCancelled else { return }
        codexSetup = result
        isCheckingCodex = false
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
            codexSetup = nil
            codexCheckRevision += 1
        }
    }

    private func refreshHookStatuses() {
        claudeHooksStatus = IntegrationCoordinator.shared.installStatus(for: .claude)
        codexHooksStatus = IntegrationCoordinator.shared.installStatus(for: .codex)
        claudeHooksEnabled = AppSettings.areHooksEnabled(for: .claude)
        codexHooksEnabled = AppSettings.areHooksEnabled(for: .codex)
        codexCheckRevision += 1
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        SettingsStatusBadge(text: text, color: color)
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
                    .panelFont(size: 10)
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
                    .panelFont(size: 10)
                    .foregroundColor(TerminalColors.dimmedText)
            }
        case .readyToInstall:
            statusBadge(String(localized: "Ready to install"), color: TerminalColors.green)
        case .error(let failure):
            statusBadge(failure.label, color: TerminalColors.red)
        case .idle:
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .panelFont(size: 10)
                .foregroundColor(TerminalColors.dimmedText)
        }
    }
}

#Preview {
    PanelSettingsView()
        .frame(width: 402, height: 400)
        .background(Color.black)
}
