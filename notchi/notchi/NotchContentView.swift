import SwiftUI

enum NotchConstants {
    static let expandedPanelSize = CGSize(width: 450, height: 450)
    static let expandedPanelHorizontalPadding: CGFloat = 19 * 2
}

extension Notification.Name {
    static let notchiShouldCollapse = Notification.Name("notchiShouldCollapse")
    static let notchiQuestionOptionShortcut = Notification.Name("notchiQuestionOptionShortcut")
}

private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

private enum SpriteHandoffTiming {
    static let expandAnimationDuration = 0.2
    static let collapseAnimationDuration = 0.16
    static let cleanupBufferDuration = 0.02

    static func animationDuration(for expanded: Bool) -> Double {
        expanded ? expandAnimationDuration : collapseAnimationDuration
    }

    static func cleanupDelay(for expanded: Bool) -> Duration {
        let totalMilliseconds = Int(((animationDuration(for: expanded) + cleanupBufferDuration) * 1000).rounded())
        return .milliseconds(totalMilliseconds)
    }
}

private enum LaunchWaveTiming {
    static let startDelay = 1.0
    static let preparationDuration = 0.45
    static let spriteScale: CGFloat = 1.2
    static let horizontalOffset: CGFloat = 5
}

struct NotchContentView: View {
    private enum NotchSide {
        case left, right
    }

    private struct SpriteHandoff {
        enum Direction {
            case expanding
            case collapsing
        }

        let direction: Direction
        let sessionId: String
        let keepsGrassIslandRendered: Bool
    }

    struct LaunchWave: Equatable {
        let state: NotchiState
        let startedAt: Date
    }

    struct HeaderSpriteContent: Equatable {
        let state: NotchiState
        let mirrorSeed: String
        let startedAt: Date
        let repeatsAnimation: Bool
        let scale: CGFloat
        let xOffset: CGFloat

        init(
            state: NotchiState,
            mirrorSeed: String,
            startedAt: Date = SpriteAnimationPhase.sharedLoopAnchor,
            repeatsAnimation: Bool = true,
            scale: CGFloat = 1,
            xOffset: CGFloat = 0
        ) {
            self.state = state
            self.mirrorSeed = mirrorSeed
            self.startedAt = startedAt
            self.repeatsAnimation = repeatsAnimation
            self.scale = scale
            self.xOffset = xOffset
        }
    }

    var stateMachine: NotchiStateMachine = .shared
    var panelManager: NotchPanelManager = .shared
    var usageService: ClaudeUsageService = .shared
    var codexUsageService: CodexUsageService = .shared
    var haptics: HapticService = .shared
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @ObservedObject private var updateManager = UpdateManager.shared
    @AppStorage(AppSettings.notchLeftContentKey) private var leftContentRaw = NotchSlotContent.ring.rawValue
    @AppStorage(AppSettings.notchRightContentKey) private var rightContentRaw = NotchSlotContent.latest.rawValue
    @State private var showingPanelSettings = false
    @State private var showingPanelSettingsDetail = false
    @State private var showingUsageDetail = false
    @State private var showingSessionActivity = false
    @State private var isMuted = AppSettings.isMuted
    @State private var isActivityCollapsed = false
    @State private var hoveredSessionId: String?
    @State private var spriteHandoff: SpriteHandoff?
    @State private var spriteHandoffProgress: CGFloat = 0
    @State private var spriteHandoffGeneration = 0
    @State private var launchGlowVisible = false
    @State private var launchGlowProgress: Double = 0
    @State private var isLaunchWavePreparing = false
    @State private var launchWave: LaunchWave?
    @State private var launchSpriteFamily = AppSettings.lastUsedAgentProvider.spriteFamily
    @MainActor private static var hasPlayedLaunchGlow = false
    @MainActor private static var hasPlayedLaunchWave = false

    private var sessionStore: SessionStore {
        stateMachine.sessionStore
    }

    private var activeSession: SessionData? {
        sessionStore.effectiveSession
    }

    private var notchSize: CGSize { panelManager.notchSize }
    private var isExpanded: Bool { panelManager.isExpanded }
    private var collapsedMode: NotchPanelManager.CollapsedMode { panelManager.collapsedMode }
    private var isCompactIdle: Bool { !isExpanded && collapsedMode == .compactIdle }
    private var leftContent: NotchSlotContent {
        NotchSlotContent(rawValue: leftContentRaw) ?? .ring
    }

