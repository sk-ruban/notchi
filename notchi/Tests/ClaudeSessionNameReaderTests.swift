import XCTest
@testable import notchi

final class ClaudeSessionNameReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSessionNameReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testReadsUserSetName() throws {
        try writeRegistry(processId: 101, #"{"sessionId":"s-1","name":"tally-domain-audit","nameSource":"user"}"#)

        XCTAssertEqual(ClaudeSessionNameReader.name(forProcessId: 101, sessionId: "s-1", in: root), "tally-domain-audit")
    }

    func testReadsNameWithoutNameSource() throws {
        try writeRegistry(processId: 101, #"{"sessionId":"s-1","name":"endorsement-audit"}"#)

        XCTAssertEqual(ClaudeSessionNameReader.name(forProcessId: 101, sessionId: "s-1", in: root), "endorsement-audit")
    }

    func testIgnoresGeneratedNames() throws {
        try writeRegistry(processId: 101, #"{"sessionId":"s-1","name":"notchi-66","nameSource":"derived"}"#)
        try writeRegistry(processId: 102, #"{"sessionId":"s-2","name":"fix-login-bug","nameSource":"auto"}"#)
        try writeRegistry(processId: 103, #"{"sessionId":"s-3","name":"notchi-66-2","nameSource":"collision"}"#)

        XCTAssertNil(ClaudeSessionNameReader.name(forProcessId: 101, sessionId: "s-1", in: root))
        XCTAssertNil(ClaudeSessionNameReader.name(forProcessId: 102, sessionId: "s-2", in: root))
        XCTAssertNil(ClaudeSessionNameReader.name(forProcessId: 103, sessionId: "s-3", in: root))
    }

    func testIgnoresRegistryOwnedByAnotherSession() throws {
        try writeRegistry(processId: 101, #"{"sessionId":"s-1","name":"tally-domain-audit","nameSource":"user"}"#)

        XCTAssertNil(ClaudeSessionNameReader.name(forProcessId: 101, sessionId: "other", in: root))
    }

    func testMissingRegistryReturnsNil() {
        XCTAssertNil(ClaudeSessionNameReader.name(forProcessId: 101, sessionId: "s-1", in: root))
    }

    private func writeRegistry(processId: Int, _ json: String) throws {
        try json.write(
            to: root.appendingPathComponent("sessions/\(processId).json"),
            atomically: true,
            encoding: .utf8
        )
    }
}
