import XCTest
@testable import notchi

final class GitPullRequestResolverTests: XCTestCase {
    private nonisolated static let openPRJSON = Data(#"{"number":115,"url":"https://github.com/sk-ruban/notchi/pull/115","state":"OPEN"}"#.utf8)
    private nonisolated static let openPROutput = GhPullRequestOutput.pullRequestJSON(openPRJSON)
    private nonisolated static let featureBranch = "feature"
    private nonisolated static let longestMissLifetime: TimeInterval = 300
    private nonisolated static let staleEntryAge: TimeInterval = 600
    private nonisolated static let signedOutGhSetup = GhSetup(executablePath: "/opt/homebrew/bin/gh", hostsFileModifiedAt: nil)
    private nonisolated static let signedInGhSetup = GhSetup(
        executablePath: "/opt/homebrew/bin/gh",
        hostsFileModifiedAt: Date(timeIntervalSinceReferenceDate: 2000)
    )

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
            fetch: { _, _ in fetchCount.increment(); return Self.openPROutput },
            currentBranch: { _ in Self.featureBranch },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        let first = resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo")
        let second = resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo")

        XCTAssertEqual(first?.number, 115)
        XCTAssertEqual(second, first)
        XCTAssertEqual(fetchCount.value, 1)
    }

    func testMissingPullRequestIsAlsoCached() {
        let fetchCount = Counter()
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in fetchCount.increment(); return .noPullRequest },
            currentBranch: { _ in Self.featureBranch },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        XCTAssertNil(resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo"))
        XCTAssertNil(resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo"))
        XCTAssertEqual(fetchCount.value, 1)
    }

    func testHitCacheExpiresAfterTwoMinutes() {
        let fetchCount = Counter()
        let clock = MutableClock(Date(timeIntervalSinceReferenceDate: 1000))
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in fetchCount.increment(); return Self.openPROutput },
            currentBranch: { _ in Self.featureBranch },
            now: { clock.value }
        )

        _ = resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo")
        clock.value = Date(timeIntervalSinceReferenceDate: 1119)
        _ = resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo")
        XCTAssertEqual(fetchCount.value, 1)