    private var rightContent: NotchSlotContent {
        NotchSlotContent(rawValue: rightContentRaw) ?? .latest
    }

    private func spriteContent(for content: NotchSlotContent, side: NotchSide) -> HeaderSpriteContent? {
        let excluded = (side == .left ? rightContent : leftContent).spriteProvider
        if let session = sessionForSprite(content, excluding: excluded) {
            return HeaderSpriteContent(state: session.state, mirrorSeed: session.id)
        }
        if let launchWave,
           contentAcceptsSprite(content, spriteFamily: launchWave.state.spriteFamily, excluding: excluded) {
            return HeaderSpriteContent(
                state: launchWave.state,
                mirrorSeed: "launch-wave-\(launchWave.state.spriteFamily.rawValue)",
                startedAt: launchWave.startedAt,
                repeatsAnimation: false,
                scale: LaunchWaveTiming.spriteScale,
                xOffset: LaunchWaveTiming.horizontalOffset
            )
        }
        return nil
    }

    private func sessionForSprite(_ content: NotchSlotContent, excluding excluded: AgentProvider?) -> SessionData? {
        switch content {
        case .claude: sessionStore.latestSession(for: .claude)
        case .codex: sessionStore.latestSession(for: .codex)
        case .latest: sessionStore.latestSession(excluding: excluded)
        case .nothing, .ring: nil
        }
    }

    private func contentAcceptsSprite(
        _ content: NotchSlotContent,
        spriteFamily: NotchiSpriteFamily,
        excluding excluded: AgentProvider?
    ) -> Bool {
        switch content {
        case .claude: spriteFamily == AgentProvider.claude.spriteFamily
        case .codex: spriteFamily == AgentProvider.codex.spriteFamily
        case .latest: spriteFamily != excluded?.spriteFamily
        case .nothing, .ring: false
        }
    }

    static func shouldRenderGrassIsland(
        isExpanded: Bool,
        showingPanelSettings: Bool,
        keepsGrassIslandRenderedForHandoff: Bool = false
    ) -> Bool {
        shouldShowGrassIsland(isExpanded: isExpanded, showingPanelSettings: showingPanelSettings)
            || keepsGrassIslandRenderedForHandoff
    }

    static func shouldShowGrassIsland(isExpanded: Bool, showingPanelSettings: Bool) -> Bool {
        isExpanded && !showingPanelSettings
    }

    private var shouldRenderGrassIsland: Bool {
        Self.shouldRenderGrassIsland(
            isExpanded: isExpanded,
            showingPanelSettings: showingPanelSettings,
            keepsGrassIslandRenderedForHandoff: spriteHandoff?.keepsGrassIslandRendered == true
        )
    }

    private var shouldShowGrassIsland: Bool {
        Self.shouldShowGrassIsland(isExpanded: isExpanded, showingPanelSettings: showingPanelSettings)
    }

    private var collapsedHoverHorizontalInset: CGFloat {
        !isExpanded && panelManager.isCollapsedHovered
            ? NotchPanelManager.collapsedHoverHorizontalInset
            : 0
    }

    private var collapsedHoverBottomInset: CGFloat {
        !isExpanded && panelManager.isCollapsedHovered
            ? NotchPanelManager.collapsedHoverBottomInset
            : 0
    }

    private var panelAnimation: Animation {
        isExpanded
            ? .spring(response: 0.5, dampingFraction: 0.78)
            : .spring(response: 0.36, dampingFraction: 0.88)
    }

    private var collapsedHoverAnimation: Animation {
        panelManager.isCollapsedHovered
            ? .spring(response: 0.36, dampingFraction: 0.74)
            : .spring(response: 0.28, dampingFraction: 0.96)
    }

    private var expandedChromeTransition: AnyTransition {
        .asymmetric(
            insertion: .offset(y: -12)
                .combined(with: .opacity)
                .animation(.easeOut(duration: 0.22).delay(0.08)),
            removal: .offset(y: -6)
                .combined(with: .opacity)
                .animation(.easeIn(duration: 0.12))
        )
    }

    private var expandedHeaderTransition: AnyTransition {
        .asymmetric(
            insertion: .offset(y: -8)
                .combined(with: .opacity)
                .animation(.easeOut(duration: 0.2).delay(0.12)),
            removal: .offset(y: -4)
                .combined(with: .opacity)
                .animation(.easeIn(duration: 0.1))
        )
    }

