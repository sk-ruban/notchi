import XCTest
@testable import notchi

final class PanelSettingsViewTests: XCTestCase {
    func testUsageBadgeShowsConnectedWhenClaudeUsageIsConnected() {
        XCTAssertEqual(
            PanelUsageBadgeState.resolve(
                isClaudeUsageConnected: true,
                hasActiveClaudeSession: false,
                hasActiveCodexSession: true,
                codexHooksInstalled: true
            ),
            .connected
        )
    }

    func testUsageBadgeShowsConnectedWhenDevinUsageIsAvailable() {
        XCTAssertEqual(
            PanelUsageBadgeState.resolve(
                isClaudeUsageConnected: false,
                hasActiveClaudeSession: false,
                hasActiveCodexSession: false,
                codexHooksInstalled: false,
                hasActiveDevinSessionWithUsage: true
            ),
            .connected
        )
    }

    func testUsageBadgeStillShowsSetupWhenClaudeUsageNeedsConnection() {
        XCTAssertEqual(
            PanelUsageBadgeState.resolve(
                isClaudeUsageConnected: false,
                hasActiveClaudeSession: true,
                hasActiveCodexSession: false,
                codexHooksInstalled: true
            ),
            .setup
        )
    }

    func testUsageBadgeShowsSetupWhenCodexSessionActiveButHooksNotInstalled() {
        XCTAssertEqual(
            PanelUsageBadgeState.resolve(
                isClaudeUsageConnected: false,
                hasActiveClaudeSession: false,
                hasActiveCodexSession: true,
                codexHooksInstalled: true
            ),
            .connected
        )

        XCTAssertEqual(
            PanelUsageBadgeState.resolve(
                isClaudeUsageConnected: false,
                hasActiveClaudeSession: false,
                hasActiveCodexSession: true,
                codexHooksInstalled: false
            ),
            .setup
        )
    }

    func testUsageBadgeShowsSetupWhenClaudeAndCodexSessionsAreBothActive() {
        XCTAssertEqual(
            PanelUsageBadgeState.resolve(
                isClaudeUsageConnected: false,
                hasActiveClaudeSession: true,
                hasActiveCodexSession: true,
                codexHooksInstalled: true
            ),
            .setup
        )
    }

    func testUsageBadgeShowsSetupWhenNoSessionIsActive() {
        XCTAssertEqual(
            PanelUsageBadgeState.resolve(
                isClaudeUsageConnected: false,
                hasActiveClaudeSession: false,
                hasActiveCodexSession: false,
                codexHooksInstalled: true
            ),
            .setup
        )
    }
}
