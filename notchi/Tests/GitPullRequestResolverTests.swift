import XCTest
@testable import notchi

final class GitPullRequestResolverTests: XCTestCase {
    private nonisolated static let openPRJSON = Data(#"{"number":115,"url":"https://github.com/sk-ruban/notchi/pull/115","state":"OPEN"}"#.utf8)

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

        XCTAssertEqual(resolver.lookup(forBranch: "main", repositoryAt: "/repo"), .pending)
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

    func testRunProcessKillsProcessThatIgnoresSigterm() throws {
        let childPIDFile = try makeChildPIDFile()
        let start = Date()
        let output = GitPullRequestResolver.runProcess(
            executable: "/bin/sh",
            arguments: ["-c", "trap \'\' TERM; sleep 30 & echo $! > \(childPIDFile.path); wait $!"],
            cwd: "/tmp",
            timeout: 0.3
        )

        XCTAssertNil(output)
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
    }

    func testRunProcessReturnsOutputWhenChildHoldsPipeOpen() throws {
        let childPIDFile = try makeChildPIDFile()
        let start = Date()
        let output = GitPullRequestResolver.runProcess(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30 & echo $! > \(childPIDFile.path); echo captured"],
            cwd: "/tmp",
            timeout: 5
        )

        XCTAssertEqual(output.flatMap { String(data: $0, encoding: .utf8) }, "captured\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
    }

    private func makeChildPIDFile() throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitPullRequestResolverTests-child-\(UUID().uuidString).pid")
        addTeardownBlock {
            if let pid = (try? String(contentsOf: file, encoding: .utf8))
                .flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
                kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: file)
        }
        return file
    }

    func testConsecutiveMissesBackOffExponentiallyUpToTheCap() {
        XCTAssertEqual(GitPullRequestResolver.missLifetime(consecutiveMisses: 1), 20)
        XCTAssertEqual(GitPullRequestResolver.missLifetime(consecutiveMisses: 2), 40)
        XCTAssertEqual(GitPullRequestResolver.missLifetime(consecutiveMisses: 3), 80)
        XCTAssertEqual(GitPullRequestResolver.missLifetime(consecutiveMisses: 6), 300)
    }

    func testSecondConsecutiveMissIsCachedForFortySeconds() {
        let fetchCount = Counter()
        let clock = MutableClock(Date(timeIntervalSinceReferenceDate: 1000))
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in fetchCount.increment(); return nil },
            currentBranch: { _ in "main" },
            now: { clock.value }
        )

        _ = resolver.pullRequest(forBranch: "main", repositoryAt: "/repo")
        clock.value = Date(timeIntervalSinceReferenceDate: 1021)
        _ = resolver.pullRequest(forBranch: "main", repositoryAt: "/repo")
        XCTAssertEqual(fetchCount.value, 2)

        clock.value = Date(timeIntervalSinceReferenceDate: 1060)
        _ = resolver.pullRequest(forBranch: "main", repositoryAt: "/repo")
        XCTAssertEqual(fetchCount.value, 2, "second miss must be cached for forty seconds")

        clock.value = Date(timeIntervalSinceReferenceDate: 1062)
        _ = resolver.pullRequest(forBranch: "main", repositoryAt: "/repo")
        XCTAssertEqual(fetchCount.value, 3)
    }

    func testInvalidationDuringAFetchDiscardsTheStaleResultAndRetries() {
        let fetchCount = Counter()
        let resolver = ResolverBox()
        resolver.value = GitPullRequestResolver(
            fetch: { _, _ in
                fetchCount.increment()
                if fetchCount.value == 1 {
                    resolver.value?.invalidate(repositoryAt: "/repo")
                    return nil
                }
                return Self.openPRJSON
            },
            currentBranch: { _ in "main" },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        XCTAssertEqual(resolver.value?.pullRequest(forBranch: "main", repositoryAt: "/repo")?.number, 115)
        XCTAssertEqual(fetchCount.value, 2, "the pre-invalidation result must be discarded and refetched")
    }

    func testInvalidateForcesRefetchWithinLifetimeForThatRepositoryOnly() {
        let fetchCount = Counter()
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in fetchCount.increment(); return Self.openPRJSON },
            currentBranch: { _ in "main" },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        _ = resolver.pullRequest(forBranch: "main", repositoryAt: "/repo")
        _ = resolver.pullRequest(forBranch: "main", repositoryAt: "/other")
        XCTAssertEqual(fetchCount.value, 2)

        resolver.invalidate(repositoryAt: "/repo")

        _ = resolver.pullRequest(forBranch: "main", repositoryAt: "/repo")
        _ = resolver.pullRequest(forBranch: "main", repositoryAt: "/other")
        XCTAssertEqual(fetchCount.value, 3)
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

private nonisolated final class ResolverBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: GitPullRequestResolver?
    var value: GitPullRequestResolver? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
