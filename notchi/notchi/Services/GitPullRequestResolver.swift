import Foundation

nonisolated struct GitPullRequest: Equatable, Sendable {
    let number: Int
    let url: String
}

nonisolated final class GitPullRequestResolver: @unchecked Sendable {
    static let shared = GitPullRequestResolver()

    private static let cacheLifetime: TimeInterval = 300
    private static let ghCandidatePaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    private struct CacheEntry {
        let fetchedAt: Date
        let pullRequest: GitPullRequest?
    }

    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private let fetch: @Sendable (String, String) -> Data?
    private let now: @Sendable () -> Date

    init(
        fetch: @escaping @Sendable (String, String) -> Data? = { _, cwd in GitPullRequestResolver.runGh(cwd: cwd) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetch = fetch
        self.now = now
    }

    func pullRequest(forBranch branch: String, repositoryAt cwd: String) -> GitPullRequest? {
        let key = "\(cwd)\u{0}\(branch)"
        let current = now()
        if let entry = lock.withLock({ cache[key] }),
           current.timeIntervalSince(entry.fetchedAt) < Self.cacheLifetime {
            return entry.pullRequest
        }
        let pullRequest = fetch(branch, cwd).flatMap(Self.parse)
        lock.withLock { cache[key] = CacheEntry(fetchedAt: current, pullRequest: pullRequest) }
        return pullRequest
    }

    static func parse(_ data: Data) -> GitPullRequest? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["state"] as? String == "OPEN",
              let number = object["number"] as? Int,
              let url = object["url"] as? String,
              !url.isEmpty else { return nil }
        return GitPullRequest(number: number, url: url)
    }

    private static func runGh(cwd: String) -> Data? {
        guard let gh = ghCandidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["pr", "view", "--json", "number,url,state"]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return data
    }
}
