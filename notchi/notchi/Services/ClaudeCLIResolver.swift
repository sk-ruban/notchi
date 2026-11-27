import Foundation

// WHY: User-agent resolution spawns shell/CLI probes with multi-second
// timeouts, so it must stay callable from background executors instead of
// inheriting the project's MainActor default.
nonisolated enum ClaudeCLIResolver {
    typealias TestHooks = ShellProbeTestHooks

    private static let commandTimeout: TimeInterval = 2
    private static let stateQueue = DispatchQueue(
        label: "com.ruban.notchi.claudeCLIResolver.state"
    )
    // WHY: resolution runs on background executors while tests mutate hooks
    // from the main actor, so guard the shared state with stateQueue and
    // snapshot it once per resolution.
    nonisolated(unsafe) private static var lockedTestHooks = TestHooks.live(commandTimeout: commandTimeout)
    nonisolated(unsafe) private static var cachedUserAgent: String?
    // Every account's usage service asks at launch; one lookup at a time lets the rest reuse its result.
    private static let userAgentResolutionLock = NSLock()

    static var testHooks: TestHooks {
        get {
            stateQueue.sync { lockedTestHooks }
        }
        set {
            stateQueue.sync { lockedTestHooks = newValue }
        }
    }

    /// The same for every account, so it's looked up once per run; a miss is retried in case Claude Code gets installed.
    static func resolveUserAgent() -> String? {
        userAgentResolutionLock.withLock {
            if let cached = stateQueue.sync(execute: { cachedUserAgent }) {
                return cached
            }
            let resolved = lookUpUserAgent(testHooks: testHooks)
            if let resolved {
                stateQueue.sync { cachedUserAgent = resolved }
            }
            return resolved
        }
    }

    private static func lookUpUserAgent(testHooks: TestHooks) -> String? {
        let environment = testHooks.environment()
        var triedPaths: Set<String> = []
        func userAgent(trying paths: [String]) -> String? {
            for path in paths where path.hasPrefix("/") && !triedPaths.contains(path) {
                guard testHooks.isExecutableFile(path) else { continue }
                triedPaths.insert(path)
                guard let version = resolveVersion(at: path, testHooks: testHooks) else { continue }
                return "claude-code/\(version)"
            }
            return nil
        }

        if let userAgent = userAgent(trying: knownExecutablePaths(environment: environment)) {
            return userAgent
        }
        // The shell lookup spawns login and interactive shells, so it only runs when no known path answers.
        guard let shellResolvedPath = resolveCommandPathViaShell(environment: environment, testHooks: testHooks) else {
            return nil
        }
        return userAgent(trying: [shellResolvedPath])
    }

    static func resetTestingHooks() {
        stateQueue.sync {
            lockedTestHooks = TestHooks.live(commandTimeout: commandTimeout)
            cachedUserAgent = nil
        }
    }

    /// Explicit install locations, then `PATH`; the shell lookup is the caller's last resort.
    private static func knownExecutablePaths(environment: [String: String]) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let explicitPaths = [
            "\(home)/.local/bin/claude",
            ClaudeConfigDirectoryResolver.resolve().claudeBinaryPath,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        let pathDerivedCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/claude" }
        return explicitPaths + pathDerivedCandidates
    }

    static func resolveCommandPathViaShell(environment: [String: String]) -> String? {
        resolveCommandPathViaShell(environment: environment, testHooks: testHooks)
    }

    private static func resolveCommandPathViaShell(
        environment: [String: String],
        testHooks: TestHooks
    ) -> String? {
        for shellPath in shellCandidates(from: environment) {
            guard testHooks.isExecutableFile(shellPath) else { continue }
            if let resolvedPath = resolveCommandPathViaShell(
                executablePath: shellPath,
                arguments: ["-lc", "command -v claude"],
                testHooks: testHooks
            ) {
                return resolvedPath
            }

            // nvm commonly exposes claude from interactive rc files like .zshrc, not login-only startup files.
            if let resolvedPath = resolveCommandPathViaShell(
                executablePath: shellPath,
                arguments: ["-ic", "command -v claude"],
                testHooks: testHooks
            ) {
                return resolvedPath
            }
        }

        return nil
    }

    private static func resolveCommandPathViaShell(
        executablePath: String,
        arguments: [String],
        testHooks: TestHooks
    ) -> String? {
        guard let output = testHooks.runProcess(executablePath, arguments, nil) else {
            return nil
        }

        guard let resolvedPath = extractExecutablePath(from: output) else {
            return nil
        }

        guard testHooks.isExecutableFile(resolvedPath) else {
            return nil
        }

        return resolvedPath
    }

    static func extractExecutablePath(from output: String) -> String? {
        extractAbsolutePath(from: output)
    }

    static func resolveVersion(at path: String) -> String? {
        resolveVersion(at: path, testHooks: testHooks)
    }

    private static func resolveVersion(at path: String, testHooks: TestHooks) -> String? {
        let environment = versionProbeEnvironment(for: path, testHooks: testHooks)
        if let version = resolveVersion(
            executablePath: path,
            arguments: ["--version"],
            environment: environment,
            testHooks: testHooks
        ) {
            return version
        }

        return resolveVersionViaShell(at: path, environment: environment, testHooks: testHooks)
    }

    static func extractVersion(from output: String) -> String? {
        let versionLine = output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.first?.isNumber == true }

        guard let versionLine else { return nil }
        guard let version = versionLine.split(whereSeparator: \.isWhitespace).first else { return nil }
        return String(version)
    }

    private static func versionProbeEnvironment(for path: String, testHooks: TestHooks) -> [String: String] {
        var environment = testHooks.environment()
        let executableDirectory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let existingPath = environment["PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let basePath: String
        if let existingPath, !existingPath.isEmpty {
            basePath = existingPath
        } else {
            basePath = "/usr/bin:/bin:/usr/sbin:/sbin"
        }
        environment["PATH"] = "\(executableDirectory):\(basePath)"
        return environment
    }

    private static func resolveVersionViaShell(
        at path: String,
        environment: [String: String],
        testHooks: TestHooks
    ) -> String? {
        for shellPath in shellCandidates(from: environment) {
            guard testHooks.isExecutableFile(shellPath) else { continue }

            let shellArg0 = URL(fileURLWithPath: shellPath).lastPathComponent
            if let version = resolveVersion(
                executablePath: shellPath,
                arguments: ["-lc", "\"$1\" --version", shellArg0, path],
                environment: environment,
                testHooks: testHooks
            ) {
                return version
            }

            if let version = resolveVersion(
                executablePath: shellPath,
                arguments: ["-ic", "\"$1\" --version", shellArg0, path],
                environment: environment,
                testHooks: testHooks
            ) {
                return version
            }
        }

        return nil
    }

    private static func resolveVersion(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        testHooks: TestHooks
    ) -> String? {
        guard let output = testHooks.runProcess(executablePath, arguments, environment) else {
            return nil
        }

        return extractVersion(from: output)
    }

}
