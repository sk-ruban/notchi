import XCTest
@testable import notchi

final class GitPullRequestResolverTests: XCTestCase {
    private static let openPRJSON = Data(#"{"number":115,"url":"https://github.com/sk-ruban/notchi/pull/115","state":"OPEN"}"#.utf8)

    func testParseReturnsOpenPullRequest() {
        XCTAssertEqual(
            GitPullRequestResolver.parse(Self.openPRJSON),
            GitPullRequest(number: 115, url: "https://github.com/sk-ruban/notchi/pull/115")
        )
    }

    func testParseIgnoresMergedPullRequest() {
        let json = Data(#"{"number":114,"url":"https://github.com/sk-ruban/notchi/pull/114","state":"MERGED"}"#.utf8)
        XCTAssertNil(GitPullRequestResolver.parse(json))
    }

    func testParseReturnsNilForMalformedOutput() {
        XCTAssertNil(GitPullRequestResolver.parse(Data("no pull requests found".utf8)))
        XCTAssertNil(GitPullRequestResolver.parse(Data(#"{"state":"OPEN","url":"x"}"#.utf8)))
    }

    func testResultIsCachedWithinLifetime() {
        let fetchCount = Counter()
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in fetchCount.increment(); return Self.openPRJSON },
            currentBranch: { _ in "main" },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        let first = resolver.pullRequest(forBranch: "main", repositoryAt: "/repo")
        let second = resolver.pullRequest(forBranch: "main", repositoryAt: "/repo")

        XCTAssertEqual(first?.number, 115)
        XCTAssertEqual(second, first)
        XCTAssertEqual(fetchCount.value, 1)
    }

    func testMissingPullRequestIsAlsoCached() {
        let fetchCount = Counter()
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in fetchCount.increment(); return nil },
            currentBranch: { _ in "main" },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        XCTAssertNil(resolver.pullRequest(forBranch: "main", repositoryAt: "/repo"))
        XCTAssertNil(resolver.pullRequest(forBranch: "main", repositoryAt: "/repo"))
        XCTAssertEqual(fetchCount.value, 1)
    }

    func testHitCacheExpiresAfterTwoMinutes() {
        let fetchCount = Counter()
        let clock = MutableClock(Date(timeIntervalSinceReferenceDate: 1000))
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in fetchCount.increment(); return Self.openPRJSON },
            currentBranch: { _ in "main" },
            now: { clock.value }
        )

        _ = resolver.pullRequest(forBranch: "main", repositoryAt: "/repo")
        clock.value = Date(timeIntervalSinceReferenceDate: 1119)
        _ = resolver.pullRequest(forBranch: "main", repositoryAt: "/repo")
        XCTAssertEqual(fetchCount.value, 1)

        clock.value = Date(timeIntervalSinceReferenceDate: 1121)
        _ = resolver.pullRequest(forBranch: "main", repositoryAt: "/repo")
        XCTAssertEqual(fetchCount.value, 2)
    }

    func testMissIsRetriedAfterTwentySeconds() {
        let fetchCount = Counter()
        let clock = MutableClock(Date(timeIntervalSinceReferenceDate: 1000))
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in fetchCount.increment(); return fetchCount.value > 1 ? Self.openPRJSON : nil },
            currentBranch: { _ in "main" },
            now: { clock.value }
        )

        XCTAssertNil(resolver.pullRequest(forBranch: "main", repositoryAt: "/repo"))
        clock.value = Date(timeIntervalSinceReferenceDate: 1019)
        XCTAssertNil(resolver.pullRequest(forBranch: "main", repositoryAt: "/repo"))
        XCTAssertEqual(fetchCount.value, 1)

        clock.value = Date(timeIntervalSinceReferenceDate: 1021)
        XCTAssertEqual(resolver.pullRequest(forBranch: "main", repositoryAt: "/repo")?.number, 115)
        XCTAssertEqual(fetchCount.value, 2)
    }

    func testConcurrentMissesSpawnOnlyOneFetch() {
        let fetchCount = Counter()
        let fetchStarted = DispatchSemaphore(value: 0)
        let releaseFetch = DispatchSemaphore(value: 0)
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in
                fetchCount.increment()
                fetchStarted.signal()
                releaseFetch.wait()
                return Self.openPRJSON
            },
            currentBranch: { _ in "main" },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        let slowResult = ResultBox()
        DispatchQueue.global().async {
            slowResult.store(resolver.pullRequest(forBranch: "main", repositoryAt: "/repo"))
        }
        XCTAssertEqual(fetchStarted.wait(timeout: .now() + 2), .success)

        XCTAssertNil(resolver.pullRequest(forBranch: "main", repositoryAt: "/repo"))
        XCTAssertEqual(fetchCount.value, 1)

        releaseFetch.signal()
        XCTAssertEqual(slowResult.wait(timeout: 2)??.number, 115)
    }

    func testResultForAStaleBranchIsDiscardedAndNotCached() {
        let fetchCount = Counter()
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in fetchCount.increment(); return Self.openPRJSON },
            currentBranch: { _ in "other-branch" },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        XCTAssertNil(resolver.pullRequest(forBranch: "main", repositoryAt: "/repo"))
        XCTAssertNil(resolver.pullRequest(forBranch: "main", repositoryAt: "/repo"))
        XCTAssertEqual(fetchCount.value, 2)
    }

    func testRunProcessTerminatesStalledProcessAtTimeout() {
        let start = Date()
        let output = GitPullRequestResolver.runProcess(
            executable: "/bin/sleep",
            arguments: ["30"],
            cwd: "/tmp",
            timeout: 0.3
        )

        XCTAssertNil(output)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testRunProcessKillsProcessThatIgnoresSigterm() {
        let start = Date()
        let output = GitPullRequestResolver.runProcess(
            executable: "/bin/sh",
            arguments: ["-c", "trap \'\' TERM; sleep 30"],
            cwd: "/tmp",
            timeout: 0.3
        )

        XCTAssertNil(output)
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
    }

    func testRunProcessReturnsOutputWhenChildHoldsPipeOpen() {
        let start = Date()
        let output = GitPullRequestResolver.runProcess(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30 & echo captured"],
            cwd: "/tmp",
            timeout: 5
        )

        XCTAssertEqual(output.flatMap { String(data: $0, encoding: .utf8) }, "captured\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
    }

    func testDifferentBranchesAreCachedSeparately() {
        let fetchCount = Counter()
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in fetchCount.increment(); return Self.openPRJSON },
            currentBranch: { _ in "main" },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        _ = resolver.pullRequest(forBranch: "main", repositoryAt: "/repo")
        _ = resolver.pullRequest(forBranch: "feature", repositoryAt: "/repo")

        XCTAssertEqual(fetchCount.value, 2)
    }
}

private nonisolated final class ResultBox: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: GitPullRequest??

    func store(_ value: GitPullRequest?) {
        lock.withLock { result = value }
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> GitPullRequest?? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return lock.withLock { result }
    }
}

private nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private nonisolated final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var value: Date {
        get { lock.withLock { date } }
        set { lock.withLock { date = newValue } }
    }
}
