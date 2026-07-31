import XCTest
@testable import notchi

@MainActor
final class PromptInjectionServiceTests: XCTestCase {
    private final class FakePasteboard: Pasteboarding {
        var stored: String?
        var setValues: [String] = []
        func string() -> String? { stored }
        func setString(_ value: String) { stored = value; setValues.append(value) }
    }

    private final class FakePoster: KeyEventPosting {
        var pasteCount = 0
        var lastPID: pid_t?
        func postPasteAndReturn(toPID pid: pid_t) { pasteCount += 1; lastPID = pid }
    }

    /// Returns a scripted sequence of values from string(), so a test can make the
    /// clipboard "change" between the saved-read and the restore-read.
    private final class QueuedPasteboard: Pasteboarding {
        private let reads: [String?]
        private var idx = 0
        var setValues: [String] = []
        init(reads: [String?]) { self.reads = reads }
        func string() -> String? { defer { idx += 1 }; return idx < reads.count ? reads[idx] : reads.last ?? nil }
        func setString(_ value: String) { setValues.append(value) }
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

    func testScriptInjectDeliversInBackgroundWithoutPasteOrClipboard() async {
        let pasteboard = FakePasteboard(); pasteboard.stored = "original"
        let poster = FakePoster()
        let session = SessionData(sessionId: "c", provider: .claude, cwd: "/tmp")
        let service = makeService(pasteboard: pasteboard, poster: poster, scriptInject: { _, _ in true })

        let result = await service.inject("run tests", into: session)
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(poster.pasteCount, 0, "background path must not synthesize keystrokes")
        XCTAssertTrue(pasteboard.setValues.isEmpty, "background path must not touch the clipboard")
        XCTAssertEqual(pasteboard.stored, "original")
    }

    func testScriptInjectFailureReturnsFailed() async {
        let session = SessionData(sessionId: "c", provider: .claude, cwd: "/tmp")
        let service = makeService(scriptInject: { _, _ in false })
        let result = await service.inject("hi", into: session)
        XCTAssertEqual(result, .failed)
    }

    // MARK: - Fallback CGEvent path (non-scriptable terminals; scriptInject → nil)

    func testFallbackPostsToResolvedPidAndRestoresPasteboard() async {
        let pasteboard = FakePasteboard(); pasteboard.stored = "original"
        let poster = FakePoster()
        let session = SessionData(sessionId: "c", provider: .claude, cwd: "/tmp")
        let service = makeService(pasteboard: pasteboard, poster: poster, resolvePID: { _ in 4321 })

        let result = await service.inject("run tests", into: session)
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(poster.pasteCount, 1)
        XCTAssertEqual(poster.lastPID, 4321)
        XCTAssertEqual(pasteboard.setValues.first, "run tests")
        XCTAssertEqual(pasteboard.stored, "original") // restored
    }

    func testFallbackUsesFrontmostPidWhenTerminalUnresolved() async {
        let poster = FakePoster()
        let session = SessionData(sessionId: "c", provider: .claude, cwd: "/tmp")
        let service = makeService(poster: poster, resolvePID: { _ in nil })

        let result = await service.inject("hi", into: session, fallbackAppPID: 99)
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(poster.lastPID, 99)
    }

    func testFallbackFailsWhenNoPidResolvable() async {
        let session = SessionData(sessionId: "c", provider: .claude, cwd: "/tmp")
        let service = makeService(resolvePID: { _ in nil })
        let result = await service.inject("hi", into: session, fallbackAppPID: nil)
        XCTAssertEqual(result, .failed)
    }

    func testFallbackRejectsNonTerminalFrontmostApp() async {
        let poster = FakePoster()
        let session = SessionData(sessionId: "c", provider: .claude, cwd: "/tmp")
        // Session unresolved + the frontmost app (e.g. a browser) is not a terminal.
        let service = makeService(poster: poster, resolvePID: { _ in nil }, isTerminalPID: { _ in false })
        let result = await service.inject("hi", into: session, fallbackAppPID: 99)
        XCTAssertEqual(result, .failed, "must not paste into a non-terminal frontmost app")
        XCTAssertEqual(poster.pasteCount, 0)
    }

    func testRestoreSkippedWhenClipboardChangedDuringWindow() async {
        // string() yields "original" first (the saved read), then a different value
        // at restore time — as if the user copied something new after injection.
        let pasteboard = QueuedPasteboard(reads: ["original", "user copied later"])
        let session = SessionData(sessionId: "c", provider: .claude, cwd: "/tmp")
        let service = makeService(pasteboard: pasteboard, resolvePID: { _ in 4321 })

        let result = await service.inject("dictated", into: session)
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(pasteboard.setValues, ["dictated"], "must not restore over the user's newer clipboard")
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
        pasteboard: Pasteboarding = FakePasteboard(),
        poster: KeyEventPosting = FakePoster(),
        scriptInject: @escaping @MainActor (String, SessionData) async -> Bool? = { _, _ in nil },
        resolvePID: @escaping @MainActor (SessionData) -> pid_t? = { _ in nil },
        isTerminalPID: @escaping @MainActor (pid_t) -> Bool = { _ in true },
        trusted: Bool = true
    ) -> PromptInjectionService {
        PromptInjectionService(
            pasteboard: pasteboard,
            poster: poster,
            scriptInject: scriptInject,
            resolveTerminalPID: resolvePID,
            isTerminalPID: isTerminalPID,
            accessibilityTrusted: { trusted },
            restoreDelay: 0
        )
    }
}
