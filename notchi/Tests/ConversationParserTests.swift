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
        ConversationParser.projectsRootPath = ConversationParser.defaultProjectsRootPath
        ClaudeConfigDirectoryResolver.resetTestingHooks()
        try? FileManager.default.removeItem(at: tempDirectoryURL)
        tempDirectoryURL = nil
        try await super.tearDown()
    }

    func testParseIncrementalSkipsSyntheticAssistantMessages() async throws {
        let sessionId = "session-\(UUID().uuidString)"
        let cwd = "/tmp/notchi"
        let parser = ConversationParser.shared

        let sessionFilePath = ConversationParser.resolvedTranscriptPath(
            sessionId: sessionId,
            cwd: cwd,
            transcriptPath: nil
        )
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

        let result = await parser.parseIncremental(sessionId: sessionId, transcriptPath: sessionFilePath)

        XCTAssertFalse(result.interrupted)
        XCTAssertEqual(result.messages.map(\.text), ["What's up?"])
    }

    func testParseIncrementalReadsAssistantMessagesFromExplicitTranscriptPath() async throws {
        let sessionId = "transcript-\(UUID().uuidString)"
        let transcriptPath = tempDirectoryURL
            .appendingPathComponent("\(UUID().uuidString).jsonl")
            .path
        let parser = ConversationParser.shared

        let explicit = assistantLine(
            uuid: "assistant-explicit",
            text: "Hello from a custom transcript path",
            model: "claude-opus-4-6"
        )
        FileManager.default.createFile(atPath: transcriptPath, contents: Data((explicit + "\n").utf8))

        let result = await parser.parseIncremental(
            sessionId: sessionId,
            transcriptPath: transcriptPath
        )
        await parser.resetState(for: sessionId)

        XCTAssertEqual(result.messages.map(\.text), ["Hello from a custom transcript path"])
        XCTAssertFalse(result.interrupted)
    }

    @MainActor
    func testResolvedTranscriptPathUsesConfiguredClaudeConfigDirectoryFallback() {
        let resolution = ClaudeConfigDirectoryResolution(
            path: "/tmp/custom-claude-config",
            source: .environment,
            shouldCache: true
        )
        ConversationParser.configureProjectsRootPath(using: resolution)

        let path = ConversationParser.resolvedTranscriptPath(
            sessionId: "session-123",
            cwd: "/Users/ruban/Developer/GitHub/notchi",
            transcriptPath: nil
        )

        XCTAssertEqual(
            path,
            "/tmp/custom-claude-config/projects/-Users-ruban-Developer-GitHub-notchi/session-123.jsonl"
        )
    }

    func testResolvedTranscriptPathFallsBackToDerivedSessionPathWhenMissingOrEmpty() {
        ConversationParser.projectsRootPath = "/tmp/config-projects"

        let missing = ConversationParser.resolvedTranscriptPath(
            sessionId: "session-123",
            cwd: "/Users/ruban/Developer/GitHub/notchi",
            transcriptPath: nil
        )
        let empty = ConversationParser.resolvedTranscriptPath(
            sessionId: "session-123",
            cwd: "/Users/ruban/Developer/GitHub/notchi",
            transcriptPath: "   "
        )

        XCTAssertEqual(missing, "/tmp/config-projects/-Users-ruban-Developer-GitHub-notchi/session-123.jsonl")
        XCTAssertEqual(empty, "/tmp/config-projects/-Users-ruban-Developer-GitHub-notchi/session-123.jsonl")
    }

    private func assistantLine(uuid: String, text: String, model: String) -> String {
        let timestamp = "2026-04-07T09:50:04.954Z"
        return """
        {"type":"assistant","uuid":"\(uuid)","timestamp":"\(timestamp)","message":{"model":"\(model)","role":"assistant","content":[{"type":"text","text":"\(text)"}]}}
        """
    }
}
