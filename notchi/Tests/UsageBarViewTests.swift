import XCTest
@testable import notchi

final class UsageBarViewTests: XCTestCase {
    func testUnlimitedLabelRequiresExplicitFlagAndNoQuota() {
        let quota = QuotaPeriod(utilization: 42, resetDate: Date(timeIntervalSinceNow: 3_600))
        for (usage, unlimited, expected) in [(nil, true, true), (quota, true, false), (quota, false, false), (nil, false, false)] as [(QuotaPeriod?, Bool, Bool)] {
            let view = UsageBarView(
                usage: usage, hasUnlimitedCredits: unlimited, isLoading: false,
                error: nil, statusMessage: nil, isStale: false, recoveryAction: .none
            )
            XCTAssertEqual(view.showsUnlimitedCredits, expected)
            if usage != nil { XCTAssertEqual(view.barFillPercentage, 42) }
        }
    }

    func testPlaceholderShowsOnlyWhenTrulyDisconnected() {
        let view = UsageBarView(
            usage: nil,
            isLoading: false,
            error: nil,
            statusMessage: nil,
            isStale: false,
            recoveryAction: .none,
            isEnabled: false
        )

        XCTAssertTrue(view.shouldShowConnectPlaceholder)
    }

    func testPlaceholderDoesNotHideRealUsageState() {
        let view = UsageBarView(
            usage: QuotaPeriod(utilization: 42, resetDate: Date(timeIntervalSince1970: 4_102_444_800)),
            isLoading: false,
            error: nil,
            statusMessage: nil,
            isStale: false,
            recoveryAction: .none,
            isEnabled: false
        )

        XCTAssertFalse(view.shouldShowConnectPlaceholder)
    }

    func testPlaceholderDoesNotHideReconnectState() {
        let view = UsageBarView(
            usage: nil,
            isLoading: false,
            error: "Token expired",
            statusMessage: nil,
            isStale: false,
            recoveryAction: .reconnect,
            isEnabled: false
        )

        XCTAssertFalse(view.shouldShowConnectPlaceholder)
    }

    func testRecoveryButtonShowsForRetryStateWithUsagePresent() {
        let view = UsageBarView(
            usage: QuotaPeriod(utilization: 42, resetDate: Date(timeIntervalSince1970: 4_102_444_800)),
            isLoading: false,
            error: nil,
            statusMessage: "Updating soon",
            isStale: true,
            recoveryAction: .retry,
            isEnabled: true
        )

        XCTAssertTrue(view.shouldShowRecoveryButton)
    }

    func testRecoveryButtonShowsForReconnectStateWithUsagePresent() {
        let view = UsageBarView(
            usage: QuotaPeriod(utilization: 42, resetDate: Date(timeIntervalSince1970: 4_102_444_800)),
            isLoading: false,
            error: nil,
            statusMessage: "Reconnect Claude Code",
            isStale: true,
            recoveryAction: .reconnect,
            isEnabled: true
        )

        XCTAssertTrue(view.shouldShowRecoveryButton)
    }

    func testRecoveryButtonHiddenForWaitForClaudeCodeState() {
        let view = UsageBarView(
            usage: nil,
            isLoading: false,
            error: "Start a Claude Code session to track usage",
            statusMessage: nil,
            isStale: false,
            recoveryAction: .waitForClaudeCode,
            isEnabled: true
        )

        XCTAssertFalse(view.shouldShowRecoveryButton)
    }

    func testRecoveryButtonShowsForRetryStateWithoutUsage() {
        let view = UsageBarView(
            usage: nil,
            isLoading: false,
            error: "Rate limited, retrying in 120s",
            statusMessage: nil,
            isStale: false,
            recoveryAction: .retry,
            isEnabled: true
        )

        XCTAssertTrue(view.shouldShowRecoveryButton)
    }

    func testRecoveryActionLabelMatchesRecoveryAction() {
        func label(for action: ClaudeUsageRecoveryAction) -> String {
            UsageBarView(
                usage: nil,
                isLoading: false,
                error: nil,
                statusMessage: nil,
                isStale: false,
                recoveryAction: action,
                isEnabled: true
            ).recoveryActionLabel
        }

        XCTAssertEqual(label(for: .retry), "Retry")
        XCTAssertEqual(label(for: .reconnect), "Reconnect")
        XCTAssertEqual(label(for: .waitForClaudeCode), "Open Claude Code")
    }

