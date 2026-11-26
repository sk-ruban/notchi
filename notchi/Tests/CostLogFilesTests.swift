import XCTest
@testable import notchi

final class CostLogFilesTests: XCTestCase {
    private func offset(of marker: String, in line: String, from start: Int = 0) -> Int? {
        Array(line.utf8).withUnsafeBytes { LogLineMarker(marker).offset(in: $0, from: start) }
    }

    func testMarkerIsFoundAtTheStartMiddleAndEndOfALine() {
        let expected = [0, 4, 8]
        XCTAssertEqual([offset(of: "usage", in: "usage..."),
                        offset(of: "usage", in: "....usage..."),
                        offset(of: "usage", in: "........usage")], expected)
    }

    func testMarkerRightAfterAPartialMatchIsFound() {
        let expectedOffset = 1
        XCTAssertEqual(offset(of: "aab", in: "aaab"), expectedOffset)
    }

    func testSearchFromAnOffsetSkipsEarlierMatches() {
        let expectedOffset = 6
        XCTAssertEqual(offset(of: "ab", in: "ab....ab", from: 1), expectedOffset)
    }

    func testMarkerMissingFromTheLineOrLongerThanItIsNotFound() {
        XCTAssertEqual([offset(of: "usage", in: "usag"), offset(of: "usage", in: "no match here")], [nil, nil])
    }

    func testForEachLineStopsBeforeAnUnterminatedLastLine() throws {
        let firstLine = "first"
        let secondLine = "second"
        let expectedOffset = Int64(firstLine.utf8.count + secondLine.utf8.count + 2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("\(firstLine)\n\(secondLine)\npartial".utf8).write(to: url)

        var lines: [String] = []
        let offset = CostLogFiles.forEachLine(in: url, from: 0) { lines.append(String(decoding: $0, as: UTF8.self)) }

        XCTAssertEqual(lines, [firstLine, secondLine])
        XCTAssertEqual(offset, expectedOffset)
    }

    func testForEachLineResumesFromTheGivenOffset() throws {
        let firstLine = "first"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("\(firstLine)\nsecond\n".utf8).write(to: url)

        var lines: [String] = []
        _ = CostLogFiles.forEachLine(in: url, from: Int64(firstLine.utf8.count + 1)) {
            lines.append(String(decoding: $0, as: UTF8.self))
        }

        XCTAssertEqual(lines, ["second"])
    }

    func testForEachLineOfAnEmptyOrMissingFileReturnsTheStartOffset() throws {
        let startOffset: Int64 = 7
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: empty) }
        try Data().write(to: empty)

        let offsets = [empty, missing].map { CostLogFiles.forEachLine(in: $0, from: startOffset) { _ in } }

        XCTAssertEqual(offsets, [startOffset, startOffset])
    }

    private static let cutoffDay = Array("2026-05-24".utf8)

    private func isDated(_ line: String) -> Bool {
        Array(line.utf8).withUnsafeBytes { CostLogLine.isDated($0, before: Self.cutoffDay) }
    }

    func testLineDatedTheDayBeforeTheCutoffIsDated() {
        XCTAssertTrue(isDated(#"{"timestamp":"2026-05-23T23:59:59.999Z"}"#))
    }

    func testLineDatedOnTheCutoffDayIsNotDated() {
        XCTAssertFalse(isDated(#"{"timestamp":"2026-05-24T00:00:00.000Z"}"#))
    }

    func testLineWithAnyTimestampOnOrAfterTheCutoffIsNotDated() {
        XCTAssertFalse(isDated(#"{"input":{"timestamp":"2020-01-01"},"timestamp":"2026-06-24T12:00:00Z"}"#))
    }

    func testLineWhoseTimestampIsSpacedNumericTruncatedOrMissingIsNotDated() {
        let lines = [#"{"timestamp": "2020-01-01T00:00:00Z"}"#, #"{"timestamp":1577836800}"#,
                     #"{"timestamp":"2020-0"#, #"{"type":"assistant"}"#]
        XCTAssertEqual(lines.map(isDated), [false, false, false, false])
    }
}
