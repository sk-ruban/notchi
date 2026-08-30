import XCTest
@testable import notchi

final class CodexPermissionModeReaderTests: XCTestCase {
    private var directory: URL!
    private var rollout: URL!
    private var reader: CodexPermissionModeReader!

    private static let readOnlyTurn = #"{"type":"turn_context","payload":{"approval_policy":"on-request","sandbox_policy":{"type":"read-only"}}}"#
    private static let workspaceTurn = #"{"type":"turn_context","payload":{"approval_policy":"on-request","sandbox_policy":{"type":"workspace-write"}}}"#
    private static let fullAccessTurn = #"{"type":"turn_context","payload":{"approval_policy":"never","sandbox_policy":{"type":"danger-full-access"}}}"#
    private static let planTurn = #"{"type":"turn_context","payload":{"approval_policy":"on-request","sandbox_policy":{"type":"workspace-write"},"collaboration_mode":{"mode":"plan","settings":{}}}}"#
    private static let sessionMeta = #"{"type":"session_meta","payload":{"id":"abc"}}"#
    private static let filler = #"{"type":"response_item","payload":{"type":"message","content":"\#(String(repeating: "x", count: 180))"}}"#

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexPermissionModeReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rollout = directory.appendingPathComponent("rollout.jsonl")
        reader = CodexPermissionModeReader()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: Mapping

    func testWorkspaceWriteSandboxIsDefault() {
        XCTAssertEqual(CodexPermissionMode.resolve(sandboxPolicy: ["type": "workspace-write"]), CodexPermissionMode.standard)
    }

    func testReadOnlySandboxIsReadOnly() {
        XCTAssertEqual(CodexPermissionMode.resolve(sandboxPolicy: ["type": "read-only"]), CodexPermissionMode.readOnly)
    }

    func testDangerFullAccessSandboxIsFullAccess() {
        XCTAssertEqual(CodexPermissionMode.resolve(sandboxPolicy: ["type": "danger-full-access"]), CodexPermissionMode.fullAccess)
    }

