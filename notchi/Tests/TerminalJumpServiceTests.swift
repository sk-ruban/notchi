import XCTest
@testable import notchi

@MainActor
final class TerminalJumpServiceTests: XCTestCase {
    func testCodexDesktopSessionOpensThreadURL() {
        let session = SessionData(sessionId: "thread-123", provider: .codex, cwd: "/tmp/project")
        session.updateCodexRuntime(processId: 123, origin: .desktop)
        var openedURLs: [URL] = []
        var activatedProcessIds: [pid_t] = []
        let service = makeService(
            openURL: { url in
                openedURLs.append(url)
                return true
            },
            activateProcess: { processId in
                activatedProcessIds.append(processId)
                return true
            }
        )

        let didJump = service.jump(to: session)

        XCTAssertTrue(didJump)
        XCTAssertEqual(openedURLs.map(\.absoluteString), ["codex://threads/thread-123"])
        XCTAssertTrue(activatedProcessIds.isEmpty)
    }

    func testCodexCLISessionActivatesHostingTerminalApp() {
        let session = SessionData(sessionId: "thread-123", provider: .codex, cwd: "/tmp/project")
        session.updateCodexRuntime(processId: 30, origin: .cli)
        var openedURLs: [URL] = []
        var activatedProcessIds: [pid_t] = []
        let service = makeService(
            openURL: { url in
                openedURLs.append(url)
                return true
            },
            processSnapshot: { self.makeSnapshot(parentProcessId: Self.terminalAncestry[$0]) },
            bundleIdentifierForProcess: { Self.terminalBundles[$0] },
            activateProcess: { processId in
                activatedProcessIds.append(processId)
                return true
            }
        )

        let didJump = service.jump(to: session)

        XCTAssertTrue(didJump)
        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertEqual(activatedProcessIds, [10])
    }

    func testClaudeCLISessionActivatesHostingTerminalApp() {
        let session = SessionData(sessionId: "claude-session", provider: .claude, cwd: "/tmp/project")
        session.updateClaudeRuntime(processId: 30)
        var openedURLs: [URL] = []
        var activatedProcessIds: [pid_t] = []
        let service = makeService(
            openURL: { url in
                openedURLs.append(url)
                return true
            },
            processSnapshot: { self.makeSnapshot(parentProcessId: Self.terminalAncestry[$0]) },
            bundleIdentifierForProcess: { Self.terminalBundles[$0] },
            activateProcess: { processId in
                activatedProcessIds.append(processId)
                return true
            }
        )

        let didJump = service.jump(to: session)

        XCTAssertTrue(didJump)
        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertEqual(activatedProcessIds, [10])
    }

    func testCodexCLISessionDoesNotActivateNonTerminalAncestor() {
        let session = SessionData(sessionId: "thread-123", provider: .codex, cwd: "/tmp/project")
        session.updateCodexRuntime(processId: 30, origin: .cli)
        var activatedProcessIds: [pid_t] = []
        let service = makeService(
            processSnapshot: { self.makeSnapshot(parentProcessId: Self.terminalAncestry[$0]) },
            bundleIdentifierForProcess: { processId in
                [pid_t(10): "com.apple.finder"][processId]
            },
            activateProcess: { processId in
                activatedProcessIds.append(processId)
                return true
            }
        )

        let didJump = service.jump(to: session)

        XCTAssertFalse(didJump)
        XCTAssertTrue(activatedProcessIds.isEmpty)
    }

    func testCodexCLISessionWithoutProcessIdDoesNotJump() {
        let session = SessionData(sessionId: "thread-123", provider: .codex, cwd: "/tmp/project")
        session.updateCodexRuntime(processId: nil, origin: .cli)
        var activatedProcessIds: [pid_t] = []
        let service = makeService { processId in
            activatedProcessIds.append(processId)
            return true
        }

        let didJump = service.jump(to: session)

        XCTAssertFalse(didJump)
        XCTAssertTrue(activatedProcessIds.isEmpty)
    }

    func testCodexCLISessionWithStaleProcessIdDoesNotJump() {
        let session = SessionData(sessionId: "thread-123", provider: .codex, cwd: "/tmp/project")
        session.updateCodexRuntime(processId: 30, origin: .cli)
        var activatedProcessIds: [pid_t] = []
        let service = makeService(
            processSnapshot: { _ in nil },
            activateProcess: { processId in
                activatedProcessIds.append(processId)
                return true
            }
        )

        let didJump = service.jump(to: session)

        XCTAssertFalse(didJump)
        XCTAssertTrue(activatedProcessIds.isEmpty)
    }

