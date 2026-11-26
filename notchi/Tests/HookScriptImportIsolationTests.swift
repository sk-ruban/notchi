import Foundation
import XCTest
@testable import notchi

final class HookScriptImportIsolationTests: XCTestCase {
    private static let hookTimeout: TimeInterval = 5
    private static let bundledHookNames = ["notchi-hook", "notchi-codex-hook", "notchi-devin-hook"]

    private static let agentLikeEnvironment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": NSHomeDirectory(),
    ]

    private var stagingDirectory: URL?
    private var startedServers: [(server: SocketServer, path: String)] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchi-hook-isolation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stagingDirectory = directory
    }

    override func tearDown() async throws {
        for entry in startedServers {
            entry.server.stop()
            _ = await waitUntil(timeout: 1) {
                !FileManager.default.fileExists(atPath: entry.path)
            }
            unlink(entry.path)
            try? FileManager.default.removeItem(atPath: (entry.path as NSString).deletingLastPathComponent)
        }
        startedServers.removeAll()

        if let stagingDirectory {
            try? FileManager.default.removeItem(at: stagingDirectory)
        }

        try await super.tearDown()
    }

    func testClaudeHookDeliversEventFromDirectoryShadowingStdlib() async throws {
        try await assertHookDeliversEvent(scriptName: "notchi-hook", sessionId: "shadowed-claude")
    }

    func testCodexHookDeliversEventFromDirectoryShadowingStdlib() async throws {
        try await assertHookDeliversEvent(scriptName: "notchi-codex-hook", sessionId: "shadowed-codex")
    }

    func testDevinHookDeliversEventFromDirectoryShadowingStdlib() async throws {
        try await assertHookDeliversEvent(scriptName: "notchi-devin-hook", sessionId: "shadowed-devin")
    }

    func testDevinHookTagsEventAsDevinWithProjectDirectoryAndReply() async throws {
        try skipUnlessStdlibPythonRuns()

        let projectDirectory = "/tmp/devin-project"
        let reply = "The directory contains:\n- hooks.log"
        let recorder = EventRecorder()
        let socketPath = uniqueSocketPath()
        try await startServer(at: socketPath, recorder: recorder)
        let script = try stageScript(named: "notchi-devin-hook", socketPath: socketPath)
        let workspace = try makeShadowedWorkspace()

        _ = try runHook(
            script: script,
            workingDirectory: workspace.directory,
            payload: #"{"hook_event_name":"Stop","session_id":"tagged-devin","last_assistant_message":"The directory contains:\n- hooks.log"}"#,
            extraEnvironment: ["DEVIN_PROJECT_DIR": projectDirectory]
        )

        let delivered = await waitUntil(timeout: 2) {
            await recorder.snapshot().contains { $0.sessionId == "tagged-devin" }
        }
        XCTAssertTrue(delivered, "Devin hook never delivered its event")
        let snapshot = await recorder.snapshot()
        let envelope = try XCTUnwrap(snapshot.first { $0.sessionId == "tagged-devin" })
        XCTAssertEqual(envelope.provider, .devin)
        XCTAssertEqual(envelope.cwd, projectDirectory)
        XCTAssertEqual(envelope.status, "waiting_for_input")
        XCTAssertEqual(envelope.lastAssistantMessage, reply)
    }

    func testDevinHookKeepsStopEventWhenReplyIsNotPlainText() async throws {
        try skipUnlessStdlibPythonRuns()

        let recorder = EventRecorder()
        let socketPath = uniqueSocketPath()
        try await startServer(at: socketPath, recorder: recorder)
        let script = try stageScript(named: "notchi-devin-hook", socketPath: socketPath)
        let workspace = try makeShadowedWorkspace()

        _ = try runHook(
            script: script,
            workingDirectory: workspace.directory,
            payload: #"{"hook_event_name":"Stop","session_id":"structured-devin","last_assistant_message":[{"type":"text","text":"hi"}]}"#,
            extraEnvironment: ["DEVIN_PROJECT_DIR": "/tmp/devin-project"]
        )

        let delivered = await waitUntil(timeout: 2) {
            await recorder.snapshot().contains { $0.sessionId == "structured-devin" }
        }
        XCTAssertTrue(delivered, "Devin hook dropped a Stop event with a structured reply")
        let snapshot = await recorder.snapshot()
        XCTAssertNil(snapshot.first { $0.sessionId == "structured-devin" }?.lastAssistantMessage)
    }

    func testClaudeHookSkipsEventsFiredByDevin() async throws {
        try skipUnlessStdlibPythonRuns()

        let recorder = EventRecorder()
        let socketPath = uniqueSocketPath()
        try await startServer(at: socketPath, recorder: recorder)
        let script = try stageScript(named: "notchi-hook", socketPath: socketPath)
        let workspace = try makeShadowedWorkspace()

        _ = try runHook(
            script: script,
            workingDirectory: workspace.directory,
            payload: #"{"hook_event_name":"Stop","session_id":"devin-via-claude-hook"}"#,
            extraEnvironment: ["DEVIN_PROJECT_DIR": "/tmp/devin-project"]
        )

        let delivered = await waitUntil(timeout: 1) {
            await !recorder.snapshot().isEmpty
        }
        XCTAssertFalse(delivered, "Claude hook forwarded an event fired by Devin")
    }

    // Claude Code hashes this exact string for the account's keychain item, so it must arrive unaltered.
    private static let personalConfigDirWithTrailingSlash = "/Users/someone/.claude-personal/"

    private func deliverClaudeStop(sessionId: String, extraEnvironment: [String: String]) async throws -> AgentHookEnvelope {
        let recorder = EventRecorder()
        let socketPath = uniqueSocketPath()
        try await startServer(at: socketPath, recorder: recorder)
        let script = try stageScript(named: "notchi-hook", socketPath: socketPath)
        let workspace = try makeShadowedWorkspace()

        _ = try runHook(
            script: script,
            workingDirectory: workspace.directory,
            payload: #"{"hook_event_name":"Stop","session_id":"\#(sessionId)"}"#,
            extraEnvironment: extraEnvironment
        )

        _ = await waitUntil(timeout: 2) {
            await recorder.snapshot().contains { $0.sessionId == sessionId }
        }
        let snapshot = await recorder.snapshot()
        return try XCTUnwrap(snapshot.first { $0.sessionId == sessionId })
    }

    func testClaudeHookReportsTheRawClaudeConfigDir() async throws {
        try skipUnlessStdlibPythonRuns()

        let envelope = try await deliverClaudeStop(
            sessionId: "personal-account",
            extraEnvironment: ["CLAUDE_CONFIG_DIR": Self.personalConfigDirWithTrailingSlash]
        )

        XCTAssertEqual(envelope.claudeConfigDir, Self.personalConfigDirWithTrailingSlash)
    }

    func testClaudeHookReportsNoClaudeConfigDirForTheDefaultAccount() async throws {
        try skipUnlessStdlibPythonRuns()

        let envelope = try await deliverClaudeStop(sessionId: "default-account", extraEnvironment: [:])

        XCTAssertNil(envelope.claudeConfigDir)
    }

    func testClaudePermissionResponseReachesStdoutFromDirectoryShadowingStdlib() async throws {
        try skipUnlessStdlibPythonRuns()

        let decision = #"{"decision":"allow"}"#
        let recorder = EventRecorder()
        let socketPath = uniqueSocketPath()
        try await startServer(at: socketPath, recorder: recorder, response: Data(decision.utf8))

        let script = try stageScript(named: "notchi-hook", socketPath: socketPath)
        let workspace = try makeShadowedWorkspace()

        let result = try runHook(
            script: script,
            workingDirectory: workspace.directory,
            payload: #"{"hook_event_name":"PermissionRequest","session_id":"shadowed-permission","tool_name":"Bash"}"#
        )

        XCTAssertEqual(result.standardOutput, decision)
        XCTAssertEqual(result.standardError, "", "Hook leaked diagnostics into the agent transcript")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workspace.marker.path),
            "Hook executed a project-local stdlib shadow instead of the real stdlib"
        )
    }

    private static let maxToolInputTextLength = 2_000

    private func deliver(
        scriptName: String,
        sessionId: String,
        payload: String,
        extraEnvironment: [String: String] = [:],
        agentArgument: String? = nil,
        agentWrapsHookInShell: Bool = false
    ) async throws -> AgentHookEnvelope {
        let recorder = EventRecorder()
        let socketPath = uniqueSocketPath()
        try await startServer(at: socketPath, recorder: recorder)
        let script = try stageScript(named: scriptName, socketPath: socketPath)
        let workspace = try makeShadowedWorkspace()

        _ = try runHook(
            script: script,
            workingDirectory: workspace.directory,
            payload: payload,
            extraEnvironment: extraEnvironment,
            agentArgument: agentArgument,
            agentWrapsHookInShell: agentWrapsHookInShell
        )

        _ = await waitUntil(timeout: 2) {
            await recorder.snapshot().contains { $0.sessionId == sessionId }
        }
        let snapshot = await recorder.snapshot()
        return try XCTUnwrap(snapshot.first { $0.sessionId == sessionId }, "\(scriptName) never delivered its event")
    }

    func testClaudeHookMarksAPromptFromAPrintModeAgentNonInteractive() async throws {
        try skipUnlessStdlibPythonRuns()

        let envelope = try await deliver(
            scriptName: "notchi-hook",
            sessionId: "claude-print-mode",
            payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"claude-print-mode","prompt":"hi"}"#,
            agentArgument: "--print"
        )

        XCTAssertEqual(envelope.interactive, false)
    }

    func testClaudeHookMarksAPromptNonInteractiveWhenAPrintModeAgentWrapsTheHookInAShell() async throws {
        try skipUnlessStdlibPythonRuns()

        let envelope = try await deliver(
            scriptName: "notchi-hook",
            sessionId: "claude-print-mode-wrapped",
            payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"claude-print-mode-wrapped","prompt":"hi"}"#,
            agentArgument: "--print",
            agentWrapsHookInShell: true
        )

        XCTAssertEqual(envelope.interactive, false)
    }

    func testClaudeHookMarksAPromptFromATerminalAgentInteractive() async throws {
        try skipUnlessStdlibPythonRuns()

        let envelope = try await deliver(
            scriptName: "notchi-hook",
            sessionId: "claude-terminal",
            payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"claude-terminal","prompt":"hi"}"#
        )

        XCTAssertEqual(envelope.interactive, true)
    }

    func testClaudeHookMarksAPermissionRequestFromAPrintModeAgentNonInteractive() async throws {
        try skipUnlessStdlibPythonRuns()

        let envelope = try await deliver(
            scriptName: "notchi-hook",
            sessionId: "claude-print-permission",
            payload: #"{"hook_event_name":"PermissionRequest","session_id":"claude-print-permission","tool_name":"Bash"}"#,
            agentArgument: "-p"
        )

        XCTAssertEqual(envelope.interactive, false)
    }

    func testDevinHookMarksAPromptFromAPrintModeAgentNonInteractive() async throws {
        try skipUnlessStdlibPythonRuns()

        let envelope = try await deliver(
            scriptName: "notchi-devin-hook",
            sessionId: "devin-print-mode",
            payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"devin-print-mode","prompt":"hi"}"#,
            extraEnvironment: ["DEVIN_PROJECT_DIR": "/tmp/devin-project"],
            agentArgument: "--print"
        )

        XCTAssertEqual(envelope.interactive, false)
    }

    func testClaudeHookKeepsTheStartOfLongToolInputTextAndFieldsNotchiReadsWhole() async throws {
        try skipUnlessStdlibPythonRuns()
        let filePath = "/tmp/project/notes.md"
        let longCommand = "echo " + String(repeating: "c", count: Self.maxToolInputTextLength * 2)
        let longContent = "start-" + String(repeating: "x", count: Self.maxToolInputTextLength * 3) + "-end"
        let toolInput = try String(decoding: JSONSerialization.data(withJSONObject: [
            "file_path": filePath, "content": longContent, "command": longCommand,
        ]), as: UTF8.self)

        let envelope = try await deliver(
            scriptName: "notchi-hook",
            sessionId: "claude-long-write",
            payload: #"{"hook_event_name":"PreToolUse","session_id":"claude-long-write","tool_name":"Write","tool_use_id":"t1","tool_input":\#(toolInput)}"#
        )

        XCTAssertEqual(envelope.toolInput?["file_path"]?.value as? String, filePath)
        XCTAssertEqual(envelope.toolInput?["command"]?.value as? String, longCommand)
        XCTAssertEqual(envelope.toolInput?["content"]?.value as? String, String(longContent.prefix(Self.maxToolInputTextLength)))
    }

    func testDevinHookKeepsTheStartOfLongToolInputText() async throws {
        try skipUnlessStdlibPythonRuns()
        let longContent = "start-" + String(repeating: "x", count: Self.maxToolInputTextLength * 3) + "-end"

        let envelope = try await deliver(
            scriptName: "notchi-devin-hook",
            sessionId: "devin-long-write",
            payload: #"{"hook_event_name":"PreToolUse","session_id":"devin-long-write","tool_name":"write","tool_input":{"content":"\#(longContent)"}}"#,
            extraEnvironment: ["DEVIN_PROJECT_DIR": "/tmp/devin-project"]
        )

        XCTAssertEqual(envelope.toolInput?["content"]?.value as? String, String(longContent.prefix(Self.maxToolInputTextLength)))
    }

    func testClaudeHookKeepsAskUserQuestionInputWhole() async throws {
        try skipUnlessStdlibPythonRuns()
        let longQuestion = String(repeating: "q", count: Self.maxToolInputTextLength * 2)

        let envelope = try await deliver(
            scriptName: "notchi-hook",
            sessionId: "claude-long-question",
            payload: #"{"hook_event_name":"PreToolUse","session_id":"claude-long-question","tool_name":"AskUserQuestion","tool_use_id":"t2","tool_input":{"questions":[{"question":"\#(longQuestion)"}]}}"#
        )

        let questions = envelope.toolInput?["questions"]?.value as? [[String: Any]]
        XCTAssertEqual(questions?.first?["question"] as? String, longQuestion)
    }

    func testClaudeHookKeepsPermissionRequestInputWhole() async throws {
        try skipUnlessStdlibPythonRuns()
        let longContent = String(repeating: "x", count: Self.maxToolInputTextLength * 3)

        let envelope = try await deliver(
            scriptName: "notchi-hook",
            sessionId: "claude-long-permission",
            payload: #"{"hook_event_name":"PermissionRequest","session_id":"claude-long-permission","tool_name":"Write","tool_input":{"file_path":"/tmp/a","content":"\#(longContent)"}}"#,
            agentArgument: "--print"
        )

        XCTAssertEqual(envelope.toolInput?["content"]?.value as? String, longContent)
    }

    func testCodexHookDetectsAnImageOnAPromptAtTheEndOfALargeTranscript() async throws {
        try skipUnlessStdlibPythonRuns()
        let prompt = "what is in this screenshot"
        let fillerLine = #"{"type":"response_item","payload":{"type":"message","content":"\#(String(repeating: "f", count: 4_000))"}}"#
        let promptLine = #"{"type":"event_msg","payload":{"type":"user_message","message":"\#(prompt)","images":["data:image/png;base64,AAAA"]}}"#
        let fillerLineCount = 1_000
        let transcript = try XCTUnwrap(stagingDirectory).appendingPathComponent("large-rollout.jsonl")
        let contents = Array(repeating: fillerLine, count: fillerLineCount) + [promptLine]
        try Data((contents.joined(separator: "\n") + "\n").utf8).write(to: transcript)

        let envelope = try await deliver(
            scriptName: "notchi-codex-hook",
            sessionId: "codex-large-transcript",
            payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"codex-large-transcript","cwd":"/tmp","transcript_path":"\#(transcript.path)","prompt":"\#(prompt)"}"#
        )

        XCTAssertEqual(envelope.hasAttachments, true)
    }

    func testClaudeHookDoesNotWaitForAnAnswerToAPrintModePermissionRequest() async throws {
        try skipUnlessStdlibPythonRuns()

        let recorder = EventRecorder()
        let socketPath = uniqueSocketPath()
        try await startServer(at: socketPath, recorder: recorder, response: Data(#"{"decision":"allow"}"#.utf8))
        let script = try stageScript(named: "notchi-hook", socketPath: socketPath)
        let workspace = try makeShadowedWorkspace()

        let result = try runHook(
            script: script,
            workingDirectory: workspace.directory,
            payload: #"{"hook_event_name":"PermissionRequest","session_id":"headless-permission","tool_name":"Bash"}"#,
            agentArgument: "--print"
        )
        let delivered = await waitUntil(timeout: 2) {
            await recorder.snapshot().contains { $0.sessionId == "headless-permission" }
        }
        XCTAssertTrue(delivered, "precondition: the hook reached notchi")

        XCTAssertEqual(result.standardOutput, "")
    }

    private func deliverCodexPrompt(_ prompt: String, transcriptLines: [String], sessionId: String) async throws -> AgentHookEnvelope {
        let transcript = try XCTUnwrap(stagingDirectory).appendingPathComponent("\(sessionId).jsonl")
        try Data((transcriptLines.joined(separator: "\n") + "\n").utf8).write(to: transcript)
        return try await deliver(
            scriptName: "notchi-codex-hook",
            sessionId: sessionId,
            payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sessionId)","cwd":"/tmp","transcript_path":"\#(transcript.path)","prompt":"\#(prompt)"}"#
        )
    }

    private func codexPromptLine(_ prompt: String, imageData: String = "AAAA") -> String {
        #"{"type":"event_msg","payload":{"type":"user_message","message":"\#(prompt)","images":["data:image/png;base64,\#(imageData)"]}}"#
    }

    private static let codexFillerLine = #"{"type":"response_item","payload":{"type":"message","content":"filler"}}"#

    func testCodexHookDetectsAnImageOnAPromptLineLargerThanTwoMegabytes() async throws {
        try skipUnlessStdlibPythonRuns()
        let prompt = "describe this large screenshot"
        let largeImage = String(repeating: "A", count: 3 * 1024 * 1024)

        let envelope = try await deliverCodexPrompt(
            prompt,
            transcriptLines: [Self.codexFillerLine, codexPromptLine(prompt, imageData: largeImage)],
            sessionId: "codex-large-prompt-line"
        )

        XCTAssertEqual(envelope.hasAttachments, true)
    }

    func testCodexHookDetectsAnImageOnAPromptFollowedByALineLargerThanTwoMegabytes() async throws {
        try skipUnlessStdlibPythonRuns()
        let prompt = "what changed here"
        let largeLine = #"{"type":"response_item","payload":{"type":"message","content":"\#(String(repeating: "r", count: 3 * 1024 * 1024))"}}"#

        let envelope = try await deliverCodexPrompt(
            prompt,
            transcriptLines: [codexPromptLine(prompt), largeLine],
            sessionId: "codex-large-following-line"
        )

        XCTAssertEqual(envelope.hasAttachments, true)
    }

    func testCodexHookDetectsAnImageOnAPromptTwoHundredLinesFromTheEnd() async throws {
        try skipUnlessStdlibPythonRuns()
        let prompt = "still in the window"
        // The hook looks back over the last 200 transcript lines; the prompt is the oldest of them.
        // 199 lines of 5,000 bytes fill just under the hook's 1 MB read, so the prompt line (about
        // 60 KB with its image) crosses that read's start and needs a second read to be whole.
        let linesAfterPrompt = 199
        let fillerLineBytes = 5_000
        let fillerPrefix = #"{"type":"response_item","payload":{"type":"message","content":""#
        let fillerSuffix = #""}}"#
        let sizedFillerLine = fillerPrefix
            + String(repeating: "f", count: fillerLineBytes - 1 - fillerPrefix.utf8.count - fillerSuffix.utf8.count)
            + fillerSuffix
        let promptImage = String(repeating: "A", count: 60_000)

        let envelope = try await deliverCodexPrompt(
            prompt,
            transcriptLines: [Self.codexFillerLine, codexPromptLine(prompt, imageData: promptImage)]
                + Array(repeating: sizedFillerLine, count: linesAfterPrompt),
            sessionId: "codex-prompt-at-window-edge"
        )

        XCTAssertEqual(envelope.hasAttachments, true)
    }

    func testBundledHooksRunPythonInIsolatedMode() throws {
        for name in Self.bundledHookNames {
            let script = try String(contentsOf: bundledScriptURL(named: name), encoding: .utf8)
            XCTAssertTrue(
                script.contains("/usr/bin/python3 -I -c"),
                "\(name).sh must run python in isolated mode so the session cwd cannot shadow the stdlib"
            )
        }
    }

    func testInstalledHooksUseTheSocketPathTheServerListensOn() throws {
        for name in Self.bundledHookNames {
            let installed = HookFile.installableScript(from: try Data(contentsOf: bundledScriptURL(named: name)))
            let assignment = try XCTUnwrap(
                String(decoding: installed, as: UTF8.self)
                    .split(separator: "\n")
                    .first { $0.hasPrefix("SOCKET_PATH=") },
                name
            )

            XCTAssertEqual(try socketPath(evaluating: String(assignment), home: "/tmp/some-other-home"), SocketServer.socketPath, name)
        }
    }

    func testInstalledHookQuotesASocketPathWithShellCharacters() throws {
        let awkwardPath = #"/tmp/it's "quoted" $HOME/notchi.sock"#
        let installed = HookFile.installableScript(
            from: try Data(contentsOf: bundledScriptURL(named: "notchi-hook")),
            socketPath: awkwardPath
        )
        let assignment = try XCTUnwrap(
            String(decoding: installed, as: UTF8.self).split(separator: "\n").first { $0.hasPrefix("SOCKET_PATH=") }
        )

        XCTAssertEqual(try socketPath(evaluating: String(assignment), home: NSHomeDirectory()), awkwardPath)
    }

    func testBundledHooksOnlySendToASocketOwnedByTheCurrentUser() throws {
        for name in Self.bundledHookNames {
            let script = try String(contentsOf: bundledScriptURL(named: name), encoding: .utf8)
            XCTAssertTrue(
                script.contains(#"[ -S "$SOCKET_PATH" ] && [ -O "$SOCKET_PATH" ] || exit 0"#),
                "\(name).sh must skip sockets it does not own"
            )
        }
    }

    func testHookDeliversEventWhenSocketPathContainsAnApostrophe() async throws {
        try skipUnlessStdlibPythonRuns()

        let recorder = EventRecorder()
        let socketPath = uniqueSocketPath(prefix: "notchi-o'brien")
        try await startServer(at: socketPath, recorder: recorder)
        let script = try stageScript(named: "notchi-hook", socketPath: socketPath)
        let workspace = try makeShadowedWorkspace()

        _ = try runHook(
            script: script,
            workingDirectory: workspace.directory,
            payload: #"{"hook_event_name":"Stop","session_id":"apostrophe-path"}"#
        )

        let delivered = await waitUntil(timeout: 2) {
            await recorder.snapshot().contains { $0.sessionId == "apostrophe-path" }
        }
        XCTAssertTrue(delivered, "Hook could not reach a socket whose path contains an apostrophe")
    }

    func testBundledHooksEndWithExplicitExitZero() throws {
        for name in Self.bundledHookNames {
            let script = try String(contentsOf: bundledScriptURL(named: name), encoding: .utf8)
            let lastLine = script
                .split(separator: "\n", omittingEmptySubsequences: true)
                .last
                .map(String.init)

            XCTAssertEqual(
                lastLine,
                "exit 0",
                "\(name).sh must end with exit 0 so a python failure stays fail-open"
            )
        }
    }

    // MARK: - Assertions

    private func skipUnlessStdlibPythonRuns() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", "import json, socket, subprocess"]
        process.environment = Self.agentLikeEnvironment

        let error = Pipe()
        process.standardOutput = Pipe()
        process.standardError = error

        try process.run()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus != 0 else { return }

        throw XCTSkip(
            "/usr/bin/python3 cannot run here, so hook behaviour is untestable: "
                + String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func assertHookDeliversEvent(
        scriptName: String,
        sessionId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try skipUnlessStdlibPythonRuns()

        let recorder = EventRecorder()
        let socketPath = uniqueSocketPath()
        try await startServer(at: socketPath, recorder: recorder)

        let script = try stageScript(named: scriptName, socketPath: socketPath)
        let workspace = try makeShadowedWorkspace()

        let result = try runHook(
            script: script,
            workingDirectory: workspace.directory,
            payload: #"{"hook_event_name":"Stop","session_id":"\#(sessionId)"}"#
        )

        XCTAssertEqual(result.standardError, "", "Hook leaked diagnostics into the agent transcript", file: file, line: line)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workspace.marker.path),
            "Hook executed a project-local stdlib shadow instead of the real stdlib",
            file: file,
            line: line
        )

        let delivered = await waitUntil(timeout: 2) {
            await recorder.snapshot().contains { $0.sessionId == sessionId }
        }
        XCTAssertTrue(delivered, "Hook never delivered an event for \(sessionId)", file: file, line: line)
    }

    // MARK: - Helpers

    private func bundledScriptURL(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("notchi/Resources/\(name).sh")
    }

    private func socketPath(evaluating assignment: String, home: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", assignment + #"; printf %s "$SOCKET_PATH""#]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": home]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func uniqueSocketPath(prefix: String = "notchi-isolation") -> String {
        "/tmp/\(prefix)-\(UUID().uuidString.prefix(8))/notchi.sock"
    }

    private func startServer(
        at path: String,
        recorder: EventRecorder,
        response: Data? = nil
    ) async throws {
        let server = SocketServer(socketPath: path, clientReadTimeout: 1.0)
        startedServers.append((server, path))

        server.start { envelope in
            Task { await recorder.record(envelope) }
            return response
        }

        let didStart = await waitUntil(timeout: 2) {
            FileManager.default.fileExists(atPath: path)
        }
        guard didStart else {
            throw ServerDidNotBind(path: path)
        }
    }

    private func stageScript(named name: String, socketPath: String) throws -> URL {
        let bundled = try Data(contentsOf: bundledScriptURL(named: name))
        let staged = HookFile.installableScript(from: bundled, socketPath: socketPath)
        XCTAssertNotEqual(staged, bundled, "\(name).sh no longer declares the socket path installers replace")

        let url = try XCTUnwrap(stagingDirectory).appendingPathComponent("\(name).sh")
        try staged.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeShadowedWorkspace() throws -> (directory: URL, marker: URL) {
        let directory = try XCTUnwrap(stagingDirectory)
            .appendingPathComponent("workspace-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let marker = directory.appendingPathComponent("shadow-executed.marker")
        let shadowSource = """
        with open("\(marker.path)", "w") as handle:
            handle.write("executed")
        """

        for module in ["json", "subprocess"] {
            try shadowSource.write(
                to: directory.appendingPathComponent("\(module).py"),
                atomically: true,
                encoding: .utf8
            )
        }

        try Data("not a mach-o file".utf8).write(to: directory.appendingPathComponent("socket.so"))

        return (directory, marker)
    }

    private func runHook(
        script: URL,
        workingDirectory: URL,
        payload: String,
        extraEnvironment: [String: String] = [:],
        agentArgument: String? = nil,
        agentWrapsHookInShell: Bool = false
    ) throws -> (standardOutput: String, standardError: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        if let agentArgument {
            // Launch through a parent shell whose arguments end with `agentArgument`, the way an agent
            // started as `claude --print` would. The trailing `true` keeps bash from exec'ing the script.
            let hook = "/bin/bash \(HookFile.shellQuote(script.path)); true"
            let command = agentWrapsHookInShell ? "/bin/bash -c \"\(hook)\"; true" : hook
            process.arguments = ["-c", command, agentArgument]
        } else {
            process.arguments = [script.path]
        }
        process.currentDirectoryURL = workingDirectory
        process.environment = Self.agentLikeEnvironment.merging(extraEnvironment) { _, new in new }

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        // A hook that exits before reading stdin must fail the test, not kill the test process with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()

        try? input.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
        try? input.fileHandleForWriting.close()

        let pendingOutput = readConcurrently(output.fileHandleForReading)
        let pendingError = readConcurrently(error.fileHandleForReading)

        let deadline = Date().addingTimeInterval(Self.hookTimeout)
        guard let outputData = pendingOutput.wait(until: deadline),
              let errorData = pendingError.wait(until: deadline) else {
            process.terminate()
            throw HookDidNotFinish(timeout: Self.hookTimeout)
        }

        process.waitUntilExit()

        return (
            String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func readConcurrently(_ handle: FileHandle) -> PendingRead {
        let pending = PendingRead()
        DispatchQueue.global().async {
            pending.finish(handle.readDataToEndOfFile())
        }
        return pending
    }

    private func waitUntil(
        timeout: TimeInterval,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if await condition() {
                return true
            }

            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        return await condition()
    }
}

private struct HookDidNotFinish: Error {
    let timeout: TimeInterval
}

private struct ServerDidNotBind: Error {
    let path: String
}

private final class PendingRead: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var data = Data()

    func finish(_ value: Data) {
        data = value
        semaphore.signal()
    }

    func wait(until deadline: Date) -> Data? {
        let remaining = max(0, deadline.timeIntervalSinceNow)
        guard semaphore.wait(timeout: .now() + remaining) == .success else { return nil }
        return data
    }
}
