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
        ConversationParser.claudeProjectsRootPath = tempDirectoryURL.path
    }

    override func tearDown() async throws {
        ConversationParser.claudeProjectsRootPath = ConversationParser.defaultClaudeProjectsRootPath
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
        ConversationParser.configureClaudeProjectsRootPath(using: resolution)

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
        ConversationParser.claudeProjectsRootPath = "/tmp/config-projects"

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

    func testParseIncrementalReadsCodexAssistantMessagesFromExplicitTranscriptPath() async throws {
        let sessionKey = ProviderSessionKey(provider: .codex, rawSessionId: "codex-\(UUID().uuidString)")
        let transcriptPath = tempDirectoryURL
            .appendingPathComponent("\(UUID().uuidString)-codex.jsonl")
            .path
        let parser = ConversationParser.shared

        let line = """
        {"timestamp":"2026-04-11T04:00:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello from Codex"}],"phase":"commentary"}}
        """
        FileManager.default.createFile(atPath: transcriptPath, contents: Data((line + "\n").utf8))

        let result = await parser.parseIncremental(sessionKey: sessionKey, transcriptPath: transcriptPath)
        await parser.resetState(for: sessionKey)

        XCTAssertEqual(result.messages.map(\.text), ["Hello from Codex"])
        XCTAssertFalse(result.interrupted)
    }

    func testParseIncrementalReadsCodexExecCommandEventsFromExplicitTranscriptPath() async throws {
        let sessionKey = ProviderSessionKey(provider: .codex, rawSessionId: "codex-\(UUID().uuidString)")
        let transcriptPath = tempDirectoryURL
            .appendingPathComponent("\(UUID().uuidString)-codex-tools.jsonl")
            .path
        let parser = ConversationParser.shared

        let contents = """
        {"timestamp":"2026-04-11T04:00:00.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"pwd\\",\\"max_output_tokens\\":200}","call_id":"call-123"}}
        {"timestamp":"2026-04-11T04:00:01.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-123","output":"Process exited with code 0\\nOutput:\\n/Users/ruban/Developer/GitHub/notchi\\n"}}
        """
        FileManager.default.createFile(atPath: transcriptPath, contents: Data((contents + "\n").utf8))

        let result = await parser.parseIncremental(sessionKey: sessionKey, transcriptPath: transcriptPath)
        await parser.resetState(for: sessionKey)

        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(result.events.first?.event, .preToolUse)
        XCTAssertEqual(result.events.first?.tool, "Bash")
        XCTAssertEqual(result.events.first?.toolUseId, "call-123")
        XCTAssertEqual(result.events.first?.toolInput?["command"]?.value as? String, "pwd")
        XCTAssertEqual(result.events.last?.event, .postToolUse)
        XCTAssertEqual(result.events.last?.status, "processing")
        XCTAssertEqual(result.events.last?.toolUseId, "call-123")
    }

    func testParseIncrementalEmitsPermissionRequestForApprovalGatedCodexCommand() async throws {
        let sessionKey = ProviderSessionKey(provider: .codex, rawSessionId: "codex-\(UUID().uuidString)")
        let transcriptPath = tempDirectoryURL
            .appendingPathComponent("\(UUID().uuidString)-codex-approval.jsonl")
            .path
        let parser = ConversationParser.shared

        let contents = """
        {"timestamp":"2026-04-11T04:00:00.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"rm /tmp/notchi-permission-test.txt\\",\\"sandbox_permissions\\":\\"require_escalated\\",\\"justification\\":\\"Do you want to allow deleting the temporary Notchi permission test file?\\"}","call_id":"call-approval"}}
        {"timestamp":"2026-04-11T04:00:01.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-approval","output":"rejected by user: permission denied"}}
        """
        FileManager.default.createFile(atPath: transcriptPath, contents: Data((contents + "\n").utf8))

        let result = await parser.parseIncremental(sessionKey: sessionKey, transcriptPath: transcriptPath)
        await parser.resetState(for: sessionKey)

        XCTAssertEqual(result.events.count, 3)
        XCTAssertEqual(result.events[0].event, .preToolUse)
        XCTAssertEqual(result.events[0].toolInput?["command"]?.value as? String, "rm /tmp/notchi-permission-test.txt")
        XCTAssertEqual(result.events[1].event, .permissionRequest)
        XCTAssertEqual(result.events[1].status, "waiting_for_input")
        XCTAssertEqual(result.events[1].tool, "Bash")
        XCTAssertEqual(result.events[1].toolUseId, "call-approval")
        XCTAssertEqual(result.events[1].toolInput?["justification"]?.value as? String, "Do you want to allow deleting the temporary Notchi permission test file?")
        XCTAssertEqual(result.events[2].event, .postToolUse)
        XCTAssertEqual(result.events[2].status, "error")
        XCTAssertEqual(result.events[2].toolUseId, "call-approval")
    }

    func testParseIncrementalMarksCodexTurnAbortedAsInterrupted() async throws {
        let sessionKey = ProviderSessionKey(provider: .codex, rawSessionId: "codex-\(UUID().uuidString)")
        let transcriptPath = tempDirectoryURL
            .appendingPathComponent("\(UUID().uuidString)-codex-aborted.jsonl")
            .path
        let parser = ConversationParser.shared

        let contents = """
        {"timestamp":"2026-04-11T04:00:00.000Z","type":"event_msg","payload":{"type":"turn_aborted"}}
        """
        FileManager.default.createFile(atPath: transcriptPath, contents: Data((contents + "\n").utf8))

        let result = await parser.parseIncremental(sessionKey: sessionKey, transcriptPath: transcriptPath)
        await parser.resetState(for: sessionKey)

        XCTAssertTrue(result.interrupted)
        XCTAssertTrue(result.messages.isEmpty)
        XCTAssertTrue(result.events.isEmpty)
    }

    func testResolvedTranscriptPathReturnsNilForCodexWithoutTranscriptPath() {
        let path = ConversationParser.resolvedTranscriptPath(
            for: .codex,
            sessionId: "codex-session",
            cwd: "/Users/ruban/Developer/GitHub/notchi",
            transcriptPath: nil
        )

        XCTAssertNil(path)
    }

    func testCodexAssistantMessageIdentifiersAreStableAcrossParserResets() async throws {
        let sessionKey = ProviderSessionKey(provider: .codex, rawSessionId: "codex-\(UUID().uuidString)")
        let transcriptPath = tempDirectoryURL
            .appendingPathComponent("\(UUID().uuidString)-stable-id.jsonl")
            .path
        let parser = ConversationParser.shared

        let line = """
        {"timestamp":"2026-04-11T04:00:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Stable Codex ID"}],"phase":"commentary"}}
        """
        FileManager.default.createFile(atPath: transcriptPath, contents: Data((line + "\n").utf8))

        let first = await parser.parseIncremental(sessionKey: sessionKey, transcriptPath: transcriptPath)
        await parser.resetState(for: sessionKey)
        let second = await parser.parseIncremental(sessionKey: sessionKey, transcriptPath: transcriptPath)
        await parser.resetState(for: sessionKey)

        XCTAssertEqual(first.messages.count, 1)
        XCTAssertEqual(second.messages.count, 1)
        XCTAssertEqual(first.messages.first?.id, second.messages.first?.id)
    }

    func testParseIncrementalParsesTimestampsWithoutFractionalSeconds() async throws {
        let sessionId = "basic-timestamp-\(UUID().uuidString)"
        let transcriptPath = tempDirectoryURL
            .appendingPathComponent("\(UUID().uuidString).jsonl")
            .path
        let parser = ConversationParser.shared

        // 2026-04-07T09:50:04Z
        let expectedTimestamp = Date(timeIntervalSince1970: 1_775_555_404)
        let line = """
        {"type":"assistant","uuid":"assistant-basic-timestamp","timestamp":"2026-04-07T09:50:04Z","message":{"model":"claude-opus-4-6","role":"assistant","content":[{"type":"text","text":"No fractional seconds"}]}}
        """
        FileManager.default.createFile(atPath: transcriptPath, contents: Data((line + "\n").utf8))

        let result = await parser.parseIncremental(sessionId: sessionId, transcriptPath: transcriptPath)

        XCTAssertEqual(result.messages.first?.timestamp, expectedTimestamp)
    }

    func testParseIncrementalReportsFastModeFromLatestAssistantReply() async throws {
        let transcriptPath = tempDirectoryURL.appendingPathComponent("\(UUID().uuidString).jsonl").path
        let parser = ConversationParser.shared
        let sessionId = "fast-\(UUID().uuidString)"
        let toolOnlyFastReply = assistantUsageLine(uuid: "a1", speed: "fast")
        FileManager.default.createFile(atPath: transcriptPath, contents: Data((toolOnlyFastReply + "\n").utf8))

        let fast = await parser.parseIncremental(sessionId: sessionId, transcriptPath: transcriptPath)

        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: transcriptPath))
        handle.seekToEndOfFile()
        handle.write(Data((assistantUsageLine(uuid: "a2", speed: "standard") + "\n").utf8))
        try handle.close()
        let standard = await parser.parseIncremental(sessionId: sessionId, transcriptPath: transcriptPath)
        await parser.resetState(for: sessionId)

        XCTAssertEqual(fast.isFastMode, true)
        XCTAssertEqual(standard.isFastMode, false)
    }

    func testParseIncrementalLeavesFastModeUnknownWithoutSpeedField() async throws {
        let transcriptPath = tempDirectoryURL.appendingPathComponent("\(UUID().uuidString).jsonl").path
        let parser = ConversationParser.shared
        let sessionId = "nospeed-\(UUID().uuidString)"
        let line = assistantLine(uuid: "a1", text: "hi", model: "claude-opus-5-5")
        FileManager.default.createFile(atPath: transcriptPath, contents: Data((line + "\n").utf8))

        let result = await parser.parseIncremental(sessionId: sessionId, transcriptPath: transcriptPath)
        await parser.resetState(for: sessionId)

        XCTAssertNil(result.isFastMode)
    }

    func testMarkCurrentPositionReportsFastModeFromLatestExistingReply() async throws {
        let transcriptPath = tempDirectoryURL.appendingPathComponent("\(UUID().uuidString).jsonl").path
        let parser = ConversationParser.shared
        let sessionId = "resume-fast-\(UUID().uuidString)"
        let lines = [assistantUsageLine(uuid: "a1", speed: "standard"), assistantUsageLine(uuid: "a2", speed: "fast")]
        FileManager.default.createFile(atPath: transcriptPath, contents: Data((lines.joined(separator: "\n") + "\n").utf8))

        let marked = await parser.markCurrentPosition(sessionId: sessionId, transcriptPath: transcriptPath)
        await parser.resetState(for: sessionId)

        XCTAssertEqual(marked.isFastMode, true)
    }

    func testMarkCurrentPositionStillSkipsExistingReplies() async throws {
        let transcriptPath = tempDirectoryURL.appendingPathComponent("\(UUID().uuidString).jsonl").path
        let parser = ConversationParser.shared
        let sessionId = "resume-skip-\(UUID().uuidString)"
        let line = assistantUsageLine(uuid: "a1", speed: "fast")
        FileManager.default.createFile(atPath: transcriptPath, contents: Data((line + "\n").utf8))

        _ = await parser.markCurrentPosition(sessionId: sessionId, transcriptPath: transcriptPath)
        let afterMark = await parser.parseIncremental(sessionId: sessionId, transcriptPath: transcriptPath)
        await parser.resetState(for: sessionId)

        XCTAssertTrue(afterMark.messages.isEmpty)
    }

    private func assistantUsageLine(uuid: String, speed: String) -> String {
        """
        {"type":"assistant","uuid":"\(uuid)","timestamp":"2026-10-28T17:00:00.000Z","message":{"model":"claude-opus-5-5","role":"assistant","content":[{"type":"tool_use","id":"t-\(uuid)","name":"Bash","input":{}}],"usage":{"input_tokens":1,"output_tokens":1,"speed":"\(speed)"}}}
        """
    }

    private func assistantLine(uuid: String, text: String, model: String) -> String {
        let timestamp = "2026-04-07T09:50:04.954Z"
        return """
        {"type":"assistant","uuid":"\(uuid)","timestamp":"\(timestamp)","message":{"model":"\(model)","role":"assistant","content":[{"type":"text","text":"\(text)"}]}}
        """
    }
}