    func testApprovalNeverWithReadOnlySandboxIsStillReadOnly() throws {
        try write([#"{"type":"turn_context","payload":{"approval_policy":"never","sandbox_policy":{"type":"read-only"}}}"#])
        XCTAssertEqual(reader.mode(forTranscriptAt: rollout.path), CodexPermissionMode.readOnly)
    }

    func testApprovalNeverWithWorkspaceWriteIsStillDefault() throws {
        try write([#"{"type":"turn_context","payload":{"approval_policy":"never","sandbox_policy":{"type":"workspace-write"}}}"#])
        XCTAssertEqual(reader.mode(forTranscriptAt: rollout.path), CodexPermissionMode.standard)
    }

    func testManagedSandboxWithWriteEntryIsDefault() {
        let policy: [String: Any] = [
            "type": "managed",
            "file_system": ["entries": [
                ["path": ["type": "special"], "access": "read"],
                ["path": ["type": "path"], "access": "write"],
            ]],
        ]
        XCTAssertEqual(CodexPermissionMode.resolve(sandboxPolicy: policy), CodexPermissionMode.standard)
    }

    func testManagedSandboxWithOnlyReadEntriesIsReadOnly() {
        let policy: [String: Any] = [
            "type": "managed",
            "file_system": ["entries": [["path": ["type": "special"], "access": "read"]]],
        ]
        XCTAssertEqual(CodexPermissionMode.resolve(sandboxPolicy: policy), CodexPermissionMode.readOnly)
    }

    func testPlanCollaborationModeWinsOverSandbox() {
        XCTAssertEqual(
            CodexPermissionMode.resolve(collaborationMode: "plan", approvalsReviewer: "auto_review", sandboxPolicy: ["type": "danger-full-access"]),
            "plan"
        )
    }

    func testAutoReviewWinsOverSandbox() {
        XCTAssertEqual(
            CodexPermissionMode.resolve(collaborationMode: "default", approvalsReviewer: "auto_review", sandboxPolicy: ["type": "danger-full-access"]),
            "auto"
        )
    }

    func testUserReviewerFallsThroughToSandbox() {
        XCTAssertEqual(
            CodexPermissionMode.resolve(collaborationMode: "default", approvalsReviewer: "user", sandboxPolicy: ["type": "read-only"]),
            CodexPermissionMode.readOnly
        )
    }

    func testMissingSandboxFallsBackToDefault() {
        XCTAssertEqual(CodexPermissionMode.resolve(sandboxPolicy: nil), CodexPermissionMode.standard)
    }

    // MARK: Rollout scanning

    func testReadsLatestTurnContextFromRollout() throws {
        try write([Self.sessionMeta, Self.readOnlyTurn, Self.filler, Self.fullAccessTurn, Self.filler])
        XCTAssertEqual(reader.mode(forTranscriptAt: rollout.path), CodexPermissionMode.fullAccess)
    }

    func testReadsPlanCollaborationModeFromRollout() throws {
        try write([Self.planTurn])
        XCTAssertEqual(reader.mode(forTranscriptAt: rollout.path), "plan")
    }

    func testRolloutWithoutTurnContextReturnsNil() throws {
        try write([Self.sessionMeta])
        XCTAssertNil(reader.mode(forTranscriptAt: rollout.path))
    }

    func testMissingRolloutReturnsNil() {
        XCTAssertNil(reader.mode(forTranscriptAt: directory.appendingPathComponent("nope.jsonl").path))
        XCTAssertNil(reader.mode(forTranscriptAt: ""))
    }

    func testUnchangedRolloutIsNotReadAgain() throws {
        try write([Self.readOnlyTurn])
        XCTAssertEqual(reader.mode(forTranscriptAt: rollout.path), CodexPermissionMode.readOnly)
        let bytesAfterFirstRead = reader.bytesReadForTesting()

        XCTAssertEqual(reader.mode(forTranscriptAt: rollout.path), CodexPermissionMode.readOnly)
        XCTAssertEqual(reader.bytesReadForTesting(), bytesAfterFirstRead)
    }

    func testAppendedTurnContextReadsOnlyTheAppendedBytes() throws {
        try write([Self.sessionMeta, Self.readOnlyTurn])
        XCTAssertEqual(reader.mode(forTranscriptAt: rollout.path), CodexPermissionMode.readOnly)
        let bytesAfterFirstRead = reader.bytesReadForTesting()

        let appended = Self.filler + "\n" + Self.fullAccessTurn + "\n"
        try append(appended)

        XCTAssertEqual(reader.mode(forTranscriptAt: rollout.path), CodexPermissionMode.fullAccess)
        XCTAssertEqual(reader.bytesReadForTesting() - bytesAfterFirstRead, appended.utf8.count)
    }

    func testAppendedLinesWithoutTurnContextKeepPreviousMode() throws {
        try write([Self.fullAccessTurn])
        XCTAssertEqual(reader.mode(forTranscriptAt: rollout.path), CodexPermissionMode.fullAccess)

        try append(Self.filler + "\n" + Self.filler + "\n")

        XCTAssertEqual(reader.mode(forTranscriptAt: rollout.path), CodexPermissionMode.fullAccess)
    }

    func testPartiallyWrittenTrailingLineIsIgnoredUntilCompleted() throws {
        try write([Self.readOnlyTurn])
        XCTAssertEqual(reader.mode(forTranscriptAt: rollout.path), CodexPermissionMode.readOnly)

        let half = Self.fullAccessTurn.index(Self.fullAccessTurn.startIndex, offsetBy: 40)
        try append(String(Self.fullAccessTurn[..<half]))
        XCTAssertEqual(reader.mode(forTranscriptAt: rollout.path), CodexPermissionMode.readOnly)

        try append(String(Self.fullAccessTurn[half...]) + "\n")
        XCTAssertEqual(reader.mode(forTranscriptAt: rollout.path), CodexPermissionMode.fullAccess)
    }

    func testTruncatedRolloutIsRescanned() throws {
        try write([Self.sessionMeta, Self.filler, Self.filler, Self.fullAccessTurn])
        XCTAssertEqual(reader.mode(forTranscriptAt: rollout.path), CodexPermissionMode.fullAccess)

        try write([Self.readOnlyTurn])

        XCTAssertEqual(reader.mode(forTranscriptAt: rollout.path), CodexPermissionMode.readOnly)
    }

    func testLargeRolloutOnlyReadsTailUntilLatestTurnContext() throws {
        let fillerLineCount = 20_000
        var lines = [Self.sessionMeta, Self.readOnlyTurn]
        lines.append(contentsOf: Array(repeating: Self.filler, count: fillerLineCount))
        lines.append(Self.fullAccessTurn)
        lines.append(contentsOf: Array(repeating: Self.filler, count: 50))
        try write(lines)
        let fileSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: rollout.path)[.size] as? Int)
        XCTAssertGreaterThan(fileSize, 3_000_000)

        XCTAssertEqual(reader.mode(forTranscriptAt: rollout.path), CodexPermissionMode.fullAccess)
        XCTAssertLessThan(reader.bytesReadForTesting(), 600 * 1024)
    }

    func testTurnContextOlderThanOneChunkIsStillFound() throws {
        var lines = [Self.planTurn]
        lines.append(contentsOf: Array(repeating: Self.filler, count: 3_000))
        try write(lines)

        XCTAssertEqual(reader.mode(forTranscriptAt: rollout.path), "plan")
    }

    private func write(_ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: rollout, atomically: true, encoding: .utf8)
    }

    private func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: rollout)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
