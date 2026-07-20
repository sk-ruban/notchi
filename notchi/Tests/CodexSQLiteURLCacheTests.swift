import XCTest
@testable import notchi

nonisolated final class CodexSQLiteURLCacheTests: XCTestCase {
    private static let ttl: TimeInterval = 60

    private nonisolated final class Recorder: @unchecked Sendable {
        var listedPrefixes: [String] = []
        var urlsByPrefix: [String: URL] = [:]
        var existingPaths: Set<String> = []
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        private let lock = NSLock()

        func list(_ prefix: String) -> URL? {
            lock.lock()
            defer { lock.unlock() }
            listedPrefixes.append(prefix)
            return urlsByPrefix[prefix]
        }

        func fileExists(_ url: URL) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return existingPaths.contains(url.path)
        }

        func listCount(for prefix: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return listedPrefixes.count { $0 == prefix }
        }
    }

    private func makeCache(recorder: Recorder) -> CodexSQLiteURLCache {
        CodexSQLiteURLCache(
            ttl: Self.ttl,
            list: { recorder.list($0) },
            fileExists: { recorder.fileExists($0) },
            now: { recorder.now }
        )
    }

    private func registerURL(_ recorder: Recorder, prefix: String, path: String) {
        let url = URL(fileURLWithPath: path)
        recorder.urlsByPrefix[prefix] = url
        recorder.existingPaths.insert(url.path)
    }

    func testSecondLookupWithinTTLReturnsCachedURLWithoutRelisting() {
        let recorder = Recorder()
        registerURL(recorder, prefix: "state_", path: "/tmp/codex/state_3.sqlite")
        let cache = makeCache(recorder: recorder)

        let first = cache.url(prefix: "state_")
        recorder.now = recorder.now.addingTimeInterval(Self.ttl - 1)
        let second = cache.url(prefix: "state_")

        XCTAssertEqual(first?.path, "/tmp/codex/state_3.sqlite")
        XCTAssertEqual(second?.path, "/tmp/codex/state_3.sqlite")
        XCTAssertEqual(recorder.listCount(for: "state_"), 1)
    }

    func testLookupAfterTTLExpiryRelistsAndPicksUpNewerDatabase() {
        let recorder = Recorder()
        registerURL(recorder, prefix: "state_", path: "/tmp/codex/state_3.sqlite")
        let cache = makeCache(recorder: recorder)

        _ = cache.url(prefix: "state_")
        registerURL(recorder, prefix: "state_", path: "/tmp/codex/state_4.sqlite")
        recorder.now = recorder.now.addingTimeInterval(Self.ttl + 1)
        let refreshed = cache.url(prefix: "state_")

        XCTAssertEqual(refreshed?.path, "/tmp/codex/state_4.sqlite")
        XCTAssertEqual(recorder.listCount(for: "state_"), 2)
    }

    func testLookupRelistsWhenCachedFileDisappears() {
        let recorder = Recorder()
        registerURL(recorder, prefix: "logs_", path: "/tmp/codex/logs_1.sqlite")
        let cache = makeCache(recorder: recorder)

        _ = cache.url(prefix: "logs_")
        recorder.existingPaths.remove("/tmp/codex/logs_1.sqlite")
        registerURL(recorder, prefix: "logs_", path: "/tmp/codex/logs_2.sqlite")
        let refreshed = cache.url(prefix: "logs_")

        XCTAssertEqual(refreshed?.path, "/tmp/codex/logs_2.sqlite")
        XCTAssertEqual(recorder.listCount(for: "logs_"), 2)
    }

    func testPrefixesAreCachedIndependently() {
        let recorder = Recorder()
        registerURL(recorder, prefix: "state_", path: "/tmp/codex/state_3.sqlite")
        registerURL(recorder, prefix: "logs_", path: "/tmp/codex/logs_1.sqlite")
        let cache = makeCache(recorder: recorder)

        XCTAssertEqual(cache.url(prefix: "state_")?.path, "/tmp/codex/state_3.sqlite")
        XCTAssertEqual(cache.url(prefix: "logs_")?.path, "/tmp/codex/logs_1.sqlite")
        XCTAssertEqual(cache.url(prefix: "state_")?.path, "/tmp/codex/state_3.sqlite")
        XCTAssertEqual(recorder.listCount(for: "state_"), 1)
        XCTAssertEqual(recorder.listCount(for: "logs_"), 1)
    }

    func testMissingDatabaseIsNotCachedAndRelistsOnNextLookup() {
        let recorder = Recorder()
        let cache = makeCache(recorder: recorder)

        XCTAssertNil(cache.url(prefix: "state_"))
        registerURL(recorder, prefix: "state_", path: "/tmp/codex/state_1.sqlite")
        let found = cache.url(prefix: "state_")

        XCTAssertEqual(found?.path, "/tmp/codex/state_1.sqlite")
        XCTAssertEqual(recorder.listCount(for: "state_"), 2)
    }
}