    func testRecoveryButtonHiddenWhenNoRecoveryAction() {
        let view = UsageBarView(
            usage: QuotaPeriod(utilization: 42, resetDate: Date(timeIntervalSince1970: 4_102_444_800)),
            isLoading: false,
            error: nil,
            statusMessage: nil,
            isStale: false,
            recoveryAction: .none,
            isEnabled: true
        )

        XCTAssertFalse(view.shouldShowRecoveryButton)
    }

    func testRetryRecoveryActionInvokesOnRetry() {
        var retried = false
        var connected = false
        let view = UsageBarView(
            usage: nil,
            isLoading: false,
            error: "Rate limited, retrying in 120s",
            statusMessage: nil,
            isStale: false,
            recoveryAction: .retry,
            isEnabled: true,
            onConnect: { connected = true },
            onRetry: { retried = true }
        )

        view.performRecoveryAction()

        XCTAssertTrue(retried)
        XCTAssertFalse(connected)
    }

    func testReconnectRecoveryActionInvokesOnConnect() {
        var retried = false
        var connected = false
        let view = UsageBarView(
            usage: nil,
            isLoading: false,
            error: "Token expired",
            statusMessage: nil,
            isStale: false,
            recoveryAction: .reconnect,
            isEnabled: true,
            onConnect: { connected = true },
            onRetry: { retried = true }
        )

        view.performRecoveryAction()

        XCTAssertTrue(connected)
        XCTAssertFalse(retried)
    }

    func testExtraUsageIndicatorOnlyShowsWhenActivelyUsingExtraUsage() {
        let view = UsageBarView(
            usage: QuotaPeriod(utilization: 100, resetDate: Date(timeIntervalSince1970: 4_102_444_800)),
            isUsingExtraUsage: true,
            isLoading: false,
            error: nil,
            statusMessage: nil,
            isStale: false,
            recoveryAction: .none,
            isEnabled: true
        )

        XCTAssertTrue(view.shouldShowExtraUsageIndicator)
    }

    func testExtraUsageIndicatorHidesWhenUsageIsStale() {
        let view = UsageBarView(
            usage: QuotaPeriod(utilization: 100, resetDate: Date(timeIntervalSince1970: 4_102_444_800)),
            isUsingExtraUsage: true,
            isLoading: false,
            error: nil,
            statusMessage: "Updating soon",
            isStale: true,
            recoveryAction: .none,
            isEnabled: true
        )

        XCTAssertFalse(view.shouldShowExtraUsageIndicator)
    }

    func testBarFillPercentageClampsAboveQuota() {
        let view = UsageBarView(
            usage: QuotaPeriod(utilization: 125, resetDate: Date(timeIntervalSince1970: 4_102_444_800)),
            isUsingExtraUsage: true,
            isLoading: false,
            error: nil,
            statusMessage: nil,
            isStale: false,
            recoveryAction: .none,
            isEnabled: true
        )

        XCTAssertEqual(view.barFillPercentage, 100)
    }

    func testResetLabelTextIncludesProviderPrefixWhenProvided() {
        let view = UsageBarView(
            usage: QuotaPeriod(utilization: 12, resetDate: Date(timeIntervalSince1970: 4_102_444_800)),
            isLoading: false,
            error: nil,
            statusMessage: nil,
            isStale: false,
            recoveryAction: .none,
            resetLabelPrefix: "Codex",
            isEnabled: true
        )

        XCTAssertEqual(view.resetLabelText(for: "4m"), "Codex resets in 4m")
    }

    func testResetLabelTextOmitsProviderPrefixByDefault() {
        let view = UsageBarView(
            usage: QuotaPeriod(utilization: 12, resetDate: Date(timeIntervalSince1970: 4_102_444_800)),
            isLoading: false,
            error: nil,
            statusMessage: nil,
            isStale: false,
            recoveryAction: .none,
            isEnabled: true
        )

        XCTAssertEqual(view.resetLabelText(for: "4m"), "Resets in 4m")
    }
}
