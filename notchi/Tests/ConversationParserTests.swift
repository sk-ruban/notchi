import Foundation
import XCTest
@testable import notchi

final class ConversationParserTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchi-conversation-parser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        ConversationParser.projectsRootPath = tempDirectoryURL.path
    }

    override func tearDown() async throws {
        ConversationParser.projectsRootPath = "\(NSHomeDirectory())/.claude/projects"
        try? FileManager.default.removeItem(at: tempDirectoryURL)
        tempDirectoryURL = nil
        try await super.tearDown()
    }

    func testParseIncrementalSkipsSyntheticAssistantMessages() async throws {
        let sessionId = "session-\(UUID().uuidString)"
        let cwd = "/tmp/notchi"
        let parser = ConversationParser.shared

        let sessionFilePath = ConversationParser.sessionFilePath(sessionId: sessionId, cwd: cwd)
        let sessionDirectory = URL(fileURLWithPath: sessionFilePath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let synthetic = assistantLine(
            uuid: "synthetic-1",
            text: "No response requested.",
            model: "<synthetic>"
        )
        let real = assistantLine(
            uuid: "assistant-1",
            text: "What's up?",
            model: "claude-opus-4-6"
        )
        try (synthetic + "\n" + real + "\n").write(toFile: sessionFilePath, atomically: true, encoding: .utf8)

        let result = await parser.parseIncremental(sessionId: sessionId, cwd: cwd)

        XCTAssertFalse(result.interrupted)
        XCTAssertEqual(result.messages.map(\.text), ["What's up?"])
    }

    private func assistantLine(uuid: String, text: String, model: String) -> String {
        let timestamp = "2026-04-07T09:50:04.954Z"
        return """
        {"type":"assistant","uuid":"\(uuid)","timestamp":"\(timestamp)","message":{"model":"\(model)","role":"assistant","content":[{"type":"text","text":"\(text)"}]}}
        """
    }
}
