import XCTest
@testable import notchi

@MainActor
final class NotchiStateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NotchiState.resetSpriteSheetMetadataCacheForTesting()
    }

    override func tearDown() {
        NotchiState.resetSpriteSheetMetadataCacheForTesting()
        super.tearDown()
    }

    func testRepeatedMetadataAccessDoesNotReprobeSpriteSheets() {
        let state = NotchiState(task: .working)
        _ = state.spriteSheetName
        _ = state.frameCount
        _ = state.columns
        _ = state.animationFPS
        let probesAfterFirstResolution = NotchiState.spriteSheetProbeCountForTesting
        XCTAssertGreaterThan(probesAfterFirstResolution, 0)

        _ = state.spriteSheetName
        _ = state.frameCount
        _ = state.columns
        _ = state.animationFPS

        XCTAssertEqual(NotchiState.spriteSheetProbeCountForTesting, probesAfterFirstResolution)
    }

    func testCachedSheetNamesAreKeyedByFamilyTaskAndEmotion() {
        var claudeIdle = NotchiState(task: .idle)
        claudeIdle.spriteFamily = .claude
        var codexIdle = NotchiState(task: .idle)
        codexIdle.spriteFamily = .codex
        var claudeIdleHappy = NotchiState(task: .idle)
        claudeIdleHappy.emotion = .happy

        XCTAssertEqual(claudeIdle.spriteSheetName, "claude_idle_neutral")
        XCTAssertEqual(codexIdle.spriteSheetName, "codex_idle_neutral")
        XCTAssertEqual(claudeIdleHappy.spriteSheetName, "claude_idle_happy")
        XCTAssertEqual(claudeIdle.spriteSheetName, "claude_idle_neutral")
    }

    func testEmotionFallbackResolutionSurvivesCaching() {
        var workingElated = NotchiState(task: .working)
        workingElated.emotion = .elated

        XCTAssertEqual(workingElated.spriteSheetName, "claude_working_happy")
        XCTAssertEqual(workingElated.spriteSheetName, "claude_working_happy")

        var workingNeutral = NotchiState(task: .working)
        workingNeutral.emotion = .neutral
        XCTAssertEqual(workingNeutral.spriteSheetName, "claude_working_neutral")
    }

    func testFrameCountIsStableAcrossRepeatedAccess() {
        let waving = NotchiState(task: .waving)
        let idle = NotchiState(task: .idle)

        XCTAssertEqual(waving.frameCount, 25)
        XCTAssertEqual(idle.frameCount, 6)
        XCTAssertEqual(waving.frameCount, 25)
        XCTAssertEqual(idle.columns, 6)
    }
}
