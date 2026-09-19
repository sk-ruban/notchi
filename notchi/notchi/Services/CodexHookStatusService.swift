import Foundation
import Darwin

nonisolated enum CodexHookReadiness: Equatable, Sendable {
    case approved
    case needsApproval
    case disabled
    case notRegistered
    case unverified
}

nonisolated struct CodexHookSetup: Equatable, Sendable {
    let executableURL: URL?
    let readiness: CodexHookReadiness

    var launchCommand: String? {
        executableURL.map { CodexHookStatusService.shellQuote($0.path) }
    }
}

nonisolated enum CodexHookStatusService {
    static func executableCandidates(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationURLs: [URL] = [],
        path: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) -> [URL] {
        // Prefer the desktop runtime so an older, separately installed CLI does
        // not report a different hook policy from the app the user is using.
        let applications = applicationURLs + [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            URL(fileURLWithPath: "/Applications/Codex.app"),
            home.appendingPathComponent("Applications/ChatGPT.app"),
            home.appendingPathComponent("Applications/Codex.app"),
        ]
        let directories = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
            + path.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        return applications.map { $0.appendingPathComponent("Contents/Resources/codex") }
            + directories.map { URL(fileURLWithPath: $0).appendingPathComponent("codex") }
    }

    static func resolveExecutable(
        candidates: [URL],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        candidates.first { isExecutable($0.path) }
    }

    static func check(applicationURLs: [URL] = []) -> CodexHookSetup {
        let executable = resolveExecutable(candidates: executableCandidates(applicationURLs: applicationURLs))
        guard let executable else {
            return CodexHookSetup(executableURL: nil, readiness: .unverified)
        }
        let response = queryHooks(executable: executable)
        return CodexHookSetup(executableURL: executable, readiness: response.map { readiness(from: $0) } ?? .unverified)
    }

    static func readiness(from response: Data, command: String = CodexHookInstaller.hookCommand) -> CodexHookReadiness {
        guard let root = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              root["error"] == nil,
              let result = root["result"] as? [String: Any],
              let entries = result["data"] as? [[String: Any]],
              entries.count == 1,
              let entry = entries.first,
              let errors = entry["errors"] as? [Any], errors.isEmpty,
              let warnings = entry["warnings"] as? [String], warnings.isEmpty,
              let hooks = entry["hooks"] as? [[String: Any]] else { return .unverified }

        let expectedEvents: Set<String> = ["sessionStart", "userPromptSubmit", "stop"]
        let notchiHooks = hooks.filter { ($0["command"] as? String) == command }
        let relevant = notchiHooks.filter { expectedEvents.contains($0["eventName"] as? String ?? "") }
        guard Set(relevant.compactMap { $0["eventName"] as? String }) == expectedEvents else {
            return .notRegistered
        }
        if relevant.contains(where: { ($0["enabled"] as? Bool) == false }) { return .disabled }
        if relevant.contains(where: { ["untrusted", "modified"].contains($0["trustStatus"] as? String ?? "") }) {
            return .needsApproval
        }
        guard relevant.allSatisfy({
            ($0["enabled"] as? Bool) == true && ["trusted", "managed"].contains($0["trustStatus"] as? String ?? "")
        }) else { return .unverified }
        return .approved
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func launcherContents(executable: URL, home: URL) -> String {
        "#!/bin/sh\ncd \(shellQuote(home.path)) || exit 1\nexec \(shellQuote(executable.path))\n"
    }

    static func writeLauncher(executable: URL) throws -> URL {
        let fileManager = FileManager.default
        let directory = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Notchi", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Codex Setup.command")
        try launcherContents(executable: executable, home: fileManager.homeDirectoryForCurrentUser)
            .write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    static func queryHooks(executable: URL, timeout: TimeInterval = 5) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        let home = FileManager.default.homeDirectoryForCurrentUser
        process.currentDirectoryURL = home
        // Match the directory where Notchi installs its hooks, even if Notchi
        // was launched from a shell with a different CODEX_HOME.
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = CodexHookInstaller.codexDirectoryURL.path
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let replies = CodexHookReplies()
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        output.fileHandleForReading.readabilityHandler = { handle in
            replies.append(handle.availableData)
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                if exited.wait(timeout: .now() + 0.5) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + 0.5)
                }
            }
            try? output.fileHandleForReading.close()
        }
        let deadline = DispatchTime.now() + timeout
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        do {
            // A missing/older app-server can exit before receiving a request.
            // A broken pipe must fail the check, not terminate the Notchi app.
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { return nil }
            try process.run()
            try send([
                "id": 1, "method": "initialize",
                "params": [
                    "clientInfo": ["name": "notchi_hook_setup", "version": "1.0"],
                    "capabilities": ["experimentalApi": true],
                ],
            ])
            guard let initialized = replies.wait(for: 1, until: deadline),
                  let object = try JSONSerialization.jsonObject(with: initialized) as? [String: Any],
                  object["result"] != nil else { return nil }
            try send(["method": "initialized", "params": [:]])
            // Checking the home layer avoids loading arbitrary project configuration.
            // No thread is started and no hooks or model requests are executed.
            try send(["id": 2, "method": "hooks/list", "params": ["cwds": [home.path]]])
            return replies.wait(for: 2, until: deadline)
        } catch {
            return nil
        }
    }
}

private nonisolated final class CodexHookReplies: @unchecked Sendable {
    private let lock = NSLock()
    private let available = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var responses: [Int: Data] = [:]
    private var finished = false

    func append(_ data: Data) {
        lock.withLock {
            guard !finished else { return }
            guard !data.isEmpty, buffer.count + data.count <= 1_048_576 else {
                finished = true
                return
            }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let id = object["id"] as? Int, id == 1 || id == 2 {
                    responses[id] = line
                }
            }
        }
        available.signal()
    }

    func wait(for id: Int, until deadline: DispatchTime) -> Data? {
        while true {
            let (response, ended) = lock.withLock { (responses.removeValue(forKey: id), finished) }
            if let response { return response }
            if ended || available.wait(timeout: deadline) == .timedOut { return nil }
        }
    }
}
