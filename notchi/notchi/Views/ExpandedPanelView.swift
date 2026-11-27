import SwiftUI

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

struct ExpandedPanelView: View {
    let sessionStore: SessionStore
    let usageService: ClaudeUsageService
    let codexUsageService: CodexUsageService
    let devinUsageService: DevinUsageService
    let usageDetailProvider: AgentProvider?
    /// The Claude account whose ring opened the usage page, which can differ from the session in view.
    let usageDetailClaudeAccountId: String?
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
    // Reading it parses each agent's config files, so it's checked on appear rather than per render.
    @State private var hooksInstalled: Bool?

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
        devinUsageService: DevinUsageService,
        usageDetailProvider: AgentProvider?,
        usageDetailClaudeAccountId: String? = nil,
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
        self.devinUsageService = devinUsageService
        self.usageDetailProvider = usageDetailProvider
        self.usageDetailClaudeAccountId = usageDetailClaudeAccountId
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

    /// The Claude usage for the account being looked at, else the most recently active one.
    private var claudeUsageService: ClaudeUsageService {
        ClaudeUsageServices.shared.service(forSession: usageContextSession) ?? usageService
    }

    private var claudeAccountUsages: [UsageDetailView.ClaudeAccountUsage] {
        let accounts = ClaudeAccountStore.shared
        return accounts.accounts.filter(\.isNotchiEnabled).map { account in
            let usageAccount = accounts.usageAccount(for: account)
            return UsageDetailView.ClaudeAccountUsage(
                id: account.id,
                name: account.name,
                color: account.color.color,
                usage: usageAccount == .default ? usageService : ClaudeUsageServices.shared.service(for: usageAccount),
                cost: ClaudeCostStores.shared.store(for: account)
            )
        }
    }

    private var claudeUsageAccountName: String? {
        ClaudeUsageServices.shared.accountName(forSession: usageContextSession)
    }

    private var usageDetailDefaultProvider: AgentProvider {
        Self.usageDetailDefaultProvider(
            requestedProvider: usageDetailProvider,
            contextSession: usageContextSession,
            lastUsedProvider: AppSettings.lastUsedAgentProvider
        )
    }

    /// Counted like the usage page does: accounts running notchi, else the default store.
    private var hasClaudeCostData: Bool {
        let accounts = claudeAccountUsages
        return accounts.isEmpty
            ? !CostHistoryStore.shared.buckets.isEmpty
            : accounts.contains { $0.cost?.buckets.isEmpty == false }
    }