    private var collapsedHeaderSpriteVisibilityAnimation: Animation {
        isExpanded
            ? .easeOut(duration: 0.14).delay(0.05)
            : .easeOut(duration: 0.16)
    }

    private var collapsedHeaderSpriteScale: CGFloat {
        !isExpanded && panelManager.isCollapsedHovered ? 1.08 : 1
    }

    private var collapsedHeaderSpriteOffsetX: CGFloat {
        let baseOffset: CGFloat = 15
        guard !isExpanded && panelManager.isCollapsedHovered else { return baseOffset }
        return baseOffset + 6
    }

    private var collapsedHeaderSpriteOffsetY: CGFloat {
        let baseOffset: CGFloat = -2
        guard !isExpanded && panelManager.isCollapsedHovered else { return baseOffset }
        return baseOffset + 3
    }

    private func ringOffsetX(side: NotchSide) -> CGFloat {
        var magnitude = sideWidth / 4 + cornerRadiusInsets.closed.top
        if !isExpanded && panelManager.isCollapsedHovered {
            magnitude += 6
        }
        return side == .left ? -magnitude : magnitude
    }

    private func spriteOffsetX(side: NotchSide) -> CGFloat {
        side == .left ? -collapsedHeaderSpriteOffsetX : collapsedHeaderSpriteOffsetX
    }

    private var collapsedUsageRingOffsetY: CGFloat {
        !isExpanded && panelManager.isCollapsedHovered ? 2 : -1
    }

    private var isLaunchWaveActive: Bool {
        launchWave != nil || isLaunchWavePreparing
    }

    private var collapsedHeaderSpriteVisuals: (opacity: Double, blur: CGFloat) {
        guard let activeSession, let spriteHandoff, spriteHandoff.sessionId == activeSession.id else {
            return (opacity: isExpanded ? 0 : 1, blur: 0)
        }

        let isSource = spriteHandoff.direction == .expanding
        return (
            opacity: SpriteHandoffVisuals.opacity(for: spriteHandoffProgress, isSource: isSource),
            blur: SpriteHandoffVisuals.blur(for: spriteHandoffProgress, isSource: isSource)
        )
    }

    private var sideWidth: CGFloat {
        max(0, notchSize.height - 12) + 24
    }

    private var ringProvider: AgentProvider {
        activeSession?.provider ?? AppSettings.lastUsedAgentProvider
    }

    private var ringIsStale: Bool {
        ringProvider == .codex ? codexUsageService.isUsageStale : usageService.isUsageStale
    }

    private var usageRingPercentage: Int? {
        guard AppSettings.isUsageEnabled else { return nil }
        let usage = ringProvider == .codex ? codexUsageService.currentUsage : usageService.currentUsage
        return usage?.usagePercentage
    }

    private var compactContentWidth: CGFloat {
        max(0, panelManager.compactNotchRect.width - (cornerRadiusInsets.closed.bottom * 2))
    }

    private var topCornerRadius: CGFloat {
        isExpanded ? cornerRadiusInsets.opened.top : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        isExpanded ? cornerRadiusInsets.opened.bottom : cornerRadiusInsets.closed.bottom
    }

