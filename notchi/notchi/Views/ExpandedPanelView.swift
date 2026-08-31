import SwiftUI

private struct PanelSwapTransitionModifier: ViewModifier {
    let blur: CGFloat
    let opacity: Double
    let xOffset: CGFloat

    static let identity = PanelSwapTransitionModifier(blur: 0, opacity: 1, xOffset: 0)

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .opacity(opacity)
            .offset(x: xOffset)
            .compositingGroup()
    }
}

private struct MorphingText: View {
    let text: String
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let color: Color
    var alignment: TextAlignment = .leading
    var lineLimit: Int? = 1

    @Environment(\.panelScale) private var panelScale
    @State private var displayedText: String
    @State private var blurProgress: CGFloat = 0
    @State private var morphGeneration = 0

    init(
        text: String,
        fontSize: CGFloat,
        fontWeight: Font.Weight = .regular,
        color: Color,
        alignment: TextAlignment = .leading,
        lineLimit: Int? = 1
    ) {
        self.text = text
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.color = color
        self.alignment = alignment
        self.lineLimit = lineLimit
        _displayedText = State(initialValue: text)
    }

    var body: some View {
        let baseText: Text = Text(displayedText)
            .font(.system(size: fontSize * PanelTypography.fontScale(panelScale: panelScale), weight: fontWeight))

        return baseText
            .foregroundColor(color)
            .lineLimit(lineLimit)
            .multilineTextAlignment(alignment)
            // Blur out briefly so the hard string swap reads like a morph.
            .blur(radius: blurProgress * 6)
            .opacity(1 - (blurProgress * 0.18))
            .compositingGroup()
            .onChange(of: text) { _, newText in
                guard newText != displayedText else { return }

                morphGeneration += 1
                let generation = morphGeneration

                withAnimation(.easeOut(duration: 0.11)) {
                    blurProgress = 1
                }

                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(70))
                    guard generation == morphGeneration else { return }

                    displayedText = newText

                    withAnimation(.easeOut(duration: 0.18)) {
                        blurProgress = 0
                    }
                }
            }
    }
}

enum ActivityItem: Identifiable {
    case tool(SessionEvent)
    case assistant(AssistantMessage)

    var id: String {
        switch self {
        case .tool(let event): return "tool-\(event.id.uuidString)"
        case .assistant(let msg): return "assistant-\(msg.id)"
        }
    }

    var timestamp: Date {
        switch self {
        case .tool(let event): return event.timestamp
        case .assistant(let msg): return msg.timestamp
        }
    }
}

nonisolated struct SharedUsageBarState {
    let provider: AgentProvider
    let usage: QuotaPeriod?
    let isUsingExtraUsage: Bool
    let isLoading: Bool
    let error: String?
    let statusMessage: String?
    let isStale: Bool
    let recoveryAction: ClaudeUsageRecoveryAction
    let lastObservedAt: Date?
    let labelOverride: String?
    let isProviderSpecific: Bool
    let period: MainUsageBarPeriod

    init(
        provider: AgentProvider,
        usage: QuotaPeriod?,
        isUsingExtraUsage: Bool,
        isLoading: Bool,
        error: String?,
        statusMessage: String?,
        isStale: Bool,
        recoveryAction: ClaudeUsageRecoveryAction,
        lastObservedAt: Date?,
        labelOverride: String? = nil,
        isProviderSpecific: Bool = true,
        period: MainUsageBarPeriod = .session
    ) {
        self.provider = provider
        self.usage = usage
        self.isUsingExtraUsage = isUsingExtraUsage
        self.isLoading = isLoading
        self.error = error
        self.statusMessage = statusMessage
        self.isStale = isStale
        self.recoveryAction = recoveryAction
        self.lastObservedAt = lastObservedAt
        self.labelOverride = labelOverride
        self.isProviderSpecific = isProviderSpecific
        self.period = period
    }

    var label: String {
        if let labelOverride {
            return labelOverride
        }
        return String(localized: "\(provider.displayName) Usage")
    }

    static let noActiveSession = SharedUsageBarState(
        // Provider is a placeholder; isProviderSpecific=false suppresses provider-keyed UI.
        provider: .claude,
        usage: nil,
        isUsingExtraUsage: false,
        isLoading: false,
        error: nil,
        statusMessage: nil,
        isStale: false,
        recoveryAction: .none,
        lastObservedAt: nil,
        labelOverride: String(localized: "Start a session to track usage"),
        isProviderSpecific: false
    )
}

