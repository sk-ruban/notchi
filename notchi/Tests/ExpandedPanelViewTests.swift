import XCTest
@testable import notchi

@MainActor
final class ExpandedPanelViewTests: XCTestCase {
    func testSharedUsageBarStaysVisibleWithActiveSessionsOrNoContextSession() {
        let claude = SessionData(sessionId: "claude-session", provider: .claude, cwd: "/tmp/project")
        let codex = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")

        XCTAssertTrue(
            ExpandedPanelView.shouldShowSharedUsageBar(
                contextSession: codex,
                activeSessions: [codex, claude]
            )
        )
        XCTAssertTrue(
            ExpandedPanelView.shouldShowSharedUsageBar(
                contextSession: codex,
                activeSessions: [codex]
            )
        )
        XCTAssertTrue(
            ExpandedPanelView.shouldShowSharedUsageBar(
                contextSession: nil,
                activeSessions: []
            )
        )
    }

    func testSharedUsageBarHidesWhenContextSessionLingersWithoutActiveSessions() {
        let codex = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")

        XCTAssertFalse(
            ExpandedPanelView.shouldShowSharedUsageBar(
                contextSession: codex,
                activeSessions: []
            )
        )
    }

    func testNoActiveSessionsUseNeutralUsageState() {
        let state = SharedUsageBarState.noActiveSession

        XCTAssertEqual(state.label, "Start a session to track usage")
        XCTAssertFalse(state.isProviderSpecific)
        XCTAssertNil(state.usage)
        XCTAssertFalse(ExpandedPanelView.includesClaudeUsage(activeSessions: []))
        XCTAssertFalse(ExpandedPanelView.includesCodexUsage(activeSessions: []))
    }

    func testActiveSessionsIncludeOnlyPresentUsageProviders() {
        let claude = SessionData(sessionId: "claude-session", provider: .claude, cwd: "/tmp/project")
        let codex = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")

        XCTAssertTrue(ExpandedPanelView.includesClaudeUsage(activeSessions: [claude]))
        XCTAssertFalse(ExpandedPanelView.includesCodexUsage(activeSessions: [claude]))

        XCTAssertFalse(ExpandedPanelView.includesClaudeUsage(activeSessions: [codex]))
        XCTAssertTrue(ExpandedPanelView.includesCodexUsage(activeSessions: [codex]))
    }

    func testSelectedCodexSessionShowsCodexUsageEvenWhenClaudeUsageIsNewer() {
        let codexSession = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")
        let claude = makeUsageState(provider: .claude, usage: 42, observedAt: Date(timeIntervalSince1970: 200))
        let codex = makeUsageState(provider: .codex, usage: 11, observedAt: Date(timeIntervalSince1970: 100))

        let state = ExpandedPanelView.sharedUsageBarState(
            contextSession: codexSession,
            claude: claude,
            codex: codex
        )

        XCTAssertEqual(state?.provider, .codex)
        XCTAssertEqual(state?.usage?.usagePercentage, 11)
    }

    func testSelectedClaudeSessionShowsClaudeUsageEvenWhenCodexUsageIsNewer() {
        let claudeSession = SessionData(sessionId: "claude-session", provider: .claude, cwd: "/tmp/project")
        let claude = makeUsageState(provider: .claude, usage: 42, observedAt: Date(timeIntervalSince1970: 100))
        let codex = makeUsageState(provider: .codex, usage: 11, observedAt: Date(timeIntervalSince1970: 200))

        let state = ExpandedPanelView.sharedUsageBarState(
            contextSession: claudeSession,
            claude: claude,
            codex: codex
        )

        XCTAssertEqual(state?.provider, .claude)
        XCTAssertEqual(state?.usage?.usagePercentage, 42)
    }

    func testNoSelectedSessionUsesMostRecentlyObservedUsage() {
        let claude = makeUsageState(provider: .claude, usage: 42, observedAt: Date(timeIntervalSince1970: 100))
        let codex = makeUsageState(provider: .codex, usage: 11, observedAt: Date(timeIntervalSince1970: 200))

        let state = ExpandedPanelView.sharedUsageBarState(
            contextSession: nil,
            claude: claude,
            codex: codex
        )

        XCTAssertEqual(state?.provider, .codex)
        XCTAssertEqual(state?.usage?.usagePercentage, 11)
    }

    func testHoveredSessionProviderDrivesUsageState() {
        let hoveredCodexSession = SessionData(sessionId: "hovered-codex-session", provider: .codex, cwd: "/tmp/project")
        let claude = makeUsageState(provider: .claude, usage: 42, observedAt: Date(timeIntervalSince1970: 200))
        let codex = makeUsageState(provider: .codex, usage: 11, observedAt: Date(timeIntervalSince1970: 100))

        let state = ExpandedPanelView.sharedUsageBarState(
            contextSession: hoveredCodexSession,
            claude: claude,
            codex: codex
        )

        XCTAssertEqual(state?.provider, .codex)
        XCTAssertEqual(state?.usage?.usagePercentage, 11)
    }

