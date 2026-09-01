import Foundation

nonisolated struct GitPullRequest: Equatable, Sendable {
    let number: Int
    let url: String
}

nonisolated enum GitPullRequestLookup: Equatable, Sendable {
    case resolved(GitPullRequest?)
    case pending
}

nonisolated final class GitPullRequestResolver: @unchecked Sendable {
    static let shared = GitPullRequestResolver()

    private static let hitCacheLifetime: TimeInterval = 120
    private static let missCacheBaseLifetime: TimeInterval = 20
    private static let missCacheMaxLifetime: TimeInterval = 300
    private static let maxFetchAttempts = 3
    private static let ghTimeout: TimeInterval = 10
    private static let killGrace: TimeInterval = 2
    private static let eofGrace: TimeInterval = 1
    private static let ghCandidatePaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    private struct CacheEntry {
        let fetchedAt: Date
        let pullRequest: GitPullRequest?
        let consecutiveMisses: Int

        var lifetime: TimeInterval {
            pullRequest == nil
                ? GitPullRequestResolver.missLifetime(consecutiveMisses: consecutiveMisses)
                : GitPullRequestResolver.hitCacheLifetime
        }
    }

    static func missLifetime(consecutiveMisses: Int) -> TimeInterval {
        let exponent = max(0, consecutiveMisses - 1)
        return min(missCacheBaseLifetime * pow(2, Double(exponent)), missCacheMaxLifetime)
    }

    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private var inFlightKeys: Set<String> = []
    private var invalidationEpochs: [String: Int] = [:]
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

    func invalidate(repositoryAt cwd: String) {
        let prefix = "\(cwd)\u{0}"
        lock.withLock {
            invalidationEpochs[cwd, default: 0] += 1
            for key in cache.keys where key.hasPrefix(prefix) {
                cache.removeValue(forKey: key)
            }
        }
    }

    func pullRequest(forBranch branch: String, repositoryAt cwd: String) -> GitPullRequest? {
        if case .resolved(let pullRequest) = lookup(forBranch: branch, repositoryAt: cwd) {
            return pullRequest
        }
        return nil
    }

    func lookup(forBranch branch: String, repositoryAt cwd: String) -> GitPullRequestLookup {
        let key = "\(cwd)\u{0}\(branch)"
        let current = now()
        enum Gate { case cached(GitPullRequest?), inFlight, fetch }
        let gate: Gate = lock.withLock {
            if let entry = cache[key],
               current.timeIntervalSince(entry.fetchedAt) < entry.lifetime {
                return .cached(entry.pullRequest)
            }
            if inFlightKeys.contains(key) {
                return .inFlight
            }
            inFlightKeys.insert(key)
            return .fetch
        }
        switch gate {
        case .cached(let pullRequest):
            return .resolved(pullRequest)
        case .inFlight:
            return .pending
        case .fetch:
            break
        }
        defer { lock.withLock { _ = inFlightKeys.remove(key) } }

        for _ in 0..<Self.maxFetchAttempts {
            let epoch = lock.withLock { invalidationEpochs[cwd] ?? 0 }
            let pullRequest = fetch(branch, cwd).flatMap(Self.parse)
            guard currentBranch(cwd) == branch else { return .pending }
            let fetchedAt = now()
            let cached: Bool = lock.withLock {
                guard (invalidationEpochs[cwd] ?? 0) == epoch else { return false }
                let misses = pullRequest == nil ? (cache[key]?.consecutiveMisses ?? 0) + 1 : 0
                cache[key] = CacheEntry(fetchedAt: fetchedAt, pullRequest: pullRequest, consecutiveMisses: misses)
                return true
            }
            if cached {
                return .resolved(pullRequest)
            }
        }
        return .pending
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
