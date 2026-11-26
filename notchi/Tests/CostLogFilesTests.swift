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
}