struct ExpandedPanelView: View {
    let sessionStore: SessionStore
    let usageService: ClaudeUsageService
    let codexUsageService: CodexUsageService
    let usageDetailProvider: AgentProvider?
    @Binding var showingSettings: Bool
    @Binding var settingsPath: [SettingsScreen]
    @Binding var showingSessionActivity: Bool
    @Binding var showingUsageDetail: Bool
    @Binding var isActivityCollapsed: Bool
    @Binding var hoveredSessionId: String?
    @AppStorage(AppSettings.showGrassIslandKey) private var showGrassIsland = true
    @AppStorage(AppSettings.showGitBranchAndPullRequestKey) private var showGitBranchAndPullRequest = true
    @AppStorage(AppSettings.mainUsageBarPeriodKey) private var mainUsageBarPeriodRaw = MainUsageBarPeriod.session.rawValue
    @Environment(\.panelScale) private var panelScale

    static let compactHeaderClearance: CGFloat = 0
    static let compactFeedMaxHeight: CGFloat = 320
    static let defaultFeedMaxHeight: CGFloat = 200

    static func feedMaxHeight(mode: ExpandedPanelMode, panelScale: CGFloat) -> CGFloat {
        (mode == .compact ? compactFeedMaxHeight : defaultFeedMaxHeight) * panelScale
    }

    init(
        sessionStore: SessionStore,
        usageService: ClaudeUsageService,
        codexUsageService: CodexUsageService,
        usageDetailProvider: AgentProvider?,
        showingSettings: Binding<Bool>,
        settingsPath: Binding<[SettingsScreen]>,
        showingSessionActivity: Binding<Bool>,
        showingUsageDetail: Binding<Bool>,
        isActivityCollapsed: Binding<Bool>,
        hoveredSessionId: Binding<String?>
    ) {
        self.sessionStore = sessionStore
        self.usageService = usageService
        self.codexUsageService = codexUsageService
        self.usageDetailProvider = usageDetailProvider
        _showingSettings = showingSettings
        _settingsPath = settingsPath
        _showingSessionActivity = showingSessionActivity
        _showingUsageDetail = showingUsageDetail
        _isActivityCollapsed = isActivityCollapsed
        _hoveredSessionId = hoveredSessionId
    }

    private var panelMode: ExpandedPanelMode {
        NotchContentView.panelMode(
            showGrassIsland: showGrassIsland,
            isActivityCollapsed: isActivityCollapsed
        )
    }

    private var effectiveSession: SessionData? {
        sessionStore.effectiveSession
    }

    private var hoveredSession: SessionData? {
        guard let hoveredSessionId else { return nil }
        return sessionStore.sortedSessions.first { $0.id == hoveredSessionId }
    }

    private var usageContextSession: SessionData? {
        hoveredSession ?? effectiveSession
    }

    private var usageDetailDefaultProvider: AgentProvider {
        Self.usageDetailDefaultProvider(
            requestedProvider: usageDetailProvider,
            contextSession: usageContextSession,
            lastUsedProvider: AppSettings.lastUsedAgentProvider
        )
    }

    private var hasUsageDetailData: Bool {
        usageService.hasUsageData || codexUsageService.hasUsageData
    }

    private var state: NotchiState {
        effectiveSession?.state ?? .idle
    }

    private var currentSpinnerVerb: String {
        effectiveSession?.currentSpinnerVerb ?? SpinnerVerbs.defaultVerb
    }

    private var showIndicator: Bool {
        state.task == .working || state.task == .compacting || state.task == .waiting
    }

    private var isShowingUsageDetail: Bool {
        showingUsageDetail && panelMode != .islandOnly
    }

    private var hasActivity: Bool {
        guard let session = effectiveSession else { return false }
        return !session.recentEvents.isEmpty ||
               !session.recentAssistantMessages.isEmpty ||
               session.isProcessing ||
               showIndicator ||
               session.lastUserPrompt != nil
    }

