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
    let textFont: Font
    let color: Color
    var alignment: TextAlignment = .leading
    var lineLimit: Int? = 1

    @State private var displayedText: String
    @State private var blurProgress: CGFloat = 0
    @State private var morphGeneration = 0

    init(
        text: String,
        font: Font,
        color: Color,
        alignment: TextAlignment = .leading,
        lineLimit: Int? = 1
    ) {
        self.text = text
        self.textFont = font
        self.color = color
        self.alignment = alignment
        self.lineLimit = lineLimit
        _displayedText = State(initialValue: text)
    }

    var body: some View {
        let baseText: Text = Text(displayedText).font(textFont)

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

struct ExpandedPanelView: View {
    let sessionStore: SessionStore
    let usageService: ClaudeUsageService
    @Binding var showingSettings: Bool
    @Binding var showingSessionActivity: Bool
    @Binding var isActivityCollapsed: Bool

    private var effectiveSession: SessionData? {
        sessionStore.effectiveSession
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
                            if shouldShowSessionPicker {
                                sessionPickerContent(geometry: geometry)
                                    .transition(primaryContentTransition)
                            } else {
                                activityContent(geometry: geometry)
                                    .transition(primaryContentTransition)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                        sharedUsageBar
                            .padding(.horizontal, 12)
                            .padding(.bottom, 5)
                    }
                }

                if showingSettings {
                    PanelSettingsView()
                        .frame(width: geometry.size.width)
                        .transition(settingsContentTransition)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showingSettings)
        .animation(.easeInOut(duration: 0.25), value: shouldShowSessionPicker)
        .onChange(of: showingSettings) { _, isShowing in
            if !isShowing {
                UpdateManager.shared.clearTransientStatus()
            }
        }
    }

    @ViewBuilder
    private func sessionPickerContent(geometry: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if isActivityCollapsed {
                Spacer()
                    .allowsHitTesting(false)
            } else {
                Spacer()
                    .frame(height: geometry.size.height * 0.3)
                    .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 0) {
                if !isActivityCollapsed {
                    Divider().background(Color.white.opacity(0.08))

                    SessionListView(
                        sessions: sessionStore.sortedSessions,
                        titleForSession: { session in
                            sessionStore.displayTitle(for: session)
                        },
                        selectedSessionId: sessionStore.selectedSessionId,
                        onSelectSession: { sessionId in
                            sessionStore.selectSession(sessionId)
                            showingSessionActivity = true
                        },
                        onDeleteSession: { sessionId in
                            sessionStore.dismissSession(sessionId)
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
    private func activityContent(geometry: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if isActivityCollapsed {
                Spacer()
                    .allowsHitTesting(false)
            } else {
                Spacer()
                    .frame(height: geometry.size.height * 0.3)
                    .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 0) {
                if hasActivity {
                    Divider().background(Color.white.opacity(0.08))
                    activitySection
                } else if !isActivityCollapsed {
                    Spacer()
                    emptyState
                }

                if !isActivityCollapsed {
                    Spacer()
                }

                if showIndicator && !isActivityCollapsed {
                    WorkingIndicatorView(state: state, workingVerb: currentSpinnerVerb)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var sharedUsageBar: some View {
        UsageBarView(
            usage: usageService.currentUsage,
            isUsingExtraUsage: usageService.isUsingExtraUsage,
            isLoading: usageService.isLoading,
            error: usageService.error,
            statusMessage: usageService.statusMessage,
            isStale: usageService.isUsageStale,
            recoveryAction: usageService.recoveryAction,
            compact: !shouldShowSessionPicker && isActivityCollapsed,
            onConnect: { ClaudeUsageService.shared.connectAndStartPolling() },
            onRetry: { ClaudeUsageService.shared.retryNow() }
        )
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isActivityCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        if let session = effectiveSession {
                            HStack(spacing: 6) {
                                ProviderBadgeView(provider: session.provider)
                                MorphingText(
                                    text: sessionStore.displaySessionLabel(for: session),
                                    font: .system(size: 11, weight: .medium),
                                    color: TerminalColors.secondaryText
                                )
                            }
                        }

                        Spacer()

                        if let mode = effectiveSession?.currentModeDisplay {
                            ModeBadgeView(mode: mode)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 0) {
                                if let prompt = effectiveSession?.lastUserPrompt {
                                    UserPromptBubbleView(text: prompt)
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
                                    QuestionPromptView(questions: questions)
                                        .id("question-prompt")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                        .onAppear {
                            if let lastItem = unifiedActivityItems.last {
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
                        .onChange(of: effectiveSession?.pendingQuestions.isEmpty) { _, isEmpty in
                            if isEmpty == false {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("question-prompt", anchor: .bottom)
                                }
                            }
                        }
                    }

                }
                .transition(.opacity)
            }
        }
    }

    private var emptyState: some View {
        let claudeHooksInstalled = HookInstaller.isInstalled()
        let hasCodexHome = FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/.codex")
        let title = (claudeHooksInstalled || hasCodexHome) ? "Waiting for activity" : "Claude hooks not installed"
        let subtitle: String
        if claudeHooksInstalled {
            subtitle = "Send a message in Claude Code or Codex to start tracking"
        } else if hasCodexHome {
            subtitle = "Send a message in Codex or install Claude hooks in Settings"
        } else {
            subtitle = "Open settings to set up Claude Code hooks or connect Codex"
        }

        return VStack(spacing: 8) {
            MorphingText(
                text: title,
                font: .system(size: 14, weight: .medium),
                color: TerminalColors.secondaryText,
                alignment: .center
            )
            MorphingText(
                text: subtitle,
                font: .system(size: 12),
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
}

struct ProviderBadgeView: View {
    let provider: SessionProvider

    private var accentColor: Color {
        switch provider {
        case .claude:
            return TerminalColors.claudeOrange
        case .codex:
            return TerminalColors.codexTeal
        }
    }

    var body: some View {
        Text(provider.displayName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(accentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(accentColor.opacity(0.15))
            .cornerRadius(4)
    }
}

struct PanelHeaderButton: View {
    let sfSymbol: String
    var showsIndicator: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: sfSymbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 32, height: 32)
                .background(isHovered ? TerminalColors.hoverBackground : TerminalColors.subtleBackground)
                .clipShape(Circle())
                .overlay(alignment: .topTrailing) {
                    if showsIndicator {
                        Circle()
                            .fill(TerminalColors.red)
                            .frame(width: 6, height: 6)
                            .offset(x: -6, y: 6)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct ModeBadgeView: View {
    let mode: String

    var color: Color {
        switch mode {
        case "Plan Mode": TerminalColors.planMode
        case "Accept Edits": TerminalColors.acceptEdits
        default: TerminalColors.secondaryText
        }
    }

    var body: some View {
        Text(mode)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(color)
    }
}
