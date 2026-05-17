import CoreGraphics
import XCTest
@testable import notchi

@MainActor
final class SessionDataTests: XCTestCase {
    func testResolveXPositionReturnsCandidateWithinConfiguredRange() {
        let positions = stride(from: 0.05, through: 0.95, by: 0.15).map { CGFloat($0) }

        let resolved = SessionData.resolveXPositionForTesting(
            hash: 0,
            existingPositions: positions
        )

        XCTAssertGreaterThanOrEqual(resolved, CGFloat(0.05))
        XCTAssertLessThanOrEqual(resolved, CGFloat(0.95))
    }

    func testResolveXPositionFallsBackToMostSeparatedCandidateWhenAllCandidatesOverlap() {
        let positions = stride(from: 0.05, through: 0.95, by: 0.15).map { CGFloat($0) }

        let resolved = SessionData.resolveXPositionForTesting(
            hash: 0,
            existingPositions: positions
        )

        XCTAssertEqual(resolved, CGFloat(0.28), accuracy: 0.0001)
    }

    func testSpinnerVerbOnlyAdvancesWhenReplyCycleAdvances() {
        let session = SessionData(sessionId: "session-1", cwd: "/tmp/project")
        let initialVerb = session.currentSpinnerVerb

        session.recordPreToolUse(tool: "Read", toolInput: ["file_path": "README.md"], toolUseId: "tool-1")
        session.recordPostToolUse(tool: "Read", toolUseId: "tool-1", success: true)

        XCTAssertEqual(session.currentSpinnerVerb, initialVerb)

        session.advanceSpinnerVerbForReply()

        XCTAssertNotEqual(session.currentSpinnerVerb, initialVerb)
        XCTAssertTrue(SpinnerVerbs.all.contains(session.currentSpinnerVerb))
    }

    func testSessionStartsWithProviderSpecificSpinnerVerb() {
        let claude = SessionData(sessionId: "claude-session", provider: .claude, cwd: "/tmp/project")
        let codex = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")

        XCTAssertEqual(claude.currentSpinnerVerb, "Clauding")
        XCTAssertEqual(codex.currentSpinnerVerb, "Codexing")
    }

    func testStableIdentifierIncludesProviderWhenRawSessionIdMatches() {
        let claude = SessionData(sessionId: "shared-session", provider: .claude, cwd: "/tmp/project")
        let codex = SessionData(sessionId: "shared-session", provider: .codex, cwd: "/tmp/project")

        XCTAssertNotEqual(claude.id, codex.id)
        XCTAssertEqual(claude.id, "claude:shared-session")
        XCTAssertEqual(codex.id, "codex:shared-session")
    }

    func testStateUsesProviderSpecificSpriteFamily() {
        let claude = SessionData(sessionId: "claude-session", provider: .claude, cwd: "/tmp/project")
        let codex = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")

        XCTAssertEqual(claude.state.spriteFamily, .claude)
        XCTAssertEqual(codex.state.spriteFamily, .codex)
    }

    func testMissingCodexEmotionSpriteFallsBackWithinCodexFamily() {
        let state = NotchiState(task: .sleeping, emotion: .happy, spriteFamily: .codex)

        XCTAssertEqual(state.spriteSheetName, "codex_sleeping_neutral")
    }

    func testSpriteSpecificAnimationFPS() {
        let targetFPSCases: [(NotchiState, Double)] = [
            (NotchiState(task: .compacting, spriteFamily: .claude), 6.0),
            (NotchiState(task: .compacting, spriteFamily: .codex), 6.0),
            (NotchiState(task: .idle, emotion: .elated, spriteFamily: .claude), 7.0),
            (NotchiState(task: .idle, emotion: .happy, spriteFamily: .claude), 7.0),
            (NotchiState(task: .idle, emotion: .elated, spriteFamily: .codex), 7.0),
            (NotchiState(task: .idle, emotion: .happy, spriteFamily: .codex), 7.0),
            (NotchiState(task: .working, emotion: .happy, spriteFamily: .codex), 7.0),
            (NotchiState(task: .waving, spriteFamily: .claude), 25.0 / 2.6),
            (NotchiState(task: .waving, spriteFamily: .codex), 25.0 / 2.6)
        ]

        for (state, expectedFPS) in targetFPSCases {
            XCTAssertEqual(state.animationFPS, expectedFPS, accuracy: 0.0001, state.spriteSheetName)
        }
    }

    func testSpriteMirrorPoliciesAreExplicitByTask() {
        XCTAssertEqual(NotchiState(task: .idle).mirrorPolicy, .timed(30...60))
        XCTAssertEqual(NotchiState(task: .waiting).mirrorPolicy, .timed(45...90))
        XCTAssertEqual(NotchiState(task: .working).mirrorPolicy, .timed(10...15))
        XCTAssertEqual(NotchiState(task: .compacting).mirrorPolicy, .stateEntry)
        XCTAssertEqual(NotchiState(task: .sleeping).mirrorPolicy, .never)
        XCTAssertEqual(NotchiState(task: .waving).mirrorPolicy, .never)
    }

    func testTimedSpriteMirroringUsesConfiguredWindows() {
        let seeds = ["alpha", "beta", "gamma", "delta", "epsilon"]
        let intervals = seeds.map { SpriteMirrorPolicy.timedInterval(seed: $0, range: 30...60) }

        for interval in intervals {
            XCTAssertGreaterThanOrEqual(interval, 30)
            XCTAssertLessThanOrEqual(interval, 60)
        }

        XCTAssertEqual(
            SpriteMirrorPolicy.timedInterval(seed: "alpha", range: 30...60),
            SpriteMirrorPolicy.timedInterval(seed: "alpha", range: 30...60)
        )
        XCTAssertGreaterThan(Set(intervals).count, 1)
    }

