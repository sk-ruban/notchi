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
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        XCTAssertNil(resolver.pullRequest(forBranch: "main", repositoryAt: "/repo"))
        XCTAssertNil(resolver.pullRequest(forBranch: "main", repositoryAt: "/repo"))
        XCTAssertEqual(fetchCount.value, 1)
    }

    func testCacheExpiresAfterLifetime() {
        let fetchCount = Counter()
        let clock = MutableClock(Date(timeIntervalSinceReferenceDate: 1000))
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in fetchCount.increment(); return Self.openPRJSON },
            now: { clock.value }
        )

        _ = resolver.pullRequest(forBranch: "main", repositoryAt: "/repo")
        clock.value = Date(timeIntervalSinceReferenceDate: 1301)
        _ = resolver.pullRequest(forBranch: "main", repositoryAt: "/repo")

        XCTAssertEqual(fetchCount.value, 2)
    }

    func testDifferentBranchesAreCachedSeparately() {
        let fetchCount = Counter()
        let resolver = GitPullRequestResolver(
            fetch: { _, _ in fetchCount.increment(); return Self.openPRJSON },
            now: { Date(timeIntervalSinceReferenceDate: 1000) }
        )

        _ = resolver.pullRequest(forBranch: "main", repositoryAt: "/repo")
        _ = resolver.pullRequest(forBranch: "feature", repositoryAt: "/repo")

        XCTAssertEqual(fetchCount.value, 2)
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
