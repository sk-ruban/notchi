import Foundation
import XCTest
@testable import notchi

final class ProcessRunnerTests: XCTestCase {
    // A child blocks once it fills the pipe (64 KB) until someone reads it.
    private static let largeOutputByteCount = 200_000
    private static let commandTimeout: TimeInterval = 2
    private static let shortTimeout: TimeInterval = 0.2
    private static let longRunningSeconds = "5"
    private static let stdoutAfterStderr = "done"

    func testOutputLargerThanThePipeBufferIsReturnedWhole() {
        let output = runProcessWithTimeout(
            executablePath: "/usr/bin/head",
            arguments: ["-c", "\(Self.largeOutputByteCount)", "/dev/zero"],
            commandTimeout: Self.commandTimeout
        )

        XCTAssertEqual(output, Data(count: Self.largeOutputByteCount))
    }

    func testStdoutIsReturnedAfterMoreThanThePipeBufferGoesToStderr() {
        let output = runProcessWithTimeout(
            executablePath: "/bin/sh",
            arguments: ["-c", "head -c \(Self.largeOutputByteCount) /dev/zero >&2; printf '\(Self.stdoutAfterStderr)'"],
            commandTimeout: Self.commandTimeout
        )

        XCTAssertEqual(output, Data(Self.stdoutAfterStderr.utf8))
    }

    func testProcessOutlivingTheTimeoutReturnsNil() {
        let output = runProcessWithTimeout(
            executablePath: "/bin/sleep",
            arguments: [Self.longRunningSeconds],
            commandTimeout: Self.shortTimeout
        )

        XCTAssertNil(output)
    }

    func testProcessThatCannotStartReturnsNil() {
        let output = runProcessWithTimeout(
            executablePath: "/nonexistent/tool",
            arguments: [],
            commandTimeout: Self.commandTimeout
        )

        XCTAssertNil(output)
    }
}
