import CoreGraphics
import XCTest
@testable import notchi

@MainActor
final class SessionDataTests: XCTestCase {
    func testAutoPermissionModeShowsAutoBadge() {
        let session = SessionData(sessionId: "auto-session", provider: .claude, cwd: "/tmp/project")

        session.updatePermissionMode("auto")

        XCTAssertEqual(session.currentModeDisplay, "Auto")
    }

    func testRecordUserPromptUnwrapsPastedContentTags() {
        let session = SessionData(sessionId: "pasted-session", provider: .claude, cwd: "/tmp/project")

        session.recordUserPrompt(
            "look at this <pasted_content id=\"c32b\">\nfix the bubble\n</pasted_content id=\"c32b\"> please"
        )

        XCTAssertEqual(session.lastUserPrompt, "look at this fix the bubble please")
    }

    func testRecordUserPromptKeepsPromptsWithoutPastedContentTagsUnchanged() {
        let session = SessionData(sessionId: "plain-session", provider: .claude, cwd: "/tmp/project")

        session.recordUserPrompt("what does <pasted_content> mean in <b>this</b> file?")

        XCTAssertEqual(session.lastUserPrompt, "what does <pasted_content> mean in <b>this</b> file?")
    }

    func testRecordUserPromptLeavesCodexPromptsVerbatim() {
        let session = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")
        let prompt = "why does <pasted_content id=\"x\">text</pasted_content id=\"x\"> show up?"

        session.recordUserPrompt(prompt)

        XCTAssertEqual(session.lastUserPrompt, prompt)
    }

    func testDefaultPermissionModeShowsNoBadge() {
        let session = SessionData(sessionId: "default-session", provider: .claude, cwd: "/tmp/project")

        XCTAssertNil(session.currentModeDisplay)
    }

    func testResolveXPositionUsesHashDerivedCandidateWhenItDoesNotCollide() {
        let resolved = SessionData.resolveXPositionForTesting(
            hash: 0,
            existingPositions: [CGFloat(0.50)]
        )

        XCTAssertEqual(resolved, CGFloat(0.05), accuracy: 0.0001)
    }

    func testResolveXPositionNudgesPastCollidingSessionToNextSeparatedCandidate() {
        let resolved = SessionData.resolveXPositionForTesting(
            hash: 0,
            existingPositions: [CGFloat(0.05)]
        )

        XCTAssertEqual(resolved, CGFloat(0.28), accuracy: 0.0001)
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
        XCTAssertEqual(
            SessionData(sessionId: "devin-session", provider: .devin, cwd: "/tmp/project").state.spriteFamily,
            .devin
        )
    }

    func testDevinSobFallsBackToDevinSadSheet() {
        let state = NotchiState(task: .idle, emotion: .sob, spriteFamily: .devin)

        XCTAssertEqual(state.spriteSheetName, "devin_idle_sad")
    }

    func testDevinEmotionalWorkingAndWaitingFallBackToNeutralSheets() {
        let expectedSheets: [(NotchiState, String)] = [
            (NotchiState(task: .working, emotion: .happy, spriteFamily: .devin), "devin_working_neutral"),
            (NotchiState(task: .working, emotion: .sob, spriteFamily: .devin), "devin_working_neutral"),
            (NotchiState(task: .waiting, emotion: .sad, spriteFamily: .devin), "devin_waiting_neutral"),
            (NotchiState(task: .sleeping, emotion: .happy, spriteFamily: .devin), "devin_sleeping_neutral"),
        ]

        for (state, expectedSheet) in expectedSheets {
            XCTAssertEqual(state.spriteSheetName, expectedSheet)
        }
    }

    func testDevinSheetsInferNonDefaultFrameCounts() {
        let expectedFrameCounts: [(NotchiState, Int)] = [
            (NotchiState(task: .idle, spriteFamily: .devin), 7),
            (NotchiState(task: .idle, emotion: .elated, spriteFamily: .devin), 17),
            (NotchiState(task: .working, spriteFamily: .devin), 4),
            (NotchiState(task: .compacting, spriteFamily: .devin), 8),
            (NotchiState(task: .waving, spriteFamily: .devin), 24),
        ]

        for (state, expectedFrameCount) in expectedFrameCounts {
            XCTAssertEqual(state.frameCount, expectedFrameCount, state.spriteSheetName)
        }
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
            (NotchiState(task: .idle, emotion: .elated, spriteFamily: .devin), 7.0),
            (NotchiState(task: .idle, emotion: .happy, spriteFamily: .devin), 7.0),
            (NotchiState(task: .waving, spriteFamily: .devin), 24.0 / 2.6),
            (NotchiState(task: .waving, spriteFamily: .claude), 25.0 / 2.6),
            (NotchiState(task: .waving, spriteFamily: .codex), 25.0 / 2.6)
        ]