    private var unifiedActivityItems: [ActivityItem] {
        guard let session = effectiveSession else { return [] }
        let toolItems = session.recentEvents.map { ActivityItem.tool($0) }
        let messageItems = session.recentAssistantMessages.map { ActivityItem.assistant($0) }
        return (toolItems + messageItems).sorted { $0.timestamp < $1.timestamp }
    }

    private var shouldShowSessionPicker: Bool {
        sessionStore.activeSessionCount >= 2 && !showingSessionActivity
    }

    private var mainUsageBarPeriod: MainUsageBarPeriod {
        AppSettings.mainUsageBarPeriod(fromRaw: mainUsageBarPeriodRaw)
    }

    private var sharedUsageResetLabelPrefix: String? {
        Self.sharedUsageResetLabelPrefix(
            state: sharedUsageBarState,
            activeSessions: sessionStore.sortedSessions,
            requestedPeriod: mainUsageBarPeriod
        )
    }

    private var sharedUsageBarState: SharedUsageBarState? {
        let activeSessions = sessionStore.sortedSessions
        guard Self.shouldShowSharedUsageBar(
            contextSession: usageContextSession,
            activeSessions: activeSessions
        ) else {
            return nil
        }

        if activeSessions.isEmpty {
            return .noActiveSession
        }

        let includesClaude = Self.includesClaudeUsage(activeSessions: activeSessions)
        let includesCodex = Self.includesCodexUsage(activeSessions: activeSessions)
        let period = mainUsageBarPeriod

        let claudePeriod = Self.effectiveMainUsagePeriod(
            for: period,
            sessionUsage: usageService.currentUsage,
            weeklyUsage: usageService.currentWeeklyUsage
        )
        let claude = includesClaude ? SharedUsageBarState(
            provider: .claude,
            usage: Self.mainUsage(for: claudePeriod, sessionUsage: usageService.currentUsage, weeklyUsage: usageService.currentWeeklyUsage),
            isUsingExtraUsage: Self.mainUsageIsUsingExtraUsage(for: claudePeriod, isUsingExtraUsage: usageService.isUsingExtraUsage),
            isLoading: usageService.isLoading,
            error: usageService.error,
            statusMessage: usageService.statusMessage,
            isStale: Self.mainUsageIsStale(
                for: claudePeriod,
                isUsageStale: usageService.isUsageStale,
                isWeeklyUsageHeldOver: usageService.isWeeklyUsageHeldOver
            ),
            recoveryAction: usageService.recoveryAction,
            lastObservedAt: usageService.lastObservedAt,
            period: claudePeriod
        ) : nil

        let codexPeriod = Self.effectiveMainUsagePeriod(
            for: period,
            sessionUsage: codexUsageService.currentUsage,
            weeklyUsage: codexUsageService.currentWeeklyUsage
        )
        let codex = includesCodex ? SharedUsageBarState(
            provider: .codex,
            usage: Self.mainUsage(
                for: codexPeriod,
                sessionUsage: codexUsageService.currentUsage,
                weeklyUsage: codexUsageService.currentWeeklyUsage
            ),
            isUsingExtraUsage: false,
            isLoading: false,
            error: nil,
            statusMessage: codexUsageService.statusMessage,
            isStale: codexUsageService.isUsageStale,
            recoveryAction: .none,
            lastObservedAt: codexUsageService.lastObservedAt,
            period: codexPeriod
        ) : nil

        return Self.sharedUsageBarState(
            contextSession: usageContextSession,
            claude: claude,
            codex: codex
        )
    }

