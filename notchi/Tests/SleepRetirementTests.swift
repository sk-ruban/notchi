import XCTest
@testable import notchi

@MainActor
final class SleepRetirementTests: XCTestCase {
    private static let thirtyMinutes: TimeInterval = 1_800
    private static let fiveHours: TimeInterval = 18_000
    private static let justUnderFiveHours: TimeInterval = 17_999
    private static let sixHours: TimeInterval = 21_600

    override func setUp() async throws {
        try await super.setUp()
        // Keep session tests away from the real Claude config folders.
        SessionStore.shared.setClaudeAccountObserverForTesting { _, _ in }
        // Keep the real last-used mascot preference out of tests.
        SessionStore.shared.setLastUsedProviderRecorderForTesting { _ in }
        NotchiStateMachine.shared.sleepRetirementAge = { Self.fiveHours }
    }

    override func tearDown() async throws {
        let sessionKeys = Array(SessionStore.shared.sessions.keys)
        sessionKeys.forEach { SessionStore.shared.dismissSession($0) }
        NotchiStateMachine.shared.resetTestingHooks()
        SessionStore.shared.resetTestingHooks()
        try await super.tearDown()
    }

    func testSessionAsleepForTheRetirementAgeIsRetired() {
        let session = makeSession(task: .sleeping)

        NotchiStateMachine.shared.retireLongSleepingSessions(now: session.lastActivity.addingTimeInterval(Self.fiveHours))

        XCTAssertNil(SessionStore.shared.session(for: session.sessionKey))
    }

    func testSessionAsleepForJustUnderTheRetirementAgeStays() {
        let session = makeSession(task: .sleeping)

        NotchiStateMachine.shared.retireLongSleepingSessions(
            now: session.lastActivity.addingTimeInterval(Self.justUnderFiveHours)
        )

        XCTAssertTrue(SessionStore.shared.session(for: session.sessionKey) === session)
    }

    func testShorterRetirementAgeRetiresASessionSooner() {
        NotchiStateMachine.shared.sleepRetirementAge = { Self.thirtyMinutes }
        let session = makeSession(task: .sleeping)

        NotchiStateMachine.shared.retireLongSleepingSessions(
            now: session.lastActivity.addingTimeInterval(Self.thirtyMinutes)
        )

        XCTAssertNil(SessionStore.shared.session(for: session.sessionKey))
    }

    func testIdleSessionStaysHoweverLongItHasBeenQuiet() {
        let session = makeSession(task: .idle)

        NotchiStateMachine.shared.retireLongSleepingSessions(now: session.lastActivity.addingTimeInterval(Self.sixHours))

        XCTAssertTrue(SessionStore.shared.session(for: session.sessionKey) === session)
    }

    func testLongSleepingSessionStaysWhenRetirementIsSetToNever() {
        NotchiStateMachine.shared.sleepRetirementAge = { nil }
        let session = makeSession(task: .sleeping)

        NotchiStateMachine.shared.retireLongSleepingSessions(now: session.lastActivity.addingTimeInterval(Self.sixHours))

        XCTAssertTrue(SessionStore.shared.session(for: session.sessionKey) === session)
    }

    func testRetiredSessionComesBackOnItsNextEvent() {
        let session = makeSession(task: .sleeping)
        NotchiStateMachine.shared.retireLongSleepingSessions(now: session.lastActivity.addingTimeInterval(Self.fiveHours))

        NotchiStateMachine.shared.handleEvent(makeEvent(rawSessionId: session.rawSessionId))

        XCTAssertNotNil(SessionStore.shared.session(for: session.sessionKey))
    }

    func testEachRetirementOptionMapsToItsDurationInSeconds() {
        let expected: [SleepRetirement: TimeInterval?] = [
            .thirtyMinutes: 1_800,
            .oneHour: 3_600,
            .twoHours: 7_200,
            .fiveHours: 18_000,
            .twelveHours: 43_200,
            .oneDay: 86_400,
            .never: nil,
        ]

        for option in SleepRetirement.allCases {
            XCTAssertEqual(option.duration, expected[option], "\(option)")
        }
    }

    func testRetirementSettingDefaultsToFiveHoursWhenUnsetOrUnrecognised() {
        XCTAssertEqual(AppSettings.sleepRetirement(fromRaw: nil), .fiveHours)
        XCTAssertEqual(AppSettings.sleepRetirement(fromRaw: "fortnight"), .fiveHours)
    }

    func testRetirementSettingReadsAStoredNever() {
        XCTAssertEqual(AppSettings.sleepRetirement(fromRaw: "never"), .never)
    }

    private func makeSession(task: NotchiTask) -> SessionData {
        let session = SessionStore.shared.process(makeEvent(rawSessionId: "retire-\(UUID().uuidString)"))
        session.updateTask(task)
        return session
    }

    private func makeEvent(rawSessionId: String) -> HookEvent {
        HookEvent(
            provider: .claude,
            rawSessionId: rawSessionId,
            transcriptPath: nil,
            cwd: "/tmp",
            event: .stop,
            status: "waiting_for_input",
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            userPrompt: nil,
            permissionMode: nil,
            interactive: true,
            codexProcessId: nil,
            codexOrigin: nil,
            lastAssistantMessage: nil
        )
    }
}
