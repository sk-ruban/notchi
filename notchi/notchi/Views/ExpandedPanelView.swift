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
    @Binding var showingSettings: Bool
    @Binding var showingSessionActivity: Bool
    @Binding var isActivityCollapsed: Bool

    private var effectiveSession: SessionData? {
        sessionStore.effectiveSession
    }

    private var state: NotchiState {
        effectiveSession?.state ?? .idle
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

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if !showingSettings {
                    if shouldShowSessionPicker {
                        sessionPickerContent(geometry: geometry)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    } else {
                        activityContent(geometry: geometry)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }

                if showingSettings {
                    PanelSettingsView()
                        .frame(width: geometry.size.width)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
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

                UsageBarView(
                    usage: usageService.currentUsage,
                    isLoading: usageService.isLoading,
                    error: usageService.error,
                    statusMessage: usageService.statusMessage,
                    isStale: usageService.isUsageStale,
                    recoveryAction: usageService.recoveryAction,
                    onConnect: { ClaudeUsageService.shared.connectAndStartPolling() },
                    onRetry: { ClaudeUsageService.shared.retryNow() }
                )
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 5)
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
                    WorkingIndicatorView(state: state)
                }

                UsageBarView(
                    usage: usageService.currentUsage,
                    isLoading: usageService.isLoading,
                    error: usageService.error,
                    statusMessage: usageService.statusMessage,
                    isStale: usageService.isUsageStale,
                    recoveryAction: usageService.recoveryAction,
                    compact: isActivityCollapsed,
                    onConnect: { ClaudeUsageService.shared.connectAndStartPolling() },
                    onRetry: { ClaudeUsageService.shared.retryNow() }
                )
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isActivityCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        if let session = effectiveSession {
                            HStack(spacing: 6) {
                                ProviderBadgeView(provider: session.provider)
                                Text("\(session.projectName) #\(session.sessionNumber)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(TerminalColors.secondaryText)
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
                                        AssistantTextRowView(message: message)
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
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(TerminalColors.secondaryText)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(TerminalColors.dimmedText)
        }
        .frame(maxWidth: .infinity)
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
