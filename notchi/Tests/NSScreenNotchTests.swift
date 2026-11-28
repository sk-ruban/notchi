import AppKit
import XCTest
@testable import notchi

@MainActor
final class NSScreenNotchTests: XCTestCase {
    private let standardNonNotchSize = NSScreen.nonNotchSize(menuBarHeight: 25)

    func testNonNotchSizeMatchesMenuBarHeight() {
        let size = NSScreen.nonNotchSize(menuBarHeight: 25)
        XCTAssertEqual(size, CGSize(width: 224, height: 25))
    }

    func testNonNotchSizeFallsBackWhenMenuBarIsHidden() {
        let size = NSScreen.nonNotchSize(menuBarHeight: 0)
        XCTAssertEqual(size, CGSize(width: 224, height: 24))
    }

    func testHeaderSpriteFitScaleShrinksBelowReferenceHeightOnNonNotchScreens() {
        XCTAssertEqual(
            NotchContentView.headerSpriteFitScale(notchHeight: 34, screenHasNotch: false),
            34.0 / 38.0,
            accuracy: 0.0001
        )
    }

    func testHeaderSpriteFitScaleFloorsAtMinimumForShortMenuBars() {
        XCTAssertEqual(NotchContentView.headerSpriteFitScale(notchHeight: 24, screenHasNotch: false), 0.8)
    }

    func testHeaderSpriteFitScaleNeverExceedsOne() {
        XCTAssertEqual(NotchContentView.headerSpriteFitScale(notchHeight: 50, screenHasNotch: false), 1)
    }

    func testHeaderSpriteFitScaleIsUnchangedOnNotchedScreens() {
        XCTAssertEqual(NotchContentView.headerSpriteFitScale(notchHeight: 35, screenHasNotch: true), 1)
    }

    func testNonNotchHeaderSessionsReturnsMultipleRelevanceOrderedSessions() {
        let olderIdle = makeSession("older-idle", provider: .claude, activityOffset: -120)
        let newerIdle = makeSession("newer-idle", provider: .codex, activityOffset: 60)
        let processing = makeSession("processing", provider: .devin, activityOffset: -60)
        processing.updateProcessingState(isProcessing: true)
        let waiting = makeSession("waiting", provider: .claude, activityOffset: -30)
        waiting.updateTask(.waiting)

        let result = NotchContentView.nonNotchHeaderSessions(
            from: [olderIdle, newerIdle, processing, waiting],
            selected: olderIdle.sessionKey,
            screenHasNotch: false,
            leftContent: .ring,
            rightContent: .latest,
            notchSize: standardNonNotchSize
        )

        XCTAssertEqual(result.map(\.id), [olderIdle.id, waiting.id, processing.id, newerIdle.id])
    }

