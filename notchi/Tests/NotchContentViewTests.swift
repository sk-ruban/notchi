import XCTest
@testable import notchi

final class NotchContentViewTests: XCTestCase {
    func testActiveSessionStateTakesPrecedenceOverLaunchWave() {
        let wave = NotchContentView.LaunchWave(
            state: NotchiState(task: .waving, spriteFamily: .claude),
            startedAt: Date()
        )

        let result = NotchContentView.resolveHeaderSpriteContent(
            activeSessionState: .working,
            activeSessionId: "claude:active",
            launchWave: wave,
            isCompactIdle: true,
            launchSpriteFamily: .claude
        )

        XCTAssertEqual(
            result,
            NotchContentView.HeaderSpriteContent(state: .working, mirrorSeed: "claude:active")
        )
    }

    func testLaunchWaveOverridesCompactIdleWhenNoActiveSession() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 1000)
        let waveState = NotchiState(task: .waving, spriteFamily: .codex)
        let wave = NotchContentView.LaunchWave(state: waveState, startedAt: startedAt)

        let result = NotchContentView.resolveHeaderSpriteContent(
            activeSessionState: nil,
            launchWave: wave,
            isCompactIdle: true,
            launchSpriteFamily: .claude
        )

        XCTAssertEqual(result?.state, waveState)
        XCTAssertEqual(result?.mirrorSeed, "launch-wave-codex")
        XCTAssertEqual(result?.startedAt, startedAt)
        XCTAssertEqual(result?.repeatsAnimation, false)
    }

    func testCompactIdleReturnsNilWhenNoSessionOrWave() {
        let result = NotchContentView.resolveHeaderSpriteContent(
            activeSessionState: nil,
            launchWave: nil,
            isCompactIdle: true,
            launchSpriteFamily: .claude
        )

        XCTAssertNil(result)
    }

    func testIdleFallbackUsesLaunchSpriteFamilyOutsideCompactIdle() {
        let result = NotchContentView.resolveHeaderSpriteContent(
            activeSessionState: nil,
            launchWave: nil,
            isCompactIdle: false,
            launchSpriteFamily: .codex
        )

        XCTAssertEqual(
            result,
            NotchContentView.HeaderSpriteContent(
                state: NotchiState(task: .idle, spriteFamily: .codex),
                mirrorSeed: "fallback-codex"
            )
        )
    }
}
