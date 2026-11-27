import XCTest
@testable import notchi

@MainActor
final class IslandSessionsTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        // Keep session tests away from the real Claude config folders.
        SessionStore.shared.setClaudeAccountObserverForTesting { _, _ in }
        // Keep the real last-used mascot preference out of tests.
        SessionStore.shared.setLastUsedProviderRecorderForTesting { _ in }
    }

    override func tearDown() async throws {
        let sessionKeys = Array(SessionStore.shared.sessions.keys)
        sessionKeys.forEach { SessionStore.shared.dismissSession($0) }
        SessionStore.shared.resetTestingHooks()
        try await super.tearDown()
    }

    func testIslandKeepsEverySessionAtTheLimitOfSeven() {
        let sessions = (0..<7).map { makeIdleSession("at-limit-\($0)") }
        let newestFirst = [6, 5, 4, 3, 2, 1, 0].map { sessions[$0].id }

        XCTAssertEqual(SessionStore.islandSessions(from: sessions).map(\.id), newestFirst)
    }

    func testIslandDropsTheLeastRecentIdleSessionsPastSeven() {
        let sessions = (0..<9).map { makeIdleSession("over-limit-\($0)") }
        let sevenNewestFirst = [8, 7, 6, 5, 4, 3, 2].map { sessions[$0].id }

        XCTAssertEqual(SessionStore.islandSessions(from: sessions).map(\.id), sevenNewestFirst)
    }

    func testIslandPutsWaitingThenWorkingSessionsAheadOfNewerIdleOnes() {
        let waiting = makeIdleSession("waiting")
        waiting.updateTask(.waiting)
        let working = makeSession("working", event: .userPromptSubmitted, status: "processing")
        let idle = (0..<7).map { makeIdleSession("idle-\($0)") }
        let expected = [waiting.id, working.id] + [6, 5, 4, 3, 2].map { idle[$0].id }

        let island = SessionStore.islandSessions(from: [waiting, working] + idle)

        XCTAssertEqual(island.map(\.id), expected)
    }

    func testIslandKeepsTheSelectedSessionEvenWhenItIsTheLeastRecent() {
        let sessions = (0..<9).map { makeIdleSession("selected-\($0)") }
        let expected = [0, 8, 7, 6, 5, 4, 3].map { sessions[$0].id }

        let island = SessionStore.islandSessions(from: sessions, selected: sessions[0].sessionKey)

        XCTAssertEqual(island.map(\.id), expected)
    }

    func testStoreIslandSessionsIncludeItsSelectedSession() {
        let sessions = (0..<9).map { makeIdleSession("store-\($0)") }
        let expected = [0, 8, 7, 6, 5, 4, 3].map { sessions[$0].id }
        SessionStore.shared.selectSession(sessions[0].sessionKey)

        XCTAssertEqual(SessionStore.shared.islandSessions.map(\.id), expected)
    }

    func testHiddenIslandSessionCountIsTheSessionsPastTheLimit() {
        let expectedHidden = 2
        (0..<9).forEach { _ = makeIdleSession("hidden-\($0)") }

        XCTAssertEqual(SessionStore.shared.hiddenIslandSessionCount, expectedHidden)
    }

    func testHiddenIslandSessionCountIsZeroAtTheLimit() {
        (0..<7).forEach { _ = makeIdleSession("none-hidden-\($0)") }

        XCTAssertEqual(SessionStore.shared.hiddenIslandSessionCount, 0)
    }

    func testHiddenSessionsTooltipUsesTheSingularForOneSession() throws {
        let english = try englishBundle()

        XCTAssertEqual(IslandHiddenSessionsBadge.tooltip(count: 1, bundle: english), "+1 session")
    }

    func testHiddenSessionsTooltipUsesThePluralForSeveralSessions() throws {
        let english = try englishBundle()

        XCTAssertEqual(IslandHiddenSessionsBadge.tooltip(count: 3, bundle: english), "+3 sessions")
    }

    private func englishBundle() throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"), "Missing en.lproj")
        return try XCTUnwrap(Bundle(path: path))
    }

    private func makeIdleSession(_ name: String) -> SessionData {
        makeSession(name, event: .stop, status: "waiting_for_input")
    }

    private func makeSession(_ name: String, event: NormalizedAgentEvent, status: String) -> SessionData {
        SessionStore.shared.process(HookEvent(
            provider: .claude,
            rawSessionId: "island-\(name)-\(UUID().uuidString)",
            transcriptPath: nil,
            cwd: "/tmp",
            event: event,
            status: status,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            userPrompt: nil,
            permissionMode: nil,
            interactive: true,
            codexProcessId: nil,
            codexOrigin: nil,
            lastAssistantMessage: nil
        ))
    }
}