    private var hasUsageDetailData: Bool {
        usageService.hasUsageData || claudeUsageService.hasUsageData
            || codexUsageService.hasUsageData || devinUsageService.hasUsageData
            || hasClaudeCostData || !CostHistoryStore.sharedCodex.buckets.isEmpty
            || !CostHistoryStore.sharedDevin.buckets.isEmpty
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
               session.lastUserPrompt != nil ||
               session.lastUserPromptHasAttachments
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
        let includesDevin = Self.includesDevinUsage(activeSessions: activeSessions)
        let period = mainUsageBarPeriod

        let claudeService = claudeUsageService
        let claudePeriod = Self.effectiveMainUsagePeriod(
            for: period,
            sessionUsage: claudeService.currentUsage,
            weeklyUsage: claudeService.currentWeeklyUsage
        )
        let claude = includesClaude ? SharedUsageBarState(
            provider: .claude,
            usage: Self.mainUsage(for: claudePeriod, sessionUsage: claudeService.currentUsage, weeklyUsage: claudeService.currentWeeklyUsage),
            isUsingExtraUsage: Self.mainUsageIsUsingExtraUsage(for: claudePeriod, isUsingExtraUsage: claudeService.isUsingExtraUsage),
            isFastMode: Self.claudeIsFastMode(activeSessions: activeSessions),
            isLoading: claudeService.isLoading,
            error: claudeService.error,
            statusMessage: claudeService.statusMessage,
            isStale: Self.mainUsageIsStale(
                for: claudePeriod,
                isUsageStale: claudeService.isUsageStale,
                isWeeklyUsageHeldOver: claudeService.isWeeklyUsageHeldOver
            ),
            recoveryAction: claudeService.recoveryAction,
            accountName: claudeUsageAccountName,
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
            statusMessage: codexUsageService.hasUnlimitedCredits && codexUsageService.displayUsage == nil
                ? String(localized: "No spending cap") : nil,
            isStale: codexUsageService.isUsageStale,
            recoveryAction: .none,
            period: codexPeriod
        ) : nil

        let devinPeriod = Self.effectiveMainUsagePeriod(
            for: period,
            sessionUsage: devinUsageService.currentUsage,
            weeklyUsage: devinUsageService.currentWeeklyUsage
        )
        let devin = includesDevin ? SharedUsageBarState(
            provider: .devin,
            usage: Self.mainUsage(
                for: devinPeriod,
                sessionUsage: devinUsageService.currentUsage,
                weeklyUsage: devinUsageService.currentWeeklyUsage
            ),
            isUsingExtraUsage: false,
            isLoading: false,
            error: nil,
            statusMessage: nil,
            isStale: devinUsageService.isUsageStale,
            recoveryAction: .none,
            period: devinPeriod
        ) : nil

        return Self.sharedUsageBarState(
            contextSession: usageContextSession,
            claude: claude,
            codex: codex,
            devin: devin,
            lastUsedProvider: AppSettings.lastUsedAgentProvider,
            claudeUsageEnabled: claudeUsageService.isUsageEnabled
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
                            NotchiStateMachine.shared.dismissSession(matchingStableId: sessionId)
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
                devinUsage: devinUsageService,
                costStore: CostHistoryStore.shared,
                codexCostStore: CostHistoryStore.sharedCodex,
                devinCostStore: CostHistoryStore.sharedDevin,
                defaultProvider: usageDetailDefaultProvider,
                claudeAccounts: claudeAccountUsages,
                // Opens on the account whose ring or usage bar led here.
                initialClaudeAccountId: usageDetailClaudeAccountId
                    ?? ClaudeUsageServices.shared.account(forSession: usageContextSession)?.id
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
                        workingSince: effectiveSession?.promptSubmitTime,
                        color: effectiveSession?.provider.accentColor ?? TerminalColors.claudeOrange
                    )
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func hasUnlimitedUsage(provider: AgentProvider) -> Bool {
        switch provider {
        case .codex: codexUsageService.hasUnlimitedCredits
        case .devin: devinUsageService.hasNoQuota
        case .claude: false
        }
    }

    @ViewBuilder
    private var sharedUsageBar: some View {
        if let state = sharedUsageBarState {
            UsageBarView(
                usage: state.usage,
                hasUnlimitedCredits: state.isProviderSpecific && hasUnlimitedUsage(provider: state.provider),
                unlimitedLabel: state.provider == .devin ? devinUsageService.noQuotaLabel : String(localized: "No spending cap"),
                isUsingExtraUsage: state.isUsingExtraUsage,
                isFastMode: state.isFastMode,
                isLoading: state.isLoading,
                error: state.error,
                statusMessage: state.statusMessage,
                isStale: state.isStale,
                recoveryAction: state.recoveryAction,
                label: state.label,
                resetLabelPrefix: sharedUsageResetLabelPrefix,
                compact: !shouldShowSessionPicker && panelMode == .islandOnly,
                isEnabled: state.isProviderSpecific
                    ? Self.sharedUsageBarIsEnabled(provider: state.provider, appUsageEnabled: claudeUsageService.isUsageEnabled)
                    : true,
                onConnect: state.provider == .claude && state.isProviderSpecific ? {
                    ClaudeUsageServices.shared.connectAndStartPolling()
                } : nil,
                onRetry: state.provider == .claude && state.isProviderSpecific ? { claudeUsageService.retryNow() } : nil,
                onOpenDetail: hasUsageDetailData ? {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        isActivityCollapsed = false
                        showingUsageDetail = true
                    }
                } : nil
            )
        }
    }

    static func questionResponseHint(for session: SessionData?) -> String? {
        guard session?.provider == .codex else { return nil }
        return String(localized: "Reply directly in the Codex app or CLI")
    }

    static func usageDetailDefaultProvider(
        requestedProvider: AgentProvider?,
        contextSession: SessionData?,
        lastUsedProvider: AgentProvider
    ) -> AgentProvider {
        requestedProvider ?? contextSession?.provider ?? lastUsedProvider
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if panelMode != .islandOnly {
                let activityItems = unifiedActivityItems
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

                        if let session = effectiveSession, let contextTokens = session.contextTokens {
                            ContextUsageRing(
                                usage: ContextUsage(usedTokens: contextTokens, windowTokens: session.contextWindowTokens)
                            )
                        }

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
                                        hasOtherAttachments: effectiveSession?.lastUserPromptHasOtherAttachments == true,
                                        imageAttachments: effectiveSession?.lastUserPromptImageAttachments ?? []
                                    )
                                    .padding(.bottom, 8)
                                }

                                ForEach(activityItems) { item in
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
                            } else if let lastItem = activityItems.last {
                                proxy.scrollTo(lastItem.id, anchor: .bottom)
                            }
                        }
                        .onChange(of: activityItems.last?.id) { _, newId in
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
        VStack(spacing: 8) {
            // onAppear runs before the first frame, so this is set by the time anything draws.
            if let hooksInstalled {
                let title = hooksInstalled ? String(localized: "Waiting for activity") : String(localized: "Hooks not installed")
                let subtitle = hooksInstalled
                    ? String(localized: "Start Claude Code, Codex or Devin to begin tracking")
                    : String(localized: "Open settings to set up Claude Code, Codex or Devin integration")

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
        }
        .frame(maxWidth: .infinity)
        .onAppear(perform: refreshHooksInstalled)
        // Forget it while hidden, so the next appearance doesn't morph from a stale title.
        .onDisappear { hooksInstalled = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshHooksInstalled()
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchiLaunchHookInstallDidFinish)) { _ in
            refreshHooksInstalled()
        }
    }

    private func refreshHooksInstalled() {
        hooksInstalled = IntegrationCoordinator.shared.hasAnyInstalledHooks()
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