    /// Uses the system notch curve in collapsed mode when available.
    private var notchClipShape: AnyShape {
        if !isExpanded, let systemPath = panelManager.systemNotchPath {
            return AnyShape(SystemNotchShape(cgPath: systemPath))
        }
        return AnyShape(NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        ))
    }

    private var grassHeight: CGFloat {
        let expandedPanelHeight = NotchConstants.expandedPanelSize.height - notchSize.height - 24
        return expandedPanelHeight * 0.3 + notchSize.height
    }

    private var shouldShowBackButton: Bool {
        showingPanelSettings ||
        (showingUsageDetail && !isActivityCollapsed) ||
        (sessionStore.activeSessionCount >= 2 && showingSessionActivity)
    }

    private var expandedPanelHeight: CGFloat {
        let fullHeight = NotchConstants.expandedPanelSize.height - notchSize.height - 24
        let collapsedHeight: CGFloat = 155
        return isActivityCollapsed ? collapsedHeight : fullHeight
    }

    private var launchWavePreparationAnimation: Animation {
        .easeInOut(duration: LaunchWaveTiming.preparationDuration)
    }

    private var grassIslandOpacityAnimation: Animation {
        .easeOut(duration: SpriteHandoffTiming.collapseAnimationDuration)
    }

    var body: some View {
        VStack(spacing: 0) {
            notchLayout
        }
        .padding(
            .horizontal,
            isExpanded
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.bottom + collapsedHoverHorizontalInset
        )
        .padding(.bottom, isExpanded ? 12 : collapsedHoverBottomInset)
        .background {
            ZStack(alignment: .top) {
                Color.black
                if shouldRenderGrassIsland {
                    GrassIslandView(
                        sessions: sessionStore.sortedSessions,
                        selectedSessionId: sessionStore.selectedSessionId,
                        hoveredSessionId: hoveredSessionId,
                        handoffSessionId: spriteHandoff?.sessionId,
                        handoffProgress: spriteHandoffProgress,
                        isHandoffCollapsing: spriteHandoff?.direction == .collapsing
                    )
                    .frame(height: grassHeight, alignment: .bottom)
                    .opacity(shouldShowGrassIsland ? 1 : 0)
                    .animation(grassIslandOpacityAnimation, value: shouldShowGrassIsland)
                }
            }
        }
        .overlay(alignment: .top) {
            if shouldShowGrassIsland {
                GrassTapOverlay(
                    sessions: sessionStore.sortedSessions,
                    selectedSessionId: sessionStore.selectedSessionId,
                    hoveredSessionId: $hoveredSessionId,
                    handoffSessionId: spriteHandoff?.sessionId,
                    handoffProgress: spriteHandoffProgress,
                    isHandoffCollapsing: spriteHandoff?.direction == .collapsing,
                    onSelectSession: { sessionId in
                        selectGrassSession(sessionId)
                    }
                )
                .frame(height: grassHeight, alignment: .bottom)
            }
        }
        .overlay(alignment: .topTrailing) {
            if shouldShowGrassIsland {
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        isActivityCollapsed.toggle()
                    }
                }) {
                    Image(systemName: isActivityCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(8)
                }
                .buttonStyle(.plain)
                .offset(y: grassHeight - 30)
                .padding(.trailing, 30)
            }
        }
        .clipShape(notchClipShape)
        .overlay {
            if !isExpanded && launchGlowVisible {
                LaunchIridescentGlow(
                    progress: launchGlowProgress,
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius,
                    systemNotchPath: panelManager.systemNotchPath,
                    reduceMotion: accessibilityReduceMotion
                )
                .padding(-LaunchIridescentGlow.bleed)
            }
        }
        .shadow(
            color: isExpanded
                ? .black.opacity(0.7)
                : (panelManager.isCollapsedHovered ? .black.opacity(0.3) : .clear),
            radius: 6
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(panelAnimation, value: isExpanded)
        .animation(.easeInOut(duration: 0.18), value: collapsedMode)
        .animation(collapsedHoverAnimation, value: panelManager.isCollapsedHovered)
        .animation(launchWavePreparationAnimation, value: isLaunchWavePreparing)
        .onAppear(perform: startLaunchGlow)
        .task {
            await startLaunchWave()
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchiShouldCollapse)) { _ in
            if let activeSession, !activeSession.pendingQuestions.isEmpty {
                sessionStore.cancelPendingQuestion(in: activeSession.sessionKey)
                return
            }
            panelManager.collapse()
        }
        .onChange(of: isExpanded) { wasExpanded, expanded in
            startSpriteHandoff(
                for: expanded,
                keepsGrassIslandRendered: wasExpanded && !showingPanelSettings
            )
            updateKeyboardFocus(for: expanded)
            if !expanded {
                showingPanelSettings = false
                showingPanelSettingsDetail = false
                showingSessionActivity = false
                showingUsageDetail = false
                hoveredSessionId = nil
            }
        }
        .onChange(of: sessionStore.activeSessionCount) { _, count in
            if count < 2 {
                showingSessionActivity = false
            }
        }
    }

    @ViewBuilder
    private var notchLayout: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .center, spacing: 0) {
                headerRow
                    .frame(height: notchSize.height)

                if isExpanded {
                    ExpandedPanelView(
                        sessionStore: sessionStore,
                        usageService: usageService,
                        codexUsageService: CodexUsageService.shared,
                        showingSettings: $showingPanelSettings,
                        showingSettingsDetail: $showingPanelSettingsDetail,
                        showingSessionActivity: $showingSessionActivity,
                        showingUsageDetail: $showingUsageDetail,
                        isActivityCollapsed: $isActivityCollapsed,
                        hoveredSessionId: $hoveredSessionId
                    )
                    .frame(
                        width: NotchConstants.expandedPanelSize.width - 48,
                        height: expandedPanelHeight
                    )
                    .transition(expandedChromeTransition)
                }
            }

            if isExpanded {
                HStack {
                    if shouldShowBackButton {
                        backButton
                            .padding(.leading, 15)
                    } else {
                        HStack(spacing: 8) {
                            PanelHeaderButton(
                                sfSymbol: panelManager.isPinned ? "pin.fill" : "pin",
                                action: { panelManager.togglePin() }
                            )
                            PanelHeaderButton(
                                sfSymbol: isMuted ? "bell.slash" : "bell",
                                action: toggleMute
                            )
                        }
                        .padding(.leading, 12)
                    }
                    Spacer()
                    headerButtons
                }
                .padding(.top, 4)
                .padding(.horizontal, 8)
                .frame(width: NotchConstants.expandedPanelSize.width - 48)
                .transition(expandedHeaderTransition)
            }
        }
    }

    private var headerButtons: some View {
        HStack(spacing: 8) {
            if !showingPanelSettings {
                PanelHeaderButton(
                    sfSymbol: "gearshape",
                    showsIndicator: updateManager.hasPendingUpdate,
                    action: {
                        haptics.playNavigationTap()
                        showingPanelSettingsDetail = false
                        showingPanelSettings = true
                    }
                )
            } else {
                PanelHeaderButton(
                    sfSymbol: panelManager.isPinned ? "pin.fill" : "pin",
                    action: { panelManager.togglePin() }
                )
            }
            PanelHeaderButton(sfSymbol: "xmark", action: { panelManager.collapse() })
        }
        .padding(.trailing, 8)
    }

    private var backButton: some View {
        Button(action: goBack) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("Back")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.7))
        }
        .buttonStyle(.plain)
    }

    private func goBack() {
        if showingPanelSettings {
            if showingPanelSettingsDetail {
                showingPanelSettingsDetail = false
            } else {
                showingPanelSettings = false
            }
        } else if showingUsageDetail {
            showingUsageDetail = false
        } else if showingSessionActivity {
            showingSessionActivity = false
            sessionStore.clearSelectedSession()
        }
    }

    private func selectGrassSession(_ sessionId: String) {
        showingUsageDetail = false
        guard sessionStore.activeSessionCount >= 2 else { return }

        let shouldPlayHaptic = sessionStore.selectedSessionId != sessionId || !showingSessionActivity
        if shouldPlayHaptic {
            haptics.playSessionSelection()
        }

        if let session = sessionStore.selectSession(matchingStableId: sessionId) {
            TerminalJumpService.shared.jump(to: session)
        }
        showingSessionActivity = true
    }

    @ViewBuilder
    private var headerRow: some View {
        if isCompactIdle && launchWave == nil && !isLaunchWavePreparing {
            Color.clear
                .frame(width: compactContentWidth)
        } else {
            HStack(spacing: 0) {
                slotView(leftContent, side: .left)

                Color.clear
                    .frame(width: notchSize.width - cornerRadiusInsets.closed.top - sideWidth)

                slotView(rightContent, side: .right)
            }
        }
    }

    @ViewBuilder
    private func slotView(_ content: NotchSlotContent, side: NotchSide) -> some View {
        switch content {
        case .nothing:
            Color.clear.frame(width: sideWidth)
        case .ring:
            ringSlot(side: side)
        case .latest, .claude, .codex:
            spriteSlot(content: spriteContent(for: content, side: side), side: side)
        }
    }

    @ViewBuilder
    private func ringSlot(side: NotchSide) -> some View {
        if let usageRingPercentage, !isLaunchWaveActive {
            UsageRingView(percentage: usageRingPercentage, isStale: ringIsStale)
                .opacity(collapsedHeaderSpriteVisuals.opacity)
                .animation(collapsedHeaderSpriteVisibilityAnimation, value: isExpanded)
                .frame(width: sideWidth)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !isExpanded else { return }
                            isActivityCollapsed = false
                            showingUsageDetail = true
                            panelManager.expand()
                        }
                )
                .scaleEffect(collapsedHeaderSpriteScale, anchor: .bottom)
                .offset(x: ringOffsetX(side: side), y: collapsedUsageRingOffsetY)
        } else {
            Color.clear.frame(width: sideWidth)
        }
    }

    @ViewBuilder
    private func spriteSlot(content: HeaderSpriteContent?, side: NotchSide) -> some View {
        if let content {
            SessionSpriteView(
                state: content.state,
                isPrimarySprite: true,
                mirrorSeed: content.mirrorSeed,
                animationStartDate: content.startedAt,
                repeatsAnimation: content.repeatsAnimation
            )
            .scaleEffect(collapsedHeaderSpriteScale * content.scale, anchor: .bottom)
            .offset(x: content.xOffset)
            .offset(x: spriteOffsetX(side: side), y: collapsedHeaderSpriteOffsetY)
            .frame(width: sideWidth)
            .opacity(collapsedHeaderSpriteVisuals.opacity)
            .blur(radius: collapsedHeaderSpriteVisuals.blur)
            .animation(collapsedHeaderSpriteVisibilityAnimation, value: isExpanded)
        } else {
            Color.clear.frame(width: sideWidth)
        }
    }

    private func startSpriteHandoff(for expanded: Bool, keepsGrassIslandRendered: Bool) {
        spriteHandoffGeneration += 1
        let generation = spriteHandoffGeneration

        guard let activeSession else {
            spriteHandoff = nil
            spriteHandoffProgress = 0
            return
        }

        let animationDuration = SpriteHandoffTiming.animationDuration(for: expanded)

        spriteHandoff = SpriteHandoff(
            direction: expanded ? .expanding : .collapsing,
            sessionId: activeSession.id,
            keepsGrassIslandRendered: keepsGrassIslandRendered
        )
        spriteHandoffProgress = 0

        withAnimation(.easeOut(duration: animationDuration)) {
            spriteHandoffProgress = 1
        }

        Task { @MainActor in
            try? await Task.sleep(for: SpriteHandoffTiming.cleanupDelay(for: expanded))
            guard generation == spriteHandoffGeneration else { return }
            spriteHandoff = nil
            spriteHandoffProgress = 0
        }
    }

    private func updateKeyboardFocus(for expanded: Bool) {
        guard expanded,
              let panel = NSApp.windows.first(where: { $0 is NotchPanel }) else { return }
        panel.makeKey()
    }

    private func startLaunchGlow() {
        guard !Self.hasPlayedLaunchGlow else { return }
        Self.hasPlayedLaunchGlow = true

        guard !accessibilityReduceMotion else { return }

        let duration = LaunchIridescentGlowTiming.duration(reduceMotion: accessibilityReduceMotion)
        launchGlowProgress = 0
        launchGlowVisible = true

        Task {
            // Commit the hidden 0 state before animating so the glow blooms from nothing.
            await Task.yield()
            withAnimation(.linear(duration: duration)) {
                launchGlowProgress = 1
            }

            try? await Task.sleep(for: .seconds(duration))
            launchGlowVisible = false
        }
    }

    private func startLaunchWave() async {
        guard !Self.hasPlayedLaunchWave else { return }

        let provider = AppSettings.lastUsedAgentProvider
        launchSpriteFamily = provider.spriteFamily

        isLaunchWavePreparing = true

        try? await Task.sleep(for: .seconds(LaunchWaveTiming.startDelay))

        guard !Task.isCancelled, !Self.hasPlayedLaunchWave else {
            isLaunchWavePreparing = false
            return
        }

        Self.hasPlayedLaunchWave = true
        isLaunchWavePreparing = false
        launchWave = LaunchWave(
            state: NotchiState(task: .waving, spriteFamily: provider.spriteFamily),
            startedAt: Date()
        )

        try? await Task.sleep(for: .seconds(NotchiState.launchWaveDuration))

        guard !Task.isCancelled else {
            launchWave = nil
            return
        }

        withAnimation(launchWavePreparationAnimation) {
            launchWave = nil
        }
    }

    private func toggleMute() {
        haptics.playToggle()
        AppSettings.toggleMute()
        isMuted = AppSettings.isMuted
    }
}

#Preview {
    NotchContentView()
        .frame(width: 400, height: 200)
}