    func testWorkingSpriteMirroringUsesTenToFifteenSecondWindows() {
        let seeds = ["alpha", "beta", "gamma", "delta", "epsilon"]
        let intervals = seeds.map { SpriteMirrorPolicy.timedInterval(seed: $0, range: 10...15) }

        for interval in intervals {
            XCTAssertGreaterThanOrEqual(interval, 10)
            XCTAssertLessThanOrEqual(interval, 15)
        }

        XCTAssertEqual(
            SpriteMirrorPolicy.timedInterval(seed: "alpha", range: 10...15),
            SpriteMirrorPolicy.timedInterval(seed: "alpha", range: 10...15)
        )
        XCTAssertGreaterThan(Set(intervals).count, 1)
    }

    func testTimedSpriteMirroringHandlesFullUInt64Range() {
        let interval = SpriteMirrorPolicy.timedInterval(seed: "alpha", range: 0...UInt64.max)

        XCTAssertGreaterThanOrEqual(interval, 0)
        XCTAssertLessThanOrEqual(interval, TimeInterval(UInt64.max))
    }

    func testWorkingSpriteMirroringIsStableInsideWorkingWindow() {
        let state = NotchiState(task: .working)
        let interval = SpriteMirrorPolicy.timedInterval(seed: "session|\(state.spriteSheetName)|interval", range: 10...15)
        let first = SpriteMirrorPolicy.isMirrored(
            state: state,
            seed: "session",
            date: Date(timeIntervalSinceReferenceDate: interval * 3 + 1),
            stateMirrored: true
        )
        let second = SpriteMirrorPolicy.isMirrored(
            state: state,
            seed: "session",
            date: Date(timeIntervalSinceReferenceDate: interval * 3 + min(8, interval - 1)),
            stateMirrored: false
        )

        XCTAssertEqual(first, second)
    }

    func testWorkingMirroringUsesFlippedSpriteAssetWhenAvailable() {
        let state = NotchiState(task: .working, spriteFamily: .claude)
        let presentation = state.spriteSheetPresentation(isMirrored: true)

        XCTAssertEqual(presentation.spriteSheetName, "claude_working_neutral_flipped")
        XCTAssertFalse(presentation.renderMirrored)
    }

    func testCodexWorkingHappyMirroringUsesMatchingFlippedSpriteAsset() {
        let state = NotchiState(task: .working, emotion: .happy, spriteFamily: .codex)
        let presentation = state.spriteSheetPresentation(isMirrored: true)

        XCTAssertEqual(presentation.spriteSheetName, "codex_working_happy_flipped")
        XCTAssertFalse(presentation.renderMirrored)
    }

    func testNonWorkingMirroringUsesRenderTransform() {
        let state = NotchiState(task: .idle, spriteFamily: .claude)
        let presentation = state.spriteSheetPresentation(isMirrored: true)

        XCTAssertEqual(presentation.spriteSheetName, state.spriteSheetName)
        XCTAssertTrue(presentation.renderMirrored)
    }

    func testCompactingSpriteUsesStateEntryMirroringUntilStateChanges() {
        let state = NotchiState(task: .compacting)

        XCTAssertTrue(SpriteMirrorPolicy.isMirrored(
            state: state,
            seed: "seed",
            date: Date(timeIntervalSinceReferenceDate: 0),
            stateMirrored: true
        ))
        XCTAssertTrue(SpriteMirrorPolicy.isMirrored(
            state: state,
            seed: "seed",
            date: Date(timeIntervalSinceReferenceDate: 10_000),
            stateMirrored: true
        ))
        XCTAssertFalse(SpriteMirrorPolicy.isMirrored(
            state: state,
            seed: "seed",
            date: Date(timeIntervalSinceReferenceDate: 10_000),
            stateMirrored: false
        ))
    }

    func testIdleSpriteMirroringIsStableInsideTimedWindow() {
        let state = NotchiState(task: .idle)
        let interval = SpriteMirrorPolicy.timedInterval(seed: "session|\(state.spriteSheetName)|interval", range: 30...60)
        let first = SpriteMirrorPolicy.isMirrored(
            state: state,
            seed: "session",
            date: Date(timeIntervalSinceReferenceDate: interval * 3 + 1),
            stateMirrored: false
        )
        let second = SpriteMirrorPolicy.isMirrored(
            state: state,
            seed: "session",
            date: Date(timeIntervalSinceReferenceDate: interval * 3 + min(20, interval - 1)),
            stateMirrored: true
        )

        XCTAssertEqual(first, second)
    }

    func testWavingSpritesUseLaunchAssets() {
        let claudeWave = NotchiState(task: .waving, spriteFamily: .claude)
        let codexWave = NotchiState(task: .waving, spriteFamily: .codex)

        XCTAssertEqual(claudeWave.spriteSheetName, "claude_waving_neutral")
        XCTAssertEqual(codexWave.spriteSheetName, "codex_waving_neutral")
        XCTAssertEqual(claudeWave.frameCount, 25)
        XCTAssertEqual(codexWave.frameCount, 25)
        XCTAssertEqual(claudeWave.columns, 25)
        XCTAssertEqual(codexWave.columns, 25)
    }
}