    private var primaryContentTransition: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: PanelSwapTransitionModifier(blur: 10, opacity: 0, xOffset: -18),
                identity: .identity
            )
            .animation(.easeOut(duration: 0.22).delay(0.04)),
            removal: .modifier(
                active: PanelSwapTransitionModifier(blur: 8, opacity: 0, xOffset: -10),
                identity: .identity
            )
            .animation(.easeIn(duration: 0.14))
        )
    }

    private var settingsContentTransition: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: PanelSwapTransitionModifier(blur: 12, opacity: 0, xOffset: 22),
                identity: .identity
            )
            .animation(.easeOut(duration: 0.22).delay(0.05)),
            removal: .modifier(
                active: PanelSwapTransitionModifier(blur: 8, opacity: 0, xOffset: 10),
                identity: .identity
            )
            .animation(.easeIn(duration: 0.14))
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if !showingSettings {
                    VStack(alignment: .leading, spacing: 0) {
                        ZStack {
                            if isShowingUsageDetail {
                                usageDetailContent(geometry: geometry)
                                    .transition(primaryContentTransition)
                            } else if shouldShowSessionPicker {
                                sessionPickerContent(geometry: geometry)
                                    .transition(primaryContentTransition)
                            } else {
                                activityContent(geometry: geometry)
                                    .transition(primaryContentTransition)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                        if !isShowingUsageDetail {
                            sharedUsageBar
                                .padding(.horizontal, 12)
                                .padding(.bottom, 5)
                        }
                    }
                }

                if showingSettings {
                    PanelSettingsView(path: $settingsPath)
                        .frame(width: geometry.size.width)
                        .transition(settingsContentTransition)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showingSettings)
        .animation(.easeInOut(duration: 0.25), value: showingUsageDetail)
        .animation(.easeInOut(duration: 0.25), value: shouldShowSessionPicker)
        .onChange(of: showingSettings) { _, isShowing in
            if !isShowing {
                settingsPath = []
                UpdateManager.shared.clearTransientStatus()
            }
            if isShowing {
                showingUsageDetail = false
            }
        }
    }

    @ViewBuilder
    private func headerClearanceSpacer(geometry: GeometryProxy) -> some View {
        switch panelMode {
        case .full:
            Spacer()
                .frame(height: geometry.size.height * 0.3)
                .allowsHitTesting(false)
        case .compact:
            Spacer()
                .frame(height: Self.compactHeaderClearance)
                .allowsHitTesting(false)
        case .islandOnly:
            Spacer()
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func sessionPickerContent(geometry: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            headerClearanceSpacer(geometry: geometry)

            VStack(alignment: .leading, spacing: 0) {
                if panelMode != .islandOnly {
                    if panelMode != .compact {
                        Divider().background(Color.white.opacity(0.08))
                    }

                    SessionListView(
                        sessions: sessionStore.sortedSessions,
                        titleForSession: { session in
                            sessionStore.displayTitle(for: session)
                        },
                        selectedSessionId: sessionStore.selectedSessionId,
                        hoveredSessionId: $hoveredSessionId,
                        onSelectSession: { sessionId in
                            if let session = sessionStore.selectSession(matchingStableId: sessionId) {
                                TerminalJumpService.shared.jump(to: session)
                            }
                            showingSessionActivity = true
                        },
                        onDeleteSession: { sessionId in
                            sessionStore.dismissSession(matchingStableId: sessionId)
                        }
                    )
                }

                Spacer()
            }
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func usageDetailContent(geometry: GeometryProxy) -> some View {
        let headerClearance: CGFloat = switch panelMode {
        case .full: geometry.size.height * 0.3
        case .compact: Self.compactHeaderClearance
        case .islandOnly: 8
        }
        VStack(spacing: 0) {
            Spacer()
                .frame(height: headerClearance)
                .allowsHitTesting(false)

            UsageDetailView(
                claudeUsage: usageService,
                codexUsage: codexUsageService,
                costStore: CostHistoryStore.shared,
                codexCostStore: CostHistoryStore.sharedCodex,
                defaultProvider: usageDetailDefaultProvider
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func activityContent(geometry: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            headerClearanceSpacer(geometry: geometry)

            VStack(alignment: .leading, spacing: 0) {
                if hasActivity {
                    if panelMode != .compact {
                        Divider().background(Color.white.opacity(0.08))
                    }
                    activitySection
                } else if panelMode != .islandOnly {
                    Spacer()
                    emptyState
                }

                if panelMode != .islandOnly {
                    Spacer()
                }

                if showIndicator && panelMode != .islandOnly {
                    WorkingIndicatorView(
                        state: state,
                        workingVerb: currentSpinnerVerb,
                        color: effectiveSession?.provider.accentColor ?? TerminalColors.claudeOrange
                    )
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var sharedUsageBar: some View {
        if let state = sharedUsageBarState {
            UsageBarView(
                usage: state.usage,
                isUsingExtraUsage: state.isUsingExtraUsage,
                isLoading: state.isLoading,
                error: state.error,
                statusMessage: state.statusMessage,
                isStale: state.isStale,
                recoveryAction: state.recoveryAction,
                label: state.label,
                resetLabelPrefix: sharedUsageResetLabelPrefix,
                compact: !shouldShowSessionPicker && panelMode == .islandOnly,
                isEnabled: state.isProviderSpecific ? Self.sharedUsageBarIsEnabled(provider: state.provider) : true,
                onConnect: state.provider == .claude && state.isProviderSpecific ? { usageService.connectAndStartPolling() } : nil,
                onRetry: state.provider == .claude && state.isProviderSpecific ? { usageService.retryNow() } : nil,
                onOpenDetail: hasUsageDetailData ? {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        isActivityCollapsed = false
                        showingUsageDetail = true
                    }
                } : nil
            )
        }
    }

    static func shouldShowSharedUsageBar(contextSession: SessionData?, activeSessions: [SessionData]) -> Bool {
        !activeSessions.isEmpty || contextSession == nil
    }

    static func includesClaudeUsage(activeSessions: [SessionData]) -> Bool {
        activeSessions.contains { $0.provider == .claude }
    }

    static func includesCodexUsage(activeSessions: [SessionData]) -> Bool {
        activeSessions.contains { $0.provider == .codex }
    }

    static func hasMixedClaudeAndCodexSessions(_ activeSessions: [SessionData]) -> Bool {
        activeSessions.contains { $0.provider == .claude }
            && activeSessions.contains { $0.provider == .codex }
    }

    static func questionResponseHint(for session: SessionData?) -> String? {
        guard session?.provider == .codex else { return nil }
        return String(localized: "Reply directly in the Codex app or CLI")
    }

    static func sharedUsageResetLabelPrefix(
        state: SharedUsageBarState?,
        activeSessions: [SessionData],
        requestedPeriod: MainUsageBarPeriod
    ) -> String? {
        guard let state else { return nil }

        var parts: [String] = []
        if hasMixedClaudeAndCodexSessions(activeSessions) {
            parts.append(state.provider.displayName)
        }
        if state.period == .weekly || state.period != requestedPeriod {
            let periodName = state.period.displayName
            parts.append(parts.isEmpty ? periodName : periodName.lowercased(with: .autoupdatingCurrent))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // The selected period falls back to the provider's other quota when its own is missing, so the
    // bar shows live data instead of staying empty. The label follows via SharedUsageBarState.period.
    static func effectiveMainUsagePeriod(
        for period: MainUsageBarPeriod,
        sessionUsage: QuotaPeriod?,
        weeklyUsage: QuotaPeriod?
    ) -> MainUsageBarPeriod {
        switch period {
        case .session: sessionUsage == nil && weeklyUsage != nil ? .weekly : .session
        case .weekly: weeklyUsage == nil && sessionUsage != nil ? .session : .weekly
        }
    }

    static func mainUsage(
        for period: MainUsageBarPeriod,
        sessionUsage: QuotaPeriod?,
        weeklyUsage: QuotaPeriod?
    ) -> QuotaPeriod? {
        switch period {
        case .session: sessionUsage
        case .weekly: weeklyUsage
        }
    }

    // Extra usage means session quota overflow, so the badge is misleading next to a weekly percentage.
    static func mainUsageIsUsingExtraUsage(for period: MainUsageBarPeriod, isUsingExtraUsage: Bool) -> Bool {
        period == .session && isUsingExtraUsage
    }

    static func mainUsageIsStale(
        for period: MainUsageBarPeriod,
        isUsageStale: Bool,
        isWeeklyUsageHeldOver: Bool
    ) -> Bool {
        switch period {
        case .session: isUsageStale
        case .weekly: isWeeklyUsageHeldOver
        }
    }

    static func sharedUsageBarIsEnabled(
        provider: AgentProvider,
        appUsageEnabled: Bool = AppSettings.isUsageEnabled
    ) -> Bool {
        provider == .codex || appUsageEnabled
    }

    static func usageDetailDefaultProvider(
        requestedProvider: AgentProvider?,
        contextSession: SessionData?,
        lastUsedProvider: AgentProvider
    ) -> AgentProvider {
        requestedProvider ?? contextSession?.provider ?? lastUsedProvider
    }

    static func sharedUsageBarState(
        contextSession: SessionData?,
        claude: SharedUsageBarState?,
        codex: SharedUsageBarState?,
        claudeUsageEnabled: Bool = AppSettings.isUsageEnabled
    ) -> SharedUsageBarState? {
        guard let claude, let codex else {
            return claude ?? codex
        }

        if let contextSession {
            return contextSession.provider == .claude ? claude : codex
        }

        if let claudeObservedAt = claude.lastObservedAt,
           let codexObservedAt = codex.lastObservedAt,
           claudeObservedAt != codexObservedAt {
            let newer = codexObservedAt > claudeObservedAt ? codex : claude
            let older = codexObservedAt > claudeObservedAt ? claude : codex
            return preferredOrFallback(newer, older, claudeUsageEnabled: claudeUsageEnabled)
        }

        return preferredOrFallback(claude, codex, claudeUsageEnabled: claudeUsageEnabled)
    }

    // Only a bar with nothing at all to show swaps to the provider that has data. Loading, error,
    // status, and recovery states stay visible, and a disabled Claude keeps its connect placeholder.
    private static func preferredOrFallback(
        _ preferred: SharedUsageBarState,
        _ fallback: SharedUsageBarState,
        claudeUsageEnabled: Bool
    ) -> SharedUsageBarState {
        let preferredIsEnabled = sharedUsageBarIsEnabled(provider: preferred.provider, appUsageEnabled: claudeUsageEnabled)
        let preferredIsSilentlyEmpty = preferred.usage == nil
            && !preferred.isLoading
            && preferred.error == nil
            && preferred.statusMessage == nil
            && preferred.recoveryAction == .none
        return preferredIsEnabled && preferredIsSilentlyEmpty && fallback.usage != nil ? fallback : preferred
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if panelMode != .islandOnly {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        if let session = effectiveSession {
                            MorphingText(
                                text: sessionStore.displaySessionLabel(for: session),
                                fontSize: 11,
                                fontWeight: .medium,
                                color: TerminalColors.secondaryText
                            )
                            .layoutPriority(1)
                            if showGitBranchAndPullRequest, let branch = session.gitBranch {
                                GitBranchLabel(branch: branch)
                                if let pullRequest = session.gitPullRequest {
                                    GitPullRequestLabel(pullRequest: pullRequest)
                                        .layoutPriority(1)
                                }
                            }
                        }

                        Spacer()

                        if let session = effectiveSession, let mode = session.currentModeDisplay {
                            ModeBadgeView(mode: mode, rawMode: session.permissionMode)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 0) {
                                if effectiveSession?.lastUserPrompt != nil ||
                                    effectiveSession?.lastUserPromptHasAttachments == true {
                                    UserPromptBubbleView(
                                        text: effectiveSession?.lastUserPrompt,
                                        hasAttachment: effectiveSession?.lastUserPromptHasAttachments == true
                                    )
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                        .padding(.bottom, 8)
                                }

                                ForEach(unifiedActivityItems) { item in
                                    switch item {
                                    case .tool(let event):
                                        ActivityRowView(event: event)
                                            .id(item.id)
                                    case .assistant(let message):
                                        AssistantTextRowView(message: message) { isExpanded in
                                            scrollActivityItem(
                                                item.id,
                                                expanded: isExpanded,
                                                proxy: proxy
                                            )
                                        }
                                            .id(item.id)
                                    }
                                }

                                let questions = effectiveSession?.pendingQuestions ?? []
                                if !questions.isEmpty {
                                    let questionProvider = effectiveSession?.provider ?? .claude
                                    let submitAnswers: (([Int: Int], [Int: String]) -> Bool)? =
                                        effectiveSession?.pendingQuestionResponseContext == nil ? nil : { selectedOptionIndexesByQuestion, customAnswersByQuestion in
                                            guard let sessionKey = effectiveSession?.sessionKey else { return false }
                                            return sessionStore.answerPendingQuestions(
                                                in: sessionKey,
                                                selectedOptionIndexesByQuestion: selectedOptionIndexesByQuestion,
                                                customAnswersByQuestion: customAnswersByQuestion
                                            )
                                        }
                                    QuestionPromptView(
                                        questions: questions,
                                        provider: questionProvider,
                                        responseHint: Self.questionResponseHint(for: effectiveSession),
                                        onSubmitAnswers: submitAnswers
                                    )
                                    .id("question-prompt")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: Self.feedMaxHeight(mode: panelMode, panelScale: panelScale))
                        .onAppear {
                            if effectiveSession?.pendingQuestions.isEmpty == false {
                                scrollToQuestionPrompt(proxy: proxy)
                            } else if let lastItem = unifiedActivityItems.last {
                                proxy.scrollTo(lastItem.id, anchor: .bottom)
                            }
                        }
                        .onChange(of: unifiedActivityItems.last?.id) { _, newId in
                            if let id = newId {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(id, anchor: .bottom)
                                }
                            }
                        }
                        .onChange(of: effectiveSession?.pendingQuestions.count) { _, count in
                            if let count, count > 0 {
                                scrollToQuestionPrompt(proxy: proxy)
                            }
                        }
                    }

                }
                .transition(.opacity)
            }
        }
    }

    private var emptyState: some View {
        let hooksInstalled = IntegrationCoordinator.shared.hasAnyInstalledHooks()
        let title = hooksInstalled ? String(localized: "Waiting for activity") : String(localized: "Hooks not installed")
        let subtitle = hooksInstalled
            ? String(localized: "Start Claude Code or Codex to begin tracking")
            : String(localized: "Open settings to set up Claude Code and Codex integration")

        return VStack(spacing: 8) {
            MorphingText(
                text: title,
                fontSize: 14,
                fontWeight: .medium,
                color: TerminalColors.secondaryText,
                alignment: .center
            )
            MorphingText(
                text: subtitle,
                fontSize: 12,
                color: TerminalColors.dimmedText,
                alignment: .center,
                lineLimit: 2
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func scrollActivityItem(_ id: String, expanded: Bool, proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            let anchor: UnitPoint = expanded ? .top : .bottom
            withAnimation(.easeInOut(duration: 0.22)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        }
    }

    private func scrollToQuestionPrompt(proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("question-prompt", anchor: .bottom)
            }
        }
    }
}

struct PanelHeaderButton: View {
    static let baseSize: CGFloat = 32

    let sfSymbol: String
    var showsIndicator: Bool = false
    let action: () -> Void
    @Environment(\.panelScale) private var panelScale
    @State private var isHovered = false

    var body: some View {
        let buttonScale: CGFloat = panelScale > 1 ? 17 / 16 : 1
        Button(action: action) {
            Image(systemName: sfSymbol)
                .font(.system(size: 16 * buttonScale, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: Self.baseSize * buttonScale, height: Self.baseSize * buttonScale)
                .background(isHovered ? TerminalColors.hoverBackground : TerminalColors.subtleBackground)
                .clipShape(Circle())
                .overlay(alignment: .topTrailing) {
                    if showsIndicator {
                        Circle()
                            .fill(TerminalColors.red)
                            .frame(width: 6 * buttonScale, height: 6 * buttonScale)
                            .offset(x: -6 * buttonScale, y: 6 * buttonScale)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct GitBranchLabel: View {
    let branch: String

    var body: some View {
        HStack(spacing: 3) {
            Image("GitBranch")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 10)
            Text(branch)
                .panelFont(size: 11, weight: .medium)
                .lineLimit(1)
        }
        .foregroundColor(TerminalColors.gitBranch)
    }
}

struct GitPullRequestLabel: View {
    let pullRequest: GitPullRequest

    var body: some View {
        Button {
            if let url = URL(string: pullRequest.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 3) {
                Image("GitPullRequest")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 10)
                Text(verbatim: "#\(pullRequest.number)")
                    .panelFont(size: 11, weight: .medium)
            }
            .foregroundColor(TerminalColors.pullRequest)
        }
        .buttonStyle(.plain)
    }
}

struct ModeBadgeView: View {
    let mode: String
    let rawMode: String

    var color: Color {
        switch rawMode {
        case "plan": TerminalColors.planMode
        case "acceptEdits", CodexPermissionMode.standard: TerminalColors.acceptEdits
        case "auto": TerminalColors.autoMode
        case "bypassPermissions", "dontAsk", CodexPermissionMode.fullAccess: TerminalColors.bypassPermissions
        default: TerminalColors.secondaryText
        }
    }

    var body: some View {
        Text(mode)
            .panelFont(size: 11, weight: .medium)
            .foregroundColor(color)
    }
}