    func testNonNotchHeaderSessionsIsEmptyOnNotchedScreens() {
        let sessions = [
            makeSession("one", provider: .claude, activityOffset: -10),
            makeSession("two", provider: .codex, activityOffset: 0),
        ]

        let result = NotchContentView.nonNotchHeaderSessions(
            from: sessions,
            screenHasNotch: true,
            leftContent: .ring,
            rightContent: .latest,
            notchSize: standardNonNotchSize
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testNonNotchHeaderSessionsIsEmptyForZeroOrOneEligibleSession() {
        let single = [makeSession("only", provider: .claude, activityOffset: 0)]

        XCTAssertTrue(
            NotchContentView.nonNotchHeaderSessions(
                from: [],
                screenHasNotch: false,
                leftContent: .ring,
                rightContent: .latest,
                notchSize: standardNonNotchSize
            ).isEmpty
        )
        XCTAssertTrue(
            NotchContentView.nonNotchHeaderSessions(
                from: single,
                screenHasNotch: false,
                leftContent: .ring,
                rightContent: .latest,
                notchSize: standardNonNotchSize
            ).isEmpty
        )
    }

    func testNonNotchHeaderSessionsRespectsSlotConfigurationAndProviders() {
        let claudeA = makeSession("claude-a", provider: .claude, activityOffset: 10)
        let claudeB = makeSession("claude-b", provider: .claude, activityOffset: 20)
        let codex = makeSession("codex", provider: .codex, activityOffset: 30)
        let devin = makeSession("devin", provider: .devin, activityOffset: 40)
        let all = [claudeA, claudeB, codex, devin]

        XCTAssertTrue(
            NotchContentView.nonNotchHeaderSessions(
                from: all,
                screenHasNotch: false,
                leftContent: .ring,
                rightContent: .nothing,
                notchSize: standardNonNotchSize
            ).isEmpty
        )
        XCTAssertTrue(
            NotchContentView.nonNotchHeaderSessions(
                from: all,
                screenHasNotch: false,
                leftContent: .nothing,
                rightContent: .nothing,
                notchSize: standardNonNotchSize
            ).isEmpty
        )
        XCTAssertEqual(
            NotchContentView.nonNotchHeaderSessions(
                from: all,
                screenHasNotch: false,
                leftContent: .claude,
                rightContent: .ring,
                notchSize: standardNonNotchSize
            ).map(\.id),
            [claudeB.id, claudeA.id]
        )
        XCTAssertEqual(
            NotchContentView.nonNotchHeaderSessions(
                from: all,
                screenHasNotch: false,
                leftContent: .claude,
                rightContent: .codex,
                notchSize: standardNonNotchSize
            ).map(\.id),
            [codex.id, claudeB.id, claudeA.id]
        )
        XCTAssertEqual(
            NotchContentView.nonNotchHeaderSessions(
                from: all,
                screenHasNotch: false,
                leftContent: .ring,
                rightContent: .latest,
                notchSize: standardNonNotchSize
            ).map(\.id),
            [devin.id, codex.id, claudeB.id, claudeA.id]
        )
    }

    func testNonNotchHeaderSessionsCapsByAvailableWidthAndIslandLimit() {
        let selectedOldest = makeSession("selected-oldest", provider: .claude, activityOffset: -600)
        let waiting = makeSession("waiting", provider: .codex, activityOffset: -500)
        waiting.updateTask(.waiting)
        let processing = makeSession("processing", provider: .devin, activityOffset: -400)
        processing.updateProcessingState(isProcessing: true)
        let idle = (0..<10).map { index in
            makeSession("idle-\(index)", provider: .claude, activityOffset: TimeInterval(60 + index))
        }
        let all = [selectedOldest, waiting, processing] + idle

        let standardWithRing = NotchContentView.nonNotchHeaderSessions(
            from: all,
            selected: selectedOldest.sessionKey,
            screenHasNotch: false,
            leftContent: .ring,
            rightContent: .latest,
            notchSize: standardNonNotchSize
        )
        let standardCapacity = NotchContentView.nonNotchHeaderSpriteCapacity(
            availableWidth: NotchContentView.nonNotchSpriteStripWidth(
                notchSize: standardNonNotchSize,
                leftContent: .ring,
                rightContent: .latest
            )
        )
        XCTAssertEqual(standardWithRing.count, standardCapacity)
        XCTAssertLessThanOrEqual(standardWithRing.count, SessionStore.islandSessionLimit)
        XCTAssertEqual(Array(standardWithRing.prefix(3)).map(\.id), [selectedOldest.id, waiting.id, processing.id])

        let narrowResult = NotchContentView.nonNotchHeaderSessions(
            from: all,
            selected: selectedOldest.sessionKey,
            screenHasNotch: false,
            leftContent: .ring,
            rightContent: .latest,
            notchSize: CGSize(width: 110, height: 25)
        )
        XCTAssertEqual(narrowResult.map(\.id), [selectedOldest.id, waiting.id, processing.id])

        let wideResult = NotchContentView.nonNotchHeaderSessions(
            from: all,
            selected: selectedOldest.sessionKey,
            screenHasNotch: false,
            leftContent: .ring,
            rightContent: .latest,
            notchSize: CGSize(width: 600, height: 25)
        )
        XCTAssertEqual(wideResult.count, SessionStore.islandSessionLimit)
        XCTAssertEqual(Array(wideResult.prefix(3)).map(\.id), [selectedOldest.id, waiting.id, processing.id])
    }

    private func makeSession(
        _ id: String,
        provider: AgentProvider,
        activityOffset: TimeInterval
    ) -> SessionData {
        SessionData(
            sessionId: id,
            provider: provider,
            cwd: "/tmp",
            sessionStartTime: Date().addingTimeInterval(activityOffset)
        )
    }
}
