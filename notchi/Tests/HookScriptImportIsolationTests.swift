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

    func testBundledHooksRunPythonInIsolatedMode() throws {
        for name in Self.bundledHookNames {
            let script = try String(contentsOf: bundledScriptURL(named: name), encoding: .utf8)
            XCTAssertTrue(
                script.contains("/usr/bin/python3 -I -c"),
                "\(name).sh must run python in isolated mode so the session cwd cannot shadow the stdlib"
            )
        }
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

    private func uniqueSocketPath() -> String {
        "/tmp/notchi-isolation-\(UUID().uuidString.prefix(8)).sock"
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
        let original = try String(contentsOf: bundledScriptURL(named: name), encoding: .utf8)
        let defaultAssignment = "SOCKET_PATH=\"/tmp/notchi.sock\""
        XCTAssertTrue(original.contains(defaultAssignment), "\(name).sh no longer declares the default socket path")

        let staged = original.replacingOccurrences(
            of: defaultAssignment,
            with: "SOCKET_PATH=\"\(socketPath)\""
        )
        let url = try XCTUnwrap(stagingDirectory).appendingPathComponent("\(name).sh")
        try staged.write(to: url, atomically: true, encoding: .utf8)
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
        extraEnvironment: [String: String] = [:]
    ) throws -> (standardOutput: String, standardError: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = workingDirectory
        process.environment = Self.agentLikeEnvironment.merging(extraEnvironment) { _, new in new }

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        try process.run()

        input.fileHandleForWriting.write(Data(payload.utf8))
        input.fileHandleForWriting.closeFile()

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