        clock.value = Date(timeIntervalSinceReferenceDate: 1121)
        _ = resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo")
        XCTAssertEqual(fetchCount.value, 2)
    }

    func testMissIsRetriedAfterTwentySeconds() {
        let fetchCount = Counter()
        let clock = MutableClock(Date(timeIntervalSinceReferenceDate: 1000))
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in fetchCount.increment(); return fetchCount.value > 1 ? Self.openPROutput : .noPullRequest },
            currentBranch: { _ in Self.featureBranch },
            now: { clock.value }
        )

        XCTAssertNil(resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo"))
        clock.value = Date(timeIntervalSinceReferenceDate: 1019)
        XCTAssertNil(resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo"))
        XCTAssertEqual(fetchCount.value, 1)

        clock.value = Date(timeIntervalSinceReferenceDate: 1021)
        XCTAssertEqual(resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo")?.number, 115)
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
                return Self.openPROutput
            },
            currentBranch: { _ in Self.featureBranch },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        let slowResult = ResultBox()
        DispatchQueue.global().async {
            slowResult.store(resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo"))
        }
        XCTAssertEqual(fetchStarted.wait(timeout: .now() + 2), .success)

        XCTAssertEqual(resolver.lookup(forBranch: Self.featureBranch, repositoryAt: "/repo"), .pending)
        XCTAssertEqual(fetchCount.value, 1)

        releaseFetch.signal()
        XCTAssertEqual(slowResult.wait(timeout: 2)??.number, 115)
    }

    func testResultForAStaleBranchIsDiscardedAndNotCached() {
        let fetchCount = Counter()
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in fetchCount.increment(); return Self.openPROutput },
            currentBranch: { _ in "other-branch" },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        XCTAssertNil(resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo"))
        XCTAssertNil(resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo"))
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

        XCTAssertEqual(output.flatMap { String(data: $0.output, encoding: .utf8) }, "captured\n")
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
            fetch: { _, _ in fetchCount.increment(); return .noPullRequest },
            currentBranch: { _ in Self.featureBranch },
            now: { clock.value }
        )

        _ = resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo")
        clock.value = Date(timeIntervalSinceReferenceDate: 1021)
        _ = resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo")
        XCTAssertEqual(fetchCount.value, 2)

        clock.value = Date(timeIntervalSinceReferenceDate: 1060)
        _ = resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo")
        XCTAssertEqual(fetchCount.value, 2, "second miss must be cached for forty seconds")

        clock.value = Date(timeIntervalSinceReferenceDate: 1062)
        _ = resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo")
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
                    return .noPullRequest
                }
                return Self.openPROutput
            },
            currentBranch: { _ in Self.featureBranch },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        XCTAssertEqual(resolver.value?.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo")?.number, 115)
        XCTAssertEqual(fetchCount.value, 2, "the pre-invalidation result must be discarded and refetched")
    }

    func testInvalidateForcesRefetchWithinLifetimeForThatRepositoryOnly() {
        let fetchCount = Counter()
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in fetchCount.increment(); return Self.openPROutput },
            currentBranch: { _ in Self.featureBranch },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        _ = resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo")
        _ = resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/other")
        XCTAssertEqual(fetchCount.value, 2)

        resolver.invalidate(repositoryAt: "/repo")

        _ = resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo")
        _ = resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/other")
        XCTAssertEqual(fetchCount.value, 3)
    }

    func testRepositoryDefaultBranchIsNeverLookedUp() {
        let expectedFetchCount = 0
        let fetchCount = Counter()
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in fetchCount.increment(); return Self.openPROutput },
            currentBranch: { _ in "trunk" },
            defaultBranch: { _ in "trunk" },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        XCTAssertEqual(resolver.lookup(forBranch: "trunk", repositoryAt: "/repo"), .resolved(nil))
        XCTAssertEqual(fetchCount.value, expectedFetchCount)
    }

    func testMasterIsNotLookedUpWhenTheRepositoryRecordsNoDefaultBranch() {
        let expectedFetchCount = 0
        let fetchCount = Counter()
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in fetchCount.increment(); return Self.openPROutput },
            currentBranch: { _ in "master" },
            defaultBranch: { _ in nil },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        _ = resolver.lookup(forBranch: "master", repositoryAt: "/repo")

        XCTAssertEqual(fetchCount.value, expectedFetchCount)
    }

    func testMainIsLookedUpWhenTheRepositoryDefaultsToAnotherBranch() {
        let expectedNumber = 115
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in Self.openPROutput },
            currentBranch: { _ in "main" },
            defaultBranch: { _ in "develop" },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        XCTAssertEqual(resolver.pullRequest(forBranch: "main", repositoryAt: "/repo")?.number, expectedNumber)
    }

    func testUnavailableGhIsNotRetriedWhileItsSetupIsUnchanged() {
        let expectedFetchCount = 1
        let fetchCount = Counter()
        let clock = MutableClock(Date(timeIntervalSinceReferenceDate: 1000))
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in fetchCount.increment(); return .ghUnavailable },
            currentBranch: { _ in Self.featureBranch },
            ghSetup: { Self.signedOutGhSetup },
            now: { clock.value }
        )

        _ = resolver.lookup(forBranch: Self.featureBranch, repositoryAt: "/repo")
        clock.value = Date(timeIntervalSinceReferenceDate: 1000 + Self.longestMissLifetime + 1)
        _ = resolver.lookup(forBranch: Self.featureBranch, repositoryAt: "/repo")
        _ = resolver.lookup(forBranch: "fix", repositoryAt: "/other")

        XCTAssertEqual(fetchCount.value, expectedFetchCount)
    }

    func testUnavailableGhIsRetriedOnceItsSetupChanges() {
        let expectedNumber = 115
        let fetchCount = Counter()
        let setup = MutableGhSetup(Self.signedOutGhSetup)
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in fetchCount.increment(); return fetchCount.value > 1 ? Self.openPROutput : .ghUnavailable },
            currentBranch: { _ in Self.featureBranch },
            ghSetup: { setup.value },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        XCTAssertEqual(resolver.lookup(forBranch: Self.featureBranch, repositoryAt: "/repo"), .resolved(nil))
        setup.value = Self.signedInGhSetup

        XCTAssertEqual(resolver.pullRequest(forBranch: Self.featureBranch, repositoryAt: "/repo")?.number, expectedNumber)
    }

    func testAuthRequiredExitStatusMeansGhIsUnavailable() {
        XCTAssertEqual(GitPullRequestResolver.ghOutput(for: ProcessResult(status: 4, output: Data())), .ghUnavailable)
    }

    func testOtherGhFailuresAndTimeoutsCountAsMisses() {
        XCTAssertEqual(GitPullRequestResolver.ghOutput(for: ProcessResult(status: 1, output: Data())), .noPullRequest)
        XCTAssertEqual(GitPullRequestResolver.ghOutput(for: nil), .noPullRequest)
    }

    func testSuccessfulGhOutputIsPassedThrough() {
        XCTAssertEqual(
            GitPullRequestResolver.ghOutput(for: ProcessResult(status: 0, output: Self.openPRJSON)),
            Self.openPROutput
        )
    }

    func testCacheDropsEntriesUnusedForTenMinutes() {
        let expectedEntryCount = 1
        let clock = MutableClock(Date(timeIntervalSinceReferenceDate: 1000))
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in .noPullRequest },
            currentBranch: { _ in Self.featureBranch },
            now: { clock.value }
        )

        _ = resolver.lookup(forBranch: Self.featureBranch, repositoryAt: "/stale")
        clock.value = Date(timeIntervalSinceReferenceDate: 1000 + Self.staleEntryAge + 1)
        _ = resolver.lookup(forBranch: Self.featureBranch, repositoryAt: "/fresh")

        XCTAssertEqual(resolver.cachedEntryCountForTesting, expectedEntryCount)
    }

    func testCacheKeepsAtMostSixtyFourEntries() {
        let expectedEntryCount = 64
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in .noPullRequest },
            currentBranch: { _ in Self.featureBranch },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        for index in 0...expectedEntryCount {
            _ = resolver.lookup(forBranch: Self.featureBranch, repositoryAt: "/repo-\(index)")
        }

        XCTAssertEqual(resolver.cachedEntryCountForTesting, expectedEntryCount)
    }

    func testInvalidationEpochIsDroppedOnceTheRepositoryHasNoFetchInFlight() {
        let expectedEpochCount = 0
        let fetchCount = Counter()
        let resolver = ResolverBox()
        resolver.value = GitPullRequestResolver(
            fetch: { _, _ in
                fetchCount.increment()
                if fetchCount.value == 1 {
                    resolver.value?.invalidate(repositoryAt: "/repo")
                }
                return Self.openPROutput
            },
            currentBranch: { _ in Self.featureBranch },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        _ = resolver.value?.lookup(forBranch: Self.featureBranch, repositoryAt: "/repo")
        resolver.value?.invalidate(repositoryAt: "/other")

        XCTAssertEqual(resolver.value?.invalidationEpochCountForTesting, expectedEpochCount)
    }

    func testDifferentBranchesAreCachedSeparately() {
        let fetchCount = Counter()
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in fetchCount.increment(); return Self.openPROutput },
            currentBranch: { _ in Self.featureBranch },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        _ = resolver.pullRequest(forBranch: "feature", repositoryAt: "/repo")
        _ = resolver.pullRequest(forBranch: "fix", repositoryAt: "/repo")

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

private nonisolated final class MutableGhSetup: @unchecked Sendable {
    private let lock = NSLock()
    private var setup: GhSetup
    init(_ setup: GhSetup) { self.setup = setup }
    var value: GhSetup {
        get { lock.withLock { setup } }
        set { lock.withLock { setup = newValue } }
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

extension GitPullRequestResolver {
    func pullRequest(forBranch branch: String, repositoryAt cwd: String) -> GitPullRequest? {
        if case .resolved(let pullRequest) = lookup(forBranch: branch, repositoryAt: cwd) {
            return pullRequest
        }
        return nil
    }
}
