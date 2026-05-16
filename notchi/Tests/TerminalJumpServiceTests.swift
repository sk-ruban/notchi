import XCTest
@testable import notchi

@MainActor
final class TerminalJumpServiceTests: XCTestCase {
    func testCodexDesktopSessionOpensThreadURL() {
        let session = SessionData(sessionId: "thread-123", provider: .codex, cwd: "/tmp/project")
        session.updateCodexRuntime(processId: 123, origin: .desktop)
        var openedURLs: [URL] = []
        let service = TerminalJumpService { url in
            openedURLs.append(url)
            return true
        }

        let didJump = service.jump(to: session)

        XCTAssertTrue(didJump)
        XCTAssertEqual(openedURLs.map(\.absoluteString), ["codex://threads/thread-123"])
    }

    func testNonDesktopCodexSessionDoesNotOpenURL() {
        let session = SessionData(sessionId: "thread-123", provider: .codex, cwd: "/tmp/project")
        session.updateCodexRuntime(processId: 123, origin: .cli)
        var openedURLs: [URL] = []
        let service = TerminalJumpService { url in
            openedURLs.append(url)
            return true
        }

        let didJump = service.jump(to: session)

        XCTAssertFalse(didJump)
        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testClaudeSessionDoesNotOpenURL() {
        let session = SessionData(sessionId: "thread-123", provider: .claude, cwd: "/tmp/project")
        var openedURLs: [URL] = []
        let service = TerminalJumpService { url in
            openedURLs.append(url)
            return true
        }

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
}