        for (state, expectedFPS) in targetFPSCases {
            XCTAssertEqual(state.animationFPS, expectedFPS, accuracy: 0.0001, state.spriteSheetName)
        }
    }

    func testMotionFrameIntervalUsesFullCadenceOnlyForFastMotion() {
        let fullCadenceCases: [NotchiState] = [
            NotchiState(task: .working),
            NotchiState(task: .working, emotion: .happy),
            NotchiState(task: .idle, emotion: .sob),
            NotchiState(task: .waiting, emotion: .sob),
        ]
        let halfCadenceCases: [NotchiState] = [
            NotchiState(task: .idle),
            NotchiState(task: .waiting),
            NotchiState(task: .idle, emotion: .happy),
            NotchiState(task: .sleeping),
        ]

        for state in fullCadenceCases {
            XCTAssertEqual(state.motionFrameInterval, 1.0 / 30.0, accuracy: 0.0001, state.spriteSheetName)
        }
        for state in halfCadenceCases {
            XCTAssertEqual(state.motionFrameInterval, 1.0 / 15.0, accuracy: 0.0001, state.spriteSheetName)
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

    private static let standardContextWindow = 200_000
    private static let extendedContextWindow = 1_000_000

    func testContextWindowIsStandardWhileUsageFitsInIt() {
        let session = SessionData(sessionId: "ctx-standard", provider: .claude, cwd: "/tmp")
        session.updateContextTokens(200_000)

        XCTAssertEqual(session.contextWindowTokens, Self.standardContextWindow)
    }

    func testContextWindowBecomesExtendedOnceUsagePassesTheStandardWindow() {
        let session = SessionData(sessionId: "ctx-extended", provider: .claude, cwd: "/tmp")
        session.updateContextTokens(200_001)

        XCTAssertEqual(session.contextWindowTokens, Self.extendedContextWindow)
    }

    func testContextWindowStaysExtendedAfterCompactionShrinksUsage() {
        let session = SessionData(sessionId: "ctx-compacted", provider: .claude, cwd: "/tmp")
        session.updateContextTokens(232_000)
        session.updateContextTokens(18_000)

        XCTAssertEqual(session.contextWindowTokens, Self.extendedContextWindow)
    }

    func testContextTokensTrackTheLatestReply() {
        let session = SessionData(sessionId: "ctx-latest", provider: .claude, cwd: "/tmp")
        session.updateContextTokens(232_000)
        session.updateContextTokens(18_000)

        XCTAssertEqual(session.contextTokens, 18_000)
    }

    func testContextWindowIsExtendedWhenAnEarlierReplyInTheSameReadPassedTheStandardWindow() {
        let session = SessionData(sessionId: "ctx-peak", provider: .claude, cwd: "/tmp")
        session.updateContextTokens(18_000, peak: 232_000)

        XCTAssertEqual(session.contextWindowTokens, Self.extendedContextWindow)
    }

    // MARK: - Claude account

    private static let personalAccountPath = "/Users/someone/.claude-personal"

    func testClaudeAccountDirectoryComesFromTheTranscriptPath() {
        let directory = SessionData.claudeConfigDirectory(
            transcriptPath: "\(Self.personalAccountPath)/projects/-Users-someone-app/1b2c.jsonl",
            rawConfigDir: nil
        )

        XCTAssertEqual(directory?.path, Self.personalAccountPath)
    }

    func testSubagentTranscriptPathPointsAtTheSameAccountDirectory() {
        let directory = SessionData.claudeConfigDirectory(
            transcriptPath: "\(Self.personalAccountPath)/projects/-Users-someone-app/1b2c/subagents/agent-7.jsonl",
            rawConfigDir: nil
        )

        XCTAssertEqual(directory?.path, Self.personalAccountPath)
    }

    func testAccountDirectoryInsideAProjectsFolderIsKeptWhole() {
        let accountInsideProjects = "/Users/someone/projects/claude-work"

        let directory = SessionData.claudeConfigDirectory(
            transcriptPath: "\(accountInsideProjects)/projects/-Users-someone-projects-app/1b2c.jsonl",
            rawConfigDir: nil
        )

        XCTAssertEqual(directory?.path, accountInsideProjects)
    }

    func testAccountDirectoryFallsBackToAnAbsoluteConfigDirWithoutATranscript() {
        let directory = SessionData.claudeConfigDirectory(transcriptPath: nil, rawConfigDir: Self.personalAccountPath)

        XCTAssertEqual(directory?.path, Self.personalAccountPath)
    }

    func testRelativeConfigDirWithoutATranscriptGivesNoAccountDirectory() {
        XCTAssertNil(SessionData.claudeConfigDirectory(transcriptPath: nil, rawConfigDir: "claude-personal"))
    }

    func testClaudeSessionWithoutAConfigDirUsesTheDefaultAccount() {
        let session = SessionData(sessionId: "default-account", provider: .claude, cwd: "/tmp")
        session.updateClaudeAccount(configDir: nil, transcriptPath: "/Users/someone/.claude/projects/-tmp/a.jsonl")

        XCTAssertTrue(session.usesDefaultClaudeAccount)
    }

    func testClaudeSessionWithAConfigDirUsesAnotherAccount() {
        let session = SessionData(sessionId: "personal-account", provider: .claude, cwd: "/tmp")
        session.updateClaudeAccount(configDir: Self.personalAccountPath, transcriptPath: nil)

        XCTAssertFalse(session.usesDefaultClaudeAccount)
    }

    // MARK: - T3 Code scratch folders

    func testT3ScratchFolderShowsItsPromptWords() {
        XCTAssertEqual(
            SessionData.projectName(forDirectory: "/Users/someone/.t3/scratch/2026-11-22-hey-test-2437ec67"),
            "hey test"
        )
    }

    func testT3ScratchFolderWithTheFullThreadIdShowsItsPromptWords() {
        XCTAssertEqual(
            SessionData.projectName(
                forDirectory: "/Users/someone/.t3/scratch/2026-11-22-fix-login-bug-0f3a9c2e7b1d4e5f8a6b9c0d1e2f3a4b"
            ),
            "fix login bug"
        )
    }

    func testT3ScratchFolderWithACollisionSuffixShowsItsPromptWords() {
        XCTAssertEqual(
            SessionData.projectName(
                forDirectory: "/Users/someone/.t3/scratch/2026-11-22-fix-login-bug-0f3a9c2e7b1d4e5f8a6b9c0d1e2f3a4b-9e8d7c6b"
            ),
            "fix login bug"
        )
    }

    func testT3ScratchFolderKeepsALongLastPromptWord() {
        XCTAssertEqual(
            SessionData.projectName(forDirectory: "/Users/someone/.t3/scratch/2026-11-22-fix-authentication-2437ec67"),
            "fix authentication"
        )
    }

    func testT3ScratchFolderKeepsAnEightLetterLastPromptWord() {
        XCTAssertEqual(
            SessionData.projectName(forDirectory: "/Users/someone/.t3/scratch/2026-11-22-fix-database-2437ec67"),
            "fix database"
        )
    }

    func testT3ScratchFolderWithoutPromptWordsKeepsItsFolderName() {
        XCTAssertEqual(
            SessionData.projectName(forDirectory: "/Users/someone/.t3/scratch/2026-11-22-2437ec67"),
            "2026-11-22-2437ec67"
        )
    }

    func testT3ScratchFolderWithoutPromptWordsButWithACollisionSuffixKeepsItsFolderName() {
        let folder = "2026-11-22-0f3a9c2e7b1d4e5f8a6b9c0d1e2f3a4b-9e8d7c6b"

        XCTAssertEqual(SessionData.projectName(forDirectory: "/Users/someone/.t3/scratch/\(folder)"), folder)
    }

    func testDatedFolderOutsideAScratchFolderKeepsItsName() {
        XCTAssertEqual(
            SessionData.projectName(forDirectory: "/Users/someone/notes/2026-11-22-hey-test-2437ec67"),
            "2026-11-22-hey-test-2437ec67"
        )
    }

    func testProjectFolderKeepsItsName() {
        XCTAssertEqual(SessionData.projectName(forDirectory: "/Users/someone/Developer/notchi"), "notchi")
    }
}
