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

    func testSelectedDevinSessionShowsDevinUsage() {
        let devinSession = SessionData(sessionId: "devin-session", provider: .devin, cwd: "/tmp/project")
        let claude = makeUsageState(provider: .claude, usage: 42, observedAt: Date(timeIntervalSince1970: 200))
        let devin = makeUsageState(provider: .devin, usage: 7, observedAt: Date(timeIntervalSince1970: 100))

        let state = ExpandedPanelView.sharedUsageBarState(
            contextSession: devinSession,
            claude: claude,
            codex: nil,
            devin: devin,
            lastUsedProvider: .claude
        )

        XCTAssertEqual(state?.provider, .devin)
        XCTAssertEqual(state?.usage?.usagePercentage, 7)
    }

    func testNoSelectedSessionIgnoresDevinsMoreFrequentRefresh() {
        let claude = makeUsageState(provider: .claude, usage: 42, observedAt: Date(timeIntervalSince1970: 100))
        let devinRefreshedLater = makeUsageState(provider: .devin, usage: 7, observedAt: Date(timeIntervalSince1970: 200))

        let state = ExpandedPanelView.sharedUsageBarState(
            contextSession: nil,
            claude: claude,
            codex: nil,
            devin: devinRefreshedLater,
            lastUsedProvider: .claude
        )

        XCTAssertEqual(state?.provider, .claude)
        XCTAssertEqual(state?.usage?.usagePercentage, 42)
    }

    func testNoSelectedSessionUsesLastUsedProviderEvenWhenAnotherIsNewer() {
        let claude = makeUsageState(provider: .claude, usage: 42, observedAt: Date(timeIntervalSince1970: 100))
        let codex = makeUsageState(provider: .codex, usage: 11, observedAt: Date(timeIntervalSince1970: 200))

        let state = ExpandedPanelView.sharedUsageBarState(
            contextSession: nil,
            claude: claude,
            codex: codex,
            lastUsedProvider: .claude
        )

        XCTAssertEqual(state?.provider, .claude)
        XCTAssertEqual(state?.usage?.usagePercentage, 42)
    }

    func testContextSessionProviderIsNeverSwappedEvenWhenItHasNoData() {
        let codexSession = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")
        let claude = makeUsageState(provider: .claude, usage: 42, observedAt: Date(timeIntervalSince1970: 100))
        let codexWithoutData = makeUsageState(provider: .codex, usage: nil, observedAt: Date(timeIntervalSince1970: 200))

        let state = ExpandedPanelView.sharedUsageBarState(
            contextSession: codexSession,
            claude: claude,
            codex: codexWithoutData
        )

        XCTAssertEqual(state?.provider, .codex)
        XCTAssertNil(state?.usage)
    }

    func testContextSessionProviderWinsWhenNeitherProviderHasDataForSelectedPeriod() {
        let codexSession = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")
        let claude = makeUsageState(provider: .claude, usage: nil, observedAt: Date(timeIntervalSince1970: 100))
        let codex = makeUsageState(provider: .codex, usage: nil, observedAt: Date(timeIntervalSince1970: 200))

        let state = ExpandedPanelView.sharedUsageBarState(
            contextSession: codexSession,
            claude: claude,
            codex: codex
        )

        XCTAssertEqual(state?.provider, .codex)
        XCTAssertNil(state?.usage)
    }

    func testLastUsedProviderFallsBackWhenItHasNoDataForSelectedPeriod() {
        let claude = makeUsageState(provider: .claude, usage: 42, observedAt: Date(timeIntervalSince1970: 100))
        let codexLastUsedButWithoutDataForPeriod = makeUsageState(
            provider: .codex, usage: nil, observedAt: Date(timeIntervalSince1970: 200)
        )

        let state = ExpandedPanelView.sharedUsageBarState(
            contextSession: nil,
            claude: claude,
            codex: codexLastUsedButWithoutDataForPeriod,
            lastUsedProvider: .codex
        )

        XCTAssertEqual(state?.provider, .claude)
        XCTAssertEqual(state?.usage?.usagePercentage, 42)
    }

    func testFallbackDoesNotOverrideAPreferredProviderThatIsStillLoading() {
        let claudeSession = SessionData(sessionId: "claude-session", provider: .claude, cwd: "/tmp/project")
        let claudeLoading = makeUsageState(provider: .claude, usage: nil, observedAt: Date(timeIntervalSince1970: 100), isLoading: true)
        let codex = makeUsageState(provider: .codex, usage: 11, observedAt: Date(timeIntervalSince1970: 200))

        let state = ExpandedPanelView.sharedUsageBarState(
            contextSession: claudeSession,
            claude: claudeLoading,
            codex: codex
        )

        XCTAssertEqual(state?.provider, .claude)
        XCTAssertTrue(state?.isLoading ?? false)
    }

    func testFallbackDoesNotOverrideAPreferredProviderShowingAnError() {
        let claudeSession = SessionData(sessionId: "claude-session", provider: .claude, cwd: "/tmp/project")
        let claudeErrored = makeUsageState(
            provider: .claude, usage: nil, observedAt: Date(timeIntervalSince1970: 100), error: "Connection failed"
        )
        let codex = makeUsageState(provider: .codex, usage: 11, observedAt: Date(timeIntervalSince1970: 200))

        let state = ExpandedPanelView.sharedUsageBarState(
            contextSession: claudeSession,
            claude: claudeErrored,
            codex: codex
        )

        XCTAssertEqual(state?.provider, .claude)
        XCTAssertEqual(state?.error, "Connection failed")
    }

    func testFallbackDoesNotOverrideADisabledClaudeProvider() {
        let claudeSession = SessionData(sessionId: "claude-session", provider: .claude, cwd: "/tmp/project")
        let claudeDisabled = makeUsageState(provider: .claude, usage: nil, observedAt: Date(timeIntervalSince1970: 100))
        let codex = makeUsageState(provider: .codex, usage: 11, observedAt: Date(timeIntervalSince1970: 200))

        let state = ExpandedPanelView.sharedUsageBarState(
            contextSession: claudeSession,
            claude: claudeDisabled,
            codex: codex,
            claudeUsageEnabled: false
        )

        XCTAssertEqual(state?.provider, .claude)
        XCTAssertNil(state?.usage)
    }

    func testFallbackDoesNotOverrideAPreferredProviderWithAStatusMessage() {
        let claudeSession = SessionData(sessionId: "claude-session", provider: .claude, cwd: "/tmp/project")
        let claudeUpdating = makeUsageState(
            provider: .claude, usage: nil, observedAt: Date(timeIntervalSince1970: 100), statusMessage: "Updating in 30s"
        )
        let codex = makeUsageState(provider: .codex, usage: 11, observedAt: Date(timeIntervalSince1970: 200))

        let state = ExpandedPanelView.sharedUsageBarState(
            contextSession: claudeSession,
            claude: claudeUpdating,
            codex: codex,
            claudeUsageEnabled: true
        )

        XCTAssertEqual(state?.provider, .claude)
        XCTAssertEqual(state?.statusMessage, "Updating in 30s")
    }

    func testFallbackDoesNotOverrideAPreferredProviderWithARecoveryAction() {
        let claudeSession = SessionData(sessionId: "claude-session", provider: .claude, cwd: "/tmp/project")
        let claudeNeedsReconnect = makeUsageState(
            provider: .claude, usage: nil, observedAt: Date(timeIntervalSince1970: 100), recoveryAction: .reconnect
        )
        let codex = makeUsageState(provider: .codex, usage: 11, observedAt: Date(timeIntervalSince1970: 200))

        let state = ExpandedPanelView.sharedUsageBarState(
            contextSession: claudeSession,
            claude: claudeNeedsReconnect,
            codex: codex,
            claudeUsageEnabled: true
        )

        XCTAssertEqual(state?.provider, .claude)
        XCTAssertEqual(state?.recoveryAction, .reconnect)
    }

    func testFallbackDoesNotOverrideADisabledClaudeProviderWithoutContextSession() {
        let sharedTimestamp = Date(timeIntervalSince1970: 100)
        let claudeDisabled = makeUsageState(provider: .claude, usage: nil, observedAt: sharedTimestamp)
        let codex = makeUsageState(provider: .codex, usage: 11, observedAt: sharedTimestamp)

        let state = ExpandedPanelView.sharedUsageBarState(
            contextSession: nil,
            claude: claudeDisabled,
            codex: codex,
            lastUsedProvider: .claude,
            claudeUsageEnabled: false
        )

        XCTAssertEqual(state?.provider, .claude)
        XCTAssertNil(state?.usage)
    }

    func testEffectivePeriodFallsBackToSessionWhenWeeklyQuotaMissing() {
        let session = QuotaPeriod(utilization: 10, resetDate: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(
            ExpandedPanelView.effectiveMainUsagePeriod(for: .weekly, sessionUsage: session, weeklyUsage: nil),
            .session
        )
    }

    func testEffectivePeriodFallsBackToWeeklyWhenSessionQuotaMissing() {
        let weekly = QuotaPeriod(utilization: 20, resetDate: Date(timeIntervalSince1970: 2_000))

        XCTAssertEqual(
            ExpandedPanelView.effectiveMainUsagePeriod(for: .session, sessionUsage: nil, weeklyUsage: weekly),
            .weekly
        )
    }

    func testEffectivePeriodKeepsWeeklyWhenWeeklyQuotaPresent() {
        let session = QuotaPeriod(utilization: 10, resetDate: Date(timeIntervalSince1970: 1_000))
        let weekly = QuotaPeriod(utilization: 20, resetDate: Date(timeIntervalSince1970: 2_000))

        XCTAssertEqual(
            ExpandedPanelView.effectiveMainUsagePeriod(for: .weekly, sessionUsage: session, weeklyUsage: weekly),
            .weekly
        )
    }

    func testEffectivePeriodKeepsSelectionWhenNoQuotaAvailable() {
        XCTAssertEqual(
            ExpandedPanelView.effectiveMainUsagePeriod(for: .weekly, sessionUsage: nil, weeklyUsage: nil),
            .weekly
        )
        XCTAssertEqual(
            ExpandedPanelView.effectiveMainUsagePeriod(for: .session, sessionUsage: nil, weeklyUsage: nil),
            .session
        )
    }

    func testMainUsageBarPeriodDecodingFallsBackToSession() {
        XCTAssertEqual(AppSettings.mainUsageBarPeriod(fromRaw: nil), .session)
        XCTAssertEqual(AppSettings.mainUsageBarPeriod(fromRaw: "garbage"), .session)
        XCTAssertEqual(AppSettings.mainUsageBarPeriod(fromRaw: "weekly"), .weekly)
        XCTAssertEqual(AppSettings.mainUsageBarPeriod(fromRaw: "session"), .session)
    }

    func testMainUsageIsStaleUsesHeldOverStateOnlyForWeeklyPeriod() {
        XCTAssertFalse(ExpandedPanelView.mainUsageIsStale(for: .session, isUsageStale: false, isWeeklyUsageHeldOver: true))
        XCTAssertTrue(ExpandedPanelView.mainUsageIsStale(for: .weekly, isUsageStale: false, isWeeklyUsageHeldOver: true))
        XCTAssertTrue(ExpandedPanelView.mainUsageIsStale(for: .session, isUsageStale: true, isWeeklyUsageHeldOver: true))
        XCTAssertFalse(ExpandedPanelView.mainUsageIsStale(for: .weekly, isUsageStale: false, isWeeklyUsageHeldOver: false))
    }

    func testExtraUsageIndicatorOnlyAppliesToTheSessionPeriod() {
        XCTAssertTrue(ExpandedPanelView.mainUsageIsUsingExtraUsage(for: .session, isUsingExtraUsage: true))
        XCTAssertFalse(ExpandedPanelView.mainUsageIsUsingExtraUsage(for: .weekly, isUsingExtraUsage: true))
        XCTAssertFalse(ExpandedPanelView.mainUsageIsUsingExtraUsage(for: .session, isUsingExtraUsage: false))
        XCTAssertFalse(ExpandedPanelView.mainUsageIsUsingExtraUsage(for: .weekly, isUsingExtraUsage: false))
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

        let devin = SessionData(sessionId: "devin-session", provider: .devin, cwd: "/tmp/project")

        XCTAssertTrue(ExpandedPanelView.hasMixedProviderSessions([claude, codex]))
        XCTAssertTrue(ExpandedPanelView.hasMixedProviderSessions([codex, devin]))
        XCTAssertFalse(ExpandedPanelView.hasMixedProviderSessions([claude]))
        XCTAssertFalse(ExpandedPanelView.hasMixedProviderSessions([devin, devin]))
    }

    func testDevinSessionPeriodIsLabelledDaily() {
        let devinSession = SessionData(sessionId: "devin-session", provider: .devin, cwd: "/tmp/project")
        let devin = makeUsageState(provider: .devin, usage: 7, observedAt: Date(timeIntervalSince1970: 100), period: .session)

        XCTAssertEqual(
            ExpandedPanelView.sharedUsageResetLabelPrefix(
                state: devin,
                activeSessions: [devinSession],
                requestedPeriod: .weekly
            ),
            "Daily"
        )
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
                activeSessions: [codexSession, claudeSession],
                requestedPeriod: .session
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
                activeSessions: [codexSession],
                requestedPeriod: .session
            )
        )
    }

    func testWeeklyStateAddsPrefixEvenForSingleProviderSessions() {
        let codexSession = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")
        let codex = makeUsageState(provider: .codex, usage: 11, observedAt: Date(timeIntervalSince1970: 100), period: .weekly)

        XCTAssertEqual(
            ExpandedPanelView.sharedUsageResetLabelPrefix(
                state: codex,
                activeSessions: [codexSession],
                requestedPeriod: .weekly
            ),
            "Weekly"
        )
    }

    func testWeeklyStateCombinesWithProviderPrefixForMixedSessions() {
        let claudeSession = SessionData(sessionId: "claude-session", provider: .claude, cwd: "/tmp/project")
        let codexSession = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")
        let codex = makeUsageState(provider: .codex, usage: 11, observedAt: Date(timeIntervalSince1970: 100), period: .weekly)

        XCTAssertEqual(
            ExpandedPanelView.sharedUsageResetLabelPrefix(
                state: codex,
                activeSessions: [codexSession, claudeSession],
                requestedPeriod: .weekly
            ),
            "Codex weekly"
        )
    }

    func testWeeklySelectionFallingBackToSessionLabelsThePeriod() {
        let codexSession = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")
        let codex = makeUsageState(provider: .codex, usage: 11, observedAt: Date(timeIntervalSince1970: 100), period: .session)

        XCTAssertEqual(
            ExpandedPanelView.sharedUsageResetLabelPrefix(
                state: codex,
                activeSessions: [codexSession],
                requestedPeriod: .weekly
            ),
            "Session"
        )
    }

    func testSessionSelectionFallingBackToWeeklyStillLabelsWeekly() {
        let codexSession = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")
        let codex = makeUsageState(provider: .codex, usage: 11, observedAt: Date(timeIntervalSince1970: 100), period: .weekly)

        XCTAssertEqual(
            ExpandedPanelView.sharedUsageResetLabelPrefix(
                state: codex,
                activeSessions: [codexSession],
                requestedPeriod: .session
            ),
            "Weekly"
        )
    }

    func testMainUsageSelectsSessionQuotaForSessionPeriod() {
        let session = QuotaPeriod(utilization: 10, resetDate: Date(timeIntervalSince1970: 1_000))
        let weekly = QuotaPeriod(utilization: 20, resetDate: Date(timeIntervalSince1970: 2_000))

        let usage = ExpandedPanelView.mainUsage(for: .session, sessionUsage: session, weeklyUsage: weekly)

        XCTAssertEqual(usage?.usagePercentage, 10)
    }

    func testMainUsageSelectsWeeklyQuotaForWeeklyPeriod() {
        let session = QuotaPeriod(utilization: 10, resetDate: Date(timeIntervalSince1970: 1_000))
        let weekly = QuotaPeriod(utilization: 20, resetDate: Date(timeIntervalSince1970: 2_000))

        let usage = ExpandedPanelView.mainUsage(for: .weekly, sessionUsage: session, weeklyUsage: weekly)

        XCTAssertEqual(usage?.usagePercentage, 20)
    }

    func testMainUsageReturnsNilWhenSelectedPeriodHasNoData() {
        let weekly = QuotaPeriod(utilization: 20, resetDate: Date(timeIntervalSince1970: 2_000))

        XCTAssertNil(ExpandedPanelView.mainUsage(for: .session, sessionUsage: nil, weeklyUsage: weekly))
        XCTAssertNil(ExpandedPanelView.mainUsage(for: .weekly, sessionUsage: weekly, weeklyUsage: nil))
    }

    func testUsageDetailOpensOnContextSessionProviderRegardlessOfLastUsed() {
        let codexSession = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")

        let provider = ExpandedPanelView.usageDetailDefaultProvider(
            requestedProvider: nil,
            contextSession: codexSession,
            lastUsedProvider: .claude
        )

        XCTAssertEqual(provider, .codex)
    }

    func testUsageDetailOpensOnRequestedProviderOverContextSession() {
        let codexSession = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")

        let provider = ExpandedPanelView.usageDetailDefaultProvider(
            requestedProvider: .claude,
            contextSession: codexSession,
            lastUsedProvider: .codex
        )

        XCTAssertEqual(provider, .claude)
    }

    func testUsageDetailOpensOnDevinContextSession() {
        let devinSession = SessionData(sessionId: "devin-session", provider: .devin, cwd: "/tmp/project")

        let provider = ExpandedPanelView.usageDetailDefaultProvider(
            requestedProvider: nil,
            contextSession: devinSession,
            lastUsedProvider: .codex
        )

        XCTAssertEqual(provider, .devin)
    }

    func testUsageDetailOpensOnLastUsedProviderWhenIdle() {
        let provider = ExpandedPanelView.usageDetailDefaultProvider(
            requestedProvider: nil,
            contextSession: nil,
            lastUsedProvider: .codex
        )

        XCTAssertEqual(provider, .codex)
    }

    func testCodexUsageBarIgnoresClaudeUsageSetting() {
        XCTAssertTrue(ExpandedPanelView.sharedUsageBarIsEnabled(provider: .codex, appUsageEnabled: false))
        XCTAssertFalse(ExpandedPanelView.sharedUsageBarIsEnabled(provider: .claude, appUsageEnabled: false))
        XCTAssertTrue(ExpandedPanelView.sharedUsageBarIsEnabled(provider: .claude, appUsageEnabled: true))
        XCTAssertTrue(ExpandedPanelView.sharedUsageBarIsEnabled(provider: .devin, appUsageEnabled: false))
    }

    private func makeUsageState(
        provider: AgentProvider,
        usage: Double?,
        observedAt: Date,
        isLoading: Bool = false,
        error: String? = nil,
        statusMessage: String? = nil,
        recoveryAction: ClaudeUsageRecoveryAction = .none,
        period: MainUsageBarPeriod = .session
    ) -> SharedUsageBarState {
        SharedUsageBarState(
            provider: provider,
            usage: usage.map { QuotaPeriod(utilization: $0, resetDate: Date(timeIntervalSince1970: 1_000)) },
            isUsingExtraUsage: false,
            isLoading: isLoading,
            error: error,
            statusMessage: statusMessage,
            isStale: false,
            recoveryAction: recoveryAction,
            lastObservedAt: observedAt,
            period: period
        )
    }
}
