import XCTest
@testable import notchi

@MainActor
final class CodexUsageScannerTests: XCTestCase {
    private var rolloutURL: URL!

    override func setUp() {
        super.setUp()
        rolloutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-scanner-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: rolloutURL)
        super.tearDown()
    }

    func testFirstScanReadsWholeFileAndSubsequentScanReadsOnlyAppendedBytes() throws {
        let firstLine = tokenCountLine(usedPercent: 11, timestamp: "2026-04-25T07:01:00.000Z")
        let appendedLine = tokenCountLine(usedPercent: 23, timestamp: "2026-04-25T07:03:14.886Z")
        try firstLine.write(to: rolloutURL, atomically: true, encoding: .utf8)
        let scanner = CodexUsageScanner()

        let initial = scanner.latestSnapshot(transcriptPaths: [rolloutURL.path])
        XCTAssertEqual(initial?.usage.usagePercentage, 11)
        XCTAssertEqual(scanner.bytesReadForTesting, UInt64(firstLine.utf8.count))

        try append(appendedLine, to: rolloutURL)
        let updated = scanner.latestSnapshot(transcriptPaths: [rolloutURL.path])

        XCTAssertEqual(updated?.usage.usagePercentage, 23)
        XCTAssertEqual(
            scanner.bytesReadForTesting,
            UInt64(firstLine.utf8.count + appendedLine.utf8.count)
        )
    }

    func testScanOfUnchangedFileReadsNoBytesAndReturnsCachedSnapshot() throws {
        let line = tokenCountLine(usedPercent: 42, timestamp: "2026-04-25T07:03:14.886Z")
        try line.write(to: rolloutURL, atomically: true, encoding: .utf8)
        let scanner = CodexUsageScanner()

        let first = scanner.latestSnapshot(transcriptPaths: [rolloutURL.path])
        let bytesAfterFirstScan = scanner.bytesReadForTesting
        let second = scanner.latestSnapshot(transcriptPaths: [rolloutURL.path])

        XCTAssertEqual(first, second)
        XCTAssertEqual(second?.usage.usagePercentage, 42)
        XCTAssertEqual(scanner.bytesReadForTesting, bytesAfterFirstScan)
    }

    func testTruncatedFileIsRescannedFromScratch() throws {
        let longLine = tokenCountLine(usedPercent: 55, timestamp: "2026-04-25T07:01:00.000Z")
        let shortLine = tokenCountLine(usedPercent: 8, timestamp: "2026-04-25T06:00:00.000Z")
        try (longLine + longLine).write(to: rolloutURL, atomically: true, encoding: .utf8)
        let scanner = CodexUsageScanner()

        XCTAssertEqual(scanner.latestSnapshot(transcriptPaths: [rolloutURL.path])?.usage.usagePercentage, 55)

        try shortLine.write(to: rolloutURL, atomically: true, encoding: .utf8)
        let rescanned = scanner.latestSnapshot(transcriptPaths: [rolloutURL.path])

        XCTAssertEqual(rescanned?.usage.usagePercentage, 8)
        XCTAssertEqual(
            rescanned?.observedAt.timeIntervalSince1970 ?? 0,
            parseISO("2026-04-25T06:00:00.000Z").timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testAppendedLinesWithoutTokenCountKeepPreviousSnapshot() throws {
        let line = tokenCountLine(usedPercent: 33, timestamp: "2026-04-25T07:03:14.886Z")
        try line.write(to: rolloutURL, atomically: true, encoding: .utf8)
        let scanner = CodexUsageScanner()

        XCTAssertEqual(scanner.latestSnapshot(transcriptPaths: [rolloutURL.path])?.usage.usagePercentage, 33)

        try append("{\"timestamp\":\"2026-04-25T07:04:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\"}}\n", to: rolloutURL)
        let after = scanner.latestSnapshot(transcriptPaths: [rolloutURL.path])

        XCTAssertEqual(after?.usage.usagePercentage, 33)
    }

    func testUnterminatedFinalLineIsNotSkippedOnceCompleted() throws {
        let firstLine = tokenCountLine(usedPercent: 11, timestamp: "2026-04-25T07:01:00.000Z")
        let secondLine = tokenCountLine(usedPercent: 77, timestamp: "2026-04-25T07:05:00.000Z")
        let splitIndex = secondLine.index(secondLine.startIndex, offsetBy: 40)
        try (firstLine + String(secondLine[..<splitIndex])).write(to: rolloutURL, atomically: true, encoding: .utf8)
        let scanner = CodexUsageScanner()

        XCTAssertEqual(scanner.latestSnapshot(transcriptPaths: [rolloutURL.path])?.usage.usagePercentage, 11)

        try append(String(secondLine[splitIndex...]), to: rolloutURL)
        let completed = scanner.latestSnapshot(transcriptPaths: [rolloutURL.path])

        XCTAssertEqual(completed?.usage.usagePercentage, 77)
    }

    func testLatestSnapshotAcrossPathsPicksMostRecentObservation() throws {
        let olderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-scanner-older-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: olderURL) }
        try tokenCountLine(usedPercent: 5, timestamp: "2026-04-25T06:00:00.000Z")
            .write(to: olderURL, atomically: true, encoding: .utf8)
        try tokenCountLine(usedPercent: 61, timestamp: "2026-04-25T07:05:00.000Z")
            .write(to: rolloutURL, atomically: true, encoding: .utf8)
        let scanner = CodexUsageScanner()

        let snapshot = scanner.latestSnapshot(transcriptPaths: [olderURL.path, rolloutURL.path])

        XCTAssertEqual(snapshot?.usage.usagePercentage, 61)
    }

    private func tokenCountLine(usedPercent: Double, timestamp: String) -> String {
        "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":\(usedPercent),\"window_minutes\":300,\"resets_at\":1777103326}}}}\n"
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func parseISO(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)!
    }
}