    func testMixedProviderSessionsAreDetectedForUsageLabel() {
        let claude = SessionData(sessionId: "claude-session", provider: .claude, cwd: "/tmp/project")
        let codex = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")

        XCTAssertTrue(ExpandedPanelView.hasMixedClaudeAndCodexSessions([claude, codex]))
        XCTAssertFalse(ExpandedPanelView.hasMixedClaudeAndCodexSessions([claude]))
        XCTAssertFalse(ExpandedPanelView.hasMixedClaudeAndCodexSessions([codex]))
    }

    func testCodexQuestionPromptShowsDirectReplyHint() {
        let claude = SessionData(sessionId: "claude-question-session", provider: .claude, cwd: "/tmp/project")
        let codex = SessionData(sessionId: "codex-question-session", provider: .codex, cwd: "/tmp/project")

        XCTAssertNil(ExpandedPanelView.questionResponseHint(for: claude))
        XCTAssertEqual(
            ExpandedPanelView.questionResponseHint(for: codex),
            "Reply directly in the Codex app or CLI"
        )
    }

    func testMixedProviderSessionsUseSelectedProviderResetLabelPrefix() {
        let claudeSession = SessionData(sessionId: "claude-session", provider: .claude, cwd: "/tmp/project")
        let codexSession = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")
        let codex = makeUsageState(provider: .codex, usage: 11, observedAt: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(
            ExpandedPanelView.sharedUsageResetLabelPrefix(
                state: codex,
                activeSessions: [codexSession, claudeSession]
            ),
            "Codex"
        )
    }

    func testSingleProviderSessionsDoNotUseResetLabelPrefix() {
        let codexSession = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")
        let codex = makeUsageState(provider: .codex, usage: 11, observedAt: Date(timeIntervalSince1970: 100))

        XCTAssertNil(
            ExpandedPanelView.sharedUsageResetLabelPrefix(
                state: codex,
                activeSessions: [codexSession]
            )
        )
    }

    func testUsageDetailOpensOnContextSessionProviderRegardlessOfLastUsed() {
        let codexSession = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")

        let provider = ExpandedPanelView.usageDetailDefaultProvider(
            requestedProvider: nil,
            contextSession: codexSession,
            lastUsedProvider: .claude,
            claudeHasData: true,
            codexHasData: true
        )

        XCTAssertEqual(provider, .codex)
    }

    func testUsageDetailOpensOnRequestedProviderOverContextSession() {
        let codexSession = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")

        let provider = ExpandedPanelView.usageDetailDefaultProvider(
            requestedProvider: .claude,
            contextSession: codexSession,
            lastUsedProvider: .codex,
            claudeHasData: true,
            codexHasData: true
        )

        XCTAssertEqual(provider, .claude)
    }

    func testUsageDetailOpensOnLastUsedProviderWhenIdleAndItHasData() {
        let provider = ExpandedPanelView.usageDetailDefaultProvider(
            requestedProvider: nil,
            contextSession: nil,
            lastUsedProvider: .codex,
            claudeHasData: true,
            codexHasData: true
        )

        XCTAssertEqual(provider, .codex)
    }

    func testUsageDetailPrefersProviderWithDataOverLastUsedWithoutData() {
        let provider = ExpandedPanelView.usageDetailDefaultProvider(
            requestedProvider: nil,
            contextSession: nil,
            lastUsedProvider: .codex,
            claudeHasData: true,
            codexHasData: false
        )

        XCTAssertEqual(provider, .claude)
    }

    func testUsageDetailPrefersCodexWithDataOverLastUsedClaudeWithoutData() {
        let provider = ExpandedPanelView.usageDetailDefaultProvider(
            requestedProvider: nil,
            contextSession: nil,
            lastUsedProvider: .claude,
            claudeHasData: false,
            codexHasData: true
        )

        XCTAssertEqual(provider, .codex)
    }

    func testUsageDetailOpensOnLastUsedProviderWhenIdleWithNoDataAnywhere() {
        let provider = ExpandedPanelView.usageDetailDefaultProvider(
            requestedProvider: nil,
            contextSession: nil,
            lastUsedProvider: .codex,
            claudeHasData: false,
            codexHasData: false
        )

        XCTAssertEqual(provider, .codex)
    }

    func testCodexUsageBarIgnoresClaudeUsageSetting() {
        XCTAssertTrue(ExpandedPanelView.sharedUsageBarIsEnabled(provider: .codex, appUsageEnabled: false))
        XCTAssertFalse(ExpandedPanelView.sharedUsageBarIsEnabled(provider: .claude, appUsageEnabled: false))
        XCTAssertTrue(ExpandedPanelView.sharedUsageBarIsEnabled(provider: .claude, appUsageEnabled: true))
    }

    private func makeUsageState(
        provider: AgentProvider,
        usage: Double,
        observedAt: Date
    ) -> SharedUsageBarState {
        SharedUsageBarState(
            provider: provider,
            usage: QuotaPeriod(utilization: usage, resetDate: Date(timeIntervalSince1970: 1_000)),
            isUsingExtraUsage: false,
            isLoading: false,
            error: nil,
            statusMessage: nil,
            isStale: false,
            recoveryAction: .none,
            lastObservedAt: observedAt
        )
    }
}
