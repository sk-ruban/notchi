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
