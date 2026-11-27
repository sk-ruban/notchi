import Foundation

/// Runs a command and returns what it wrote to stdout, or nil when it can't start or outlives `commandTimeout`.
nonisolated func runProcessWithTimeout(
    executablePath: String,
    arguments: [String],
    environment: [String: String]? = nil,
    commandTimeout: TimeInterval
) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.environment = environment

    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = FileHandle.nullDevice

    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in
        exited.signal()
    }

    do {
        try process.run()
    } catch {
        return nil
    }

    // A child that fills the pipe (64 KB) blocks until it's read, so stdout is drained while
    // waiting rather than after; otherwise any larger output would end in a timeout.
    let output = ProcessOutput()
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        output.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        drained.signal()
    }

    let deadline = DispatchTime.now() + commandTimeout
    guard exited.wait(timeout: deadline) == .success,
          drained.wait(timeout: deadline) == .success else {
        process.terminate()
        return nil
    }
    return output.data
}

/// Written by the drain before it signals, and read only after that signal.
nonisolated private final class ProcessOutput: @unchecked Sendable {
    var data = Data()
}

nonisolated func extractAbsolutePath(from output: String) -> String? {
    output
        .split(separator: "\n")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .last { $0.hasPrefix("/") || $0.hasPrefix("~") }
}

/// The login shell first, then the system shells, each once.
nonisolated func shellCandidates(from environment: [String: String]) -> [String] {
    var seenShells: Set<String> = []
    return [environment["SHELL"], "/bin/zsh", "/bin/bash"]
        .compactMap { $0 }
        .filter { seenShells.insert($0).inserted }
}

/// What a resolver reads from the system while probing shells, replaceable in tests.
nonisolated struct ShellProbeTestHooks: Sendable {
    let environment: @Sendable () -> [String: String]
    let isExecutableFile: @Sendable (String) -> Bool
    let runProcess: @Sendable (
        _ executablePath: String,
        _ arguments: [String],
        _ environment: [String: String]?
    ) -> String?

    static func live(commandTimeout: TimeInterval) -> Self {
        Self(
            environment: { ProcessInfo.processInfo.environment },
            isExecutableFile: { path in
                FileManager.default.isExecutableFile(atPath: path)
            },
            runProcess: { executablePath, arguments, environment in
                runProcessWithTimeout(
                    executablePath: executablePath,
                    arguments: arguments,
                    environment: environment,
                    commandTimeout: commandTimeout
                ).flatMap { String(data: $0, encoding: .utf8) }
            }
        )
    }
}
