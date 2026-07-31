import XCTest
@testable import notchi

@MainActor
final class PromptInjectionServiceTests: XCTestCase {
    private final class FakePoster: KeyEventPosting {
        var callCount = 0
        var lastText: String?
        var lastPID: pid_t?
        func postTextAndReturn(_ text: String, toPID pid: pid_t) {
            callCount += 1; lastText = text; lastPID = pid
        }
    }

    func testCanInjectRejectsCodexDesktopOnly() {
        let claude = SessionData(sessionId: "c", provider: .claude, cwd: "/tmp")
        let codexCLI = SessionData(sessionId: "x", provider: .codex, cwd: "/tmp")
        codexCLI.updateCodexRuntime(processId: 10, origin: .cli)
        let codexDesktop = SessionData(sessionId: "y", provider: .codex, cwd: "/tmp")
        codexDesktop.updateCodexRuntime(processId: 11, origin: .desktop)

        XCTAssertTrue(PromptInjectionService.canInject(into: claude))
        XCTAssertTrue(PromptInjectionService.canInject(into: codexCLI))
        XCTAssertFalse(PromptInjectionService.canInject(into: codexDesktop))
    }

    func testPreparedPromptTrimsAndRejectsEmpty() {
        XCTAssertEqual(PromptInjectionService.preparedPrompt("  hi  "), "hi")
        XCTAssertNil(PromptInjectionService.preparedPrompt("   \n "))
    }

    func testInjectNilSessionReturnsNoSession() async {
        let service = makeService()
        let result = await service.inject("hi", into: nil)
        XCTAssertEqual(result, .noSession)
    }

    // MARK: - Background script path (preferred)

    func testScriptInjectDeliversInBackgroundWithoutKeystrokes() async {
        let poster = FakePoster()
        let session = SessionData(sessionId: "c", provider: .claude, cwd: "/tmp")
        let service = makeService(poster: poster, scriptInject: { _, _ in true })

        let result = await service.inject("run tests", into: session)
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(poster.callCount, 0, "background path must not synthesize keystrokes")
    }

    func testScriptInjectFailureReturnsFailed() async {
        let session = SessionData(sessionId: "c", provider: .claude, cwd: "/tmp")
        let service = makeService(scriptInject: { _, _ in false })
        let result = await service.inject("hi", into: session)
        XCTAssertEqual(result, .failed)
    }

    // MARK: - Fallback keystroke path (non-scriptable terminals; scriptInject → nil)

    func testFallbackTypesTextToResolvedPid() async {
        let poster = FakePoster()
        let session = SessionData(sessionId: "c", provider: .claude, cwd: "/tmp")
        let service = makeService(poster: poster, resolvePID: { _ in 4321 })

        let result = await service.inject("run tests", into: session)
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(poster.callCount, 1)
        XCTAssertEqual(poster.lastText, "run tests")
        XCTAssertEqual(poster.lastPID, 4321)
    }

    func testFallbackUsesFrontmostPidWhenTerminalUnresolved() async {
        let poster = FakePoster()
        let session = SessionData(sessionId: "c", provider: .claude, cwd: "/tmp")
        let service = makeService(poster: poster, resolvePID: { _ in nil })

        let result = await service.inject("hi", into: session, fallbackAppPID: 99)
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(poster.lastPID, 99)
    }

    func testFallbackRejectsNonTerminalFrontmostApp() async {
        let poster = FakePoster()
        let session = SessionData(sessionId: "c", provider: .claude, cwd: "/tmp")
        // Session unresolved + the frontmost app (e.g. a browser) is not a terminal.
        let service = makeService(poster: poster, resolvePID: { _ in nil }, isTerminalPID: { _ in false })

        let result = await service.inject("hi", into: session, fallbackAppPID: 99)
        XCTAssertEqual(result, .failed, "must not type into a non-terminal frontmost app")
        XCTAssertEqual(poster.callCount, 0)
    }

    func testFallbackFailsWhenNoPidResolvable() async {
        let session = SessionData(sessionId: "c", provider: .claude, cwd: "/tmp")
        let service = makeService(resolvePID: { _ in nil })
        let result = await service.inject("hi", into: session, fallbackAppPID: nil)
        XCTAssertEqual(result, .failed)
    }

    func testFallbackReturnsNeedsAccessibilityWhenUntrusted() async {
        let session = SessionData(sessionId: "c", provider: .claude, cwd: "/tmp")
        let service = makeService(resolvePID: { _ in 1 }, trusted: false)
        let result = await service.inject("hi", into: session)
        XCTAssertEqual(result, .needsAccessibility)
    }

    func testInjectReturnsNotInjectableForCodexDesktop() async {
        let session = SessionData(sessionId: "y", provider: .codex, cwd: "/tmp")
        session.updateCodexRuntime(processId: 11, origin: .desktop)
        let service = makeService(scriptInject: { _, _ in true })
        let result = await service.inject("hi", into: session)
        XCTAssertEqual(result, .notInjectable)
    }

    private func makeService(
        poster: KeyEventPosting = FakePoster(),
        scriptInject: @escaping @MainActor (String, SessionData) async -> Bool? = { _, _ in nil },
        resolvePID: @escaping @MainActor (SessionData) -> pid_t? = { _ in nil },
        isTerminalPID: @escaping @MainActor (pid_t) -> Bool = { _ in true },
        trusted: Bool = true
    ) -> PromptInjectionService {
        PromptInjectionService(
            poster: poster,
            scriptInject: scriptInject,
            resolveTerminalPID: resolvePID,
            isTerminalPID: isTerminalPID,
            accessibilityTrusted: { trusted }
        )
    }
}
