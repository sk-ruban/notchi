import Foundation

nonisolated struct GitPullRequest: Equatable, Sendable {
    let number: Int
    let url: String
}

nonisolated final class GitPullRequestResolver: @unchecked Sendable {
    static let shared = GitPullRequestResolver()

    private static let hitCacheLifetime: TimeInterval = 120
    private static let missCacheLifetime: TimeInterval = 20
    private static let ghTimeout: TimeInterval = 10
    private static let killGrace: TimeInterval = 2
    private static let eofGrace: TimeInterval = 1
    private static let ghCandidatePaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    private struct CacheEntry {
        let fetchedAt: Date
        let pullRequest: GitPullRequest?
    }

    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private var inFlightKeys: Set<String> = []
    private let fetch: @Sendable (String, String) -> Data?
    private let currentBranch: @Sendable (String) -> String?
    private let now: @Sendable () -> Date

    init(
        fetch: @escaping @Sendable (String, String) -> Data? = { _, cwd in GitPullRequestResolver.runGh(cwd: cwd) },
        currentBranch: @escaping @Sendable (String) -> String? = { cwd in GitBranchReader.branch(forRepositoryAt: cwd) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetch = fetch
        self.currentBranch = currentBranch
        self.now = now
    }

    func pullRequest(forBranch branch: String, repositoryAt cwd: String) -> GitPullRequest? {
        let key = "\(cwd)\u{0}\(branch)"
        let current = now()
        let cachedOrInFlight: (entry: CacheEntry?, alreadyFetching: Bool) = lock.withLock {
            let entry = cache[key]
            if let entry,
               current.timeIntervalSince(entry.fetchedAt) < (entry.pullRequest == nil ? Self.missCacheLifetime : Self.hitCacheLifetime) {
                return (entry, true)
            }
            if inFlightKeys.contains(key) {
                return (entry, true)
            }
            inFlightKeys.insert(key)
            return (entry, false)
        }
        if cachedOrInFlight.alreadyFetching {
            return cachedOrInFlight.entry?.pullRequest
        }
        defer { lock.withLock { _ = inFlightKeys.remove(key) } }

        let pullRequest = fetch(branch, cwd).flatMap(Self.parse)
        guard currentBranch(cwd) == branch else { return nil }
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
        return runProcess(
            executable: gh,
            arguments: ["pr", "view", "--json", "number,url,state"],
            cwd: cwd,
            timeout: ghTimeout
        )
    }

    static func runProcess(executable: String, arguments: [String], cwd: String, timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        let output = LockedDataBuffer()
        let sawEOF = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                sawEOF.signal()
            } else {
                output.append(chunk)
            }
        }
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + killGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + killGrace)
            }
        }

        // A child that inherited the pipe can hold the write end open after
        // the main process exits, so EOF gets a grace period, not a blocking wait.
        _ = sawEOF.wait(timeout: .now() + eofGrace)
        stdoutPipe.fileHandleForReading.readabilityHandler = nil

        guard !timedOut, process.terminationStatus == 0 else { return nil }
        return output.data
    }
}

private nonisolated final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    var data: Data { lock.withLock { buffer } }

    func append(_ chunk: Data) {
        lock.withLock { buffer.append(chunk) }
    }
}