    func testCodexCLISessionStopsOnAncestorCycle() {
        let session = SessionData(sessionId: "thread-123", provider: .codex, cwd: "/tmp/project")
        session.updateCodexRuntime(processId: 30, origin: .cli)
        var activatedProcessIds: [pid_t] = []
        let service = makeService(
            processSnapshot: { processId in
                self.makeSnapshot(parentProcessId: [pid_t(30): pid_t(20), pid_t(20): pid_t(30)][processId])
            },
            bundleIdentifierForProcess: { _ in nil },
            activateProcess: { processId in
                activatedProcessIds.append(processId)
                return true
            }
        )

        let didJump = service.jump(to: session)

        XCTAssertFalse(didJump)
        XCTAssertTrue(activatedProcessIds.isEmpty)
    }

    func testCodexCLISessionStopsAfterAncestryDepthLimit() {
        let session = SessionData(sessionId: "thread-123", provider: .codex, cwd: "/tmp/project")
        session.updateCodexRuntime(processId: 30, origin: .cli)
        var activatedProcessIds: [pid_t] = []
        let service = makeService(
            processSnapshot: { processId in
                self.makeSnapshot(parentProcessId: processId + 1)
            },
            bundleIdentifierForProcess: { processId in
                processId == 60 ? "com.apple.Terminal" : nil
            },
            activateProcess: { processId in
                activatedProcessIds.append(processId)
                return true
            }
        )

        let didJump = service.jump(to: session)

        XCTAssertFalse(didJump)
        XCTAssertTrue(activatedProcessIds.isEmpty)
    }

    func testNonDesktopCodexSessionDoesNotOpenURL() {
        let session = SessionData(sessionId: "thread-123", provider: .codex, cwd: "/tmp/project")
        session.updateCodexRuntime(processId: 123, origin: .cli)
        var openedURLs: [URL] = []
        let service = makeService(openURL: { url in
            openedURLs.append(url)
            return true
        })

        let didJump = service.jump(to: session)

        XCTAssertFalse(didJump)
        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testCodexSessionWithoutOriginDoesNotJump() {
        let session = SessionData(sessionId: "thread-123", provider: .codex, cwd: "/tmp/project")
        var openedURLs: [URL] = []
        let service = makeService(openURL: { url in
            openedURLs.append(url)
            return true
        })

        let didJump = service.jump(to: session)

        XCTAssertFalse(didJump)
        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testClaudeSessionDoesNotOpenURL() {
        let session = SessionData(sessionId: "thread-123", provider: .claude, cwd: "/tmp/project")
        var openedURLs: [URL] = []
        let service = makeService(openURL: { url in
            openedURLs.append(url)
            return true
        })

        let didJump = service.jump(to: session)

        XCTAssertFalse(didJump)
        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testThreadURLPercentEncodesPathUnsafeCharacters() {
        let url = TerminalJumpService.codexDesktopThreadURL(threadId: " thread/with space ")

        XCTAssertEqual(url?.absoluteString, "codex://threads/thread%2Fwith%20space")
    }

    func testThreadURLReturnsNilForBlankThreadId() {
        XCTAssertNil(TerminalJumpService.codexDesktopThreadURL(threadId: ""))
        XCTAssertNil(TerminalJumpService.codexDesktopThreadURL(threadId: "   "))
    }

    private func makeService(
        openURL: @escaping (URL) -> Bool = { _ in true },
        processSnapshot: @escaping @MainActor (pid_t) -> TerminalJumpService.ProcessSnapshot? = { _ in nil },
        bundleIdentifierForProcess: @escaping @MainActor (pid_t) -> String? = { _ in nil },
        activateProcess: @escaping @MainActor (pid_t) -> Bool = { _ in true }
    ) -> TerminalJumpService {
        TerminalJumpService(
            openURL: openURL,
            processSnapshot: processSnapshot,
            bundleIdentifierForProcess: bundleIdentifierForProcess,
            activateProcess: activateProcess
        )
    }

    private func makeService(activateProcess: @escaping @MainActor (pid_t) -> Bool) -> TerminalJumpService {
        makeService(
            openURL: { _ in true },
            processSnapshot: { _ in nil },
            bundleIdentifierForProcess: { _ in nil },
            activateProcess: activateProcess
        )
    }

    private func makeSnapshot(parentProcessId: pid_t?) -> TerminalJumpService.ProcessSnapshot? {
        guard let parentProcessId else { return nil }

        return TerminalJumpService.ProcessSnapshot(parentProcessId: parentProcessId)
    }

    private static let terminalAncestry: [pid_t: pid_t] = [30: 20, 20: 10, 10: 1]
    private static let terminalBundles: [pid_t: String] = [10: "com.apple.Terminal"]
}
