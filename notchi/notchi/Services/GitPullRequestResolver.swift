import Foundation

nonisolated struct GitPullRequest: Equatable, Sendable {
    let number: Int
    let url: String
}

nonisolated enum GitPullRequestLookup: Equatable, Sendable {
    case resolved(GitPullRequest?)
    case pending
}

nonisolated enum GhPullRequestOutput: Equatable, Sendable {
    case pullRequestJSON(Data)
    case noPullRequest
    /// gh isn't installed or isn't signed in, so no branch can resolve until that changes.
    case ghUnavailable
}

/// The parts of the gh install that installing it or signing in changes.
nonisolated struct GhSetup: Equatable, Sendable {
    let executablePath: String?
    let hostsFileModifiedAt: Date?
}

nonisolated struct ProcessResult: Equatable, Sendable {
    let status: Int32
    let output: Data
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
    private static let ghAuthRequiredExitStatus: Int32 = 4
    // Repositories without a remote HEAD usually still default to one of these.
    private static let conventionalDefaultBranches: Set<String> = ["main", "master"]
    // Past every lifetime, so dropping these never loses a live entry's backoff.
    private static let staleEntryAge: TimeInterval = 2 * missCacheMaxLifetime
    private static let maxCacheEntries = 64

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
    // Only repositories with a fetch in flight need an epoch, so this stays as small as inFlightKeys.
    private var invalidationEpochs: [String: Int] = [:]
    private var unavailableGhSetup: GhSetup?
    private let fetch: @Sendable (String, String) -> GhPullRequestOutput
    private let currentBranch: @Sendable (String) -> String?
    private let defaultBranch: @Sendable (String) -> String?
    private let ghSetup: @Sendable () -> GhSetup
    private let now: @Sendable () -> Date

    init(
        fetch: @escaping @Sendable (String, String) -> GhPullRequestOutput = { _, cwd in GitPullRequestResolver.runGh(cwd: cwd) },
        currentBranch: @escaping @Sendable (String) -> String? = { cwd in GitBranchReader.branch(forRepositoryAt: cwd) },
        defaultBranch: @escaping @Sendable (String) -> String? = { cwd in GitBranchReader.defaultBranch(forRepositoryAt: cwd) },
        ghSetup: @escaping @Sendable () -> GhSetup = { GitPullRequestResolver.currentGhSetup() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetch = fetch
        self.currentBranch = currentBranch
        self.defaultBranch = defaultBranch
        self.ghSetup = ghSetup
        self.now = now
    }

    func invalidate(repositoryAt cwd: String) {
        let prefix = "\(cwd)\u{0}"
        lock.withLock {
            if inFlightKeys.contains(where: { $0.hasPrefix(prefix) }) {
                invalidationEpochs[cwd, default: 0] += 1
            }
            for key in cache.keys where key.hasPrefix(prefix) {
                cache.removeValue(forKey: key)
            }
        }
    }

    func lookup(forBranch branch: String, repositoryAt cwd: String) -> GitPullRequestLookup {
        // A pull request's head is a feature branch; asking gh about the default branch only ever misses.
        let isDefaultBranch = defaultBranch(cwd).map { $0 == branch }
            ?? Self.conventionalDefaultBranches.contains(branch)
        guard !isDefaultBranch else { return .resolved(nil) }

        let key = "\(cwd)\u{0}\(branch)"
        let prefix = "\(cwd)\u{0}"
        let current = now()
        var ghStillUnavailable = false
        if let unavailableGhSetup = lock.withLock({ self.unavailableGhSetup }) {
            ghStillUnavailable = ghSetup() == unavailableGhSetup
            if !ghStillUnavailable {
                lock.withLock { self.unavailableGhSetup = nil }
            }
        }
        enum Gate { case cached(GitPullRequest?), inFlight, fetch }
        let gate: Gate = lock.withLock {
            if let entry = cache[key],
               current.timeIntervalSince(entry.fetchedAt) < entry.lifetime {
                return .cached(entry.pullRequest)
            }
            if ghStillUnavailable {
                return .cached(nil)
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
        defer {
            lock.withLock {
                inFlightKeys.remove(key)
                if !inFlightKeys.contains(where: { $0.hasPrefix(prefix) }) {
                    invalidationEpochs.removeValue(forKey: cwd)
                }
            }
        }

        for _ in 0..<Self.maxFetchAttempts {
            let epoch = lock.withLock { invalidationEpochs[cwd] ?? 0 }
            // Read before fetching so a sign-in that lands mid-fetch still counts as a change.
            let setup = ghSetup()
            let output = fetch(branch, cwd)
            if output == .ghUnavailable {
                lock.withLock { unavailableGhSetup = setup }
                return .resolved(nil)
            }
            let pullRequest: GitPullRequest? = if case .pullRequestJSON(let data) = output { Self.parse(data) } else { nil }
            guard currentBranch(cwd) == branch else { return .pending }
            let fetchedAt = now()
            let cached: Bool = lock.withLock {
                guard (invalidationEpochs[cwd] ?? 0) == epoch else { return false }
                let misses = pullRequest == nil ? (cache[key]?.consecutiveMisses ?? 0) + 1 : 0
                cache[key] = CacheEntry(fetchedAt: fetchedAt, pullRequest: pullRequest, consecutiveMisses: misses)
                pruneCache(now: fetchedAt)
                return true
            }
            if cached {
                return .resolved(pullRequest)
            }
        }
        return .pending
    }

    /// Call with `lock` held.
    private func pruneCache(now: Date) {
        cache = cache.filter { now.timeIntervalSince($0.value.fetchedAt) < Self.staleEntryAge }
        let overflow = cache.count - Self.maxCacheEntries
        guard overflow > 0 else { return }
        for key in cache.sorted(by: { $0.value.fetchedAt < $1.value.fetchedAt }).prefix(overflow).map(\.key) {
            cache.removeValue(forKey: key)
        }
    }

#if DEBUG
    var cachedEntryCountForTesting: Int { lock.withLock { cache.count } }
    var invalidationEpochCountForTesting: Int { lock.withLock { invalidationEpochs.count } }
#endif

    static func parse(_ data: Data) -> GitPullRequest? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["state"] as? String == "OPEN",
              let number = object["number"] as? Int,
              let url = object["url"] as? String,
              !url.isEmpty else { return nil }
        return GitPullRequest(number: number, url: url)
    }

    private static var ghExecutablePath: String? {
        ghCandidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    static func currentGhSetup() -> GhSetup {
        let environment = ProcessInfo.processInfo.environment
        let configDirectory = environment["GH_CONFIG_DIR"]
            ?? ((environment["XDG_CONFIG_HOME"] ?? NSHomeDirectory() + "/.config") + "/gh")
        let hostsFile = (configDirectory as NSString).appendingPathComponent("hosts.yml")
        let hostsFileModifiedAt = (try? FileManager.default.attributesOfItem(atPath: hostsFile))?[.modificationDate] as? Date
        return GhSetup(executablePath: ghExecutablePath, hostsFileModifiedAt: hostsFileModifiedAt)
    }

    private static func runGh(cwd: String) -> GhPullRequestOutput {
        guard let gh = ghExecutablePath else { return .ghUnavailable }
        return ghOutput(for: runProcess(
            executable: gh,
            arguments: ["pr", "view", "--json", "number,url,state"],
            cwd: cwd,
            timeout: ghTimeout
        ))
    }

    static func ghOutput(for result: ProcessResult?) -> GhPullRequestOutput {
        guard let result else { return .noPullRequest }
        switch result.status {
        case 0:
            return .pullRequestJSON(result.output)
        case ghAuthRequiredExitStatus:
            return .ghUnavailable
        default:
            return .noPullRequest
        }
    }

    /// Returns nil when the process can't launch or runs past `timeout`.
    static func runProcess(executable: String, arguments: [String], cwd: String, timeout: TimeInterval) -> ProcessResult? {
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

        guard !timedOut else { return nil }
        return ProcessResult(status: process.terminationStatus, output: output.data)
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
