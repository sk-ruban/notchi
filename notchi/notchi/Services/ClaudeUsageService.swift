import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "ClaudeUsageService")

enum ClaudeUsageRecoveryAction: Equatable {
    case none
    case retry
    case reconnect
    case waitForClaudeCode
}

enum ClaudeUsageResumeTrigger: String, Sendable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
}

struct ClaudeUsageRecoverySnapshot: Codable, Equatable {
    let oauthBackoffUntil: Date?
    let oauthHeadersFallbackProbeUntil: Date?
    let isHeadersFallbackActive: Bool
    let lastGoodUsage: QuotaPeriod?
}

protocol ClaudeUsagePollTimer {
    func invalidate()
}

struct ClaudeUsageServiceDependencies {
    var fetchUsage: (URLRequest) async throws -> (Data, URLResponse)
    var getOAuthTokenFromEnvironment: () -> String?
    var getCachedOAuthToken: (_ allowInteraction: Bool) -> String?
    var getOAuthCredentials: (_ allowInteraction: Bool) -> ClaudeOAuthCredentials?
    var cacheOAuthToken: (_ token: String) -> Void
    var refreshAccessTokenSilently: () -> String?
    var clearCachedOAuthToken: () -> Void
    var loadRecoverySnapshot: () -> ClaudeUsageRecoverySnapshot?
    var saveRecoverySnapshot: (ClaudeUsageRecoverySnapshot) -> Void
    var clearRecoverySnapshot: () -> Void
    var resolveUserAgent: () -> String?
    var pollJitter: () -> Double
    var now: () -> Date
    var schedulePoll: @MainActor (TimeInterval, @escaping () -> Void) -> any ClaudeUsagePollTimer
}

private struct LivePollTimer: ClaudeUsagePollTimer {
    let timer: Timer

    func invalidate() {
        timer.invalidate()
    }
}

private struct AnthropicErrorEnvelope: Decodable {
    let error: AnthropicErrorDetail?
    let requestID: String?

    enum CodingKeys: String, CodingKey {
        case error
        case requestID = "request_id"
    }
}

private struct AnthropicErrorDetail: Decodable {
    let type: String?
    let message: String?
}

private func runProcessWithTimeout(
    executablePath: String,
    arguments: [String],
    environment: [String: String]? = nil,
    commandTimeout: TimeInterval
) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.environment = environment

    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = Pipe()

    let completion = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in
        completion.signal()
    }

    do {
        try process.run()
    } catch {
        return nil
    }

    if completion.wait(timeout: .now() + commandTimeout) == .timedOut {
        process.terminate()
        return nil
    }

    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return nil }
    return output
}

private func extractAbsolutePath(from output: String) -> String? {
    output
        .split(separator: "\n")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { $0.hasPrefix("/") || $0.hasPrefix("~") }
}

enum ClaudeConfigDirectorySource: String {
    case environment = "env"
    case shell = "shell"
    case fallback = "default"
}

struct ClaudeConfigDirectoryResolution {
    let path: String
    let source: ClaudeConfigDirectorySource

    var directoryURL: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    var settingsURL: URL {
        directoryURL.appendingPathComponent("settings.json")
    }

    var hooksDirectoryURL: URL {
        directoryURL.appendingPathComponent("hooks", isDirectory: true)
    }

    var hookScriptURL: URL {
        hooksDirectoryURL.appendingPathComponent("notchi-hook.sh")
    }

    var claudeBinaryPath: String {
        directoryURL.appendingPathComponent("bin/claude").path
    }

    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + String(path.dropFirst(home.count))
    }
}

enum ClaudeConfigDirectoryResolver {
    struct TestHooks {
        var environment: () -> [String: String]
        var isExecutableFile: (String) -> Bool
        var runProcess: (
            _ executablePath: String,
            _ arguments: [String],
            _ environment: [String: String]?
        ) -> String?
    }

    private static let commandTimeout: TimeInterval = 2
    private static var cachedResolution: ClaudeConfigDirectoryResolution?
    static var testHooks = makeDefaultTestHooks()

    static func resolve() -> ClaudeConfigDirectoryResolution {
        if let cachedResolution {
            return cachedResolution
        }

        let environment = testHooks.environment()
        let resolved: ClaudeConfigDirectoryResolution

        if let path = normalize(path: environment["CLAUDE_CONFIG_DIR"]) {
            resolved = ClaudeConfigDirectoryResolution(path: path, source: .environment)
        } else if let path = resolveViaShell(environment: environment) {
            resolved = ClaudeConfigDirectoryResolution(path: path, source: .shell)
        } else {
            let fallback = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
                .path
            resolved = ClaudeConfigDirectoryResolution(path: fallback, source: .fallback)
        }

        cachedResolution = resolved
        return resolved
    }

    static func resetTestingHooks() {
        testHooks = makeDefaultTestHooks()
        cachedResolution = nil
    }

    private static func makeDefaultTestHooks() -> TestHooks {
        TestHooks(
            environment: { ProcessInfo.processInfo.environment },
            isExecutableFile: { path in
                FileManager.default.isExecutableFile(atPath: path)
            },
            runProcess: { executablePath, arguments, environment in
                runProcessWithTimeout(
                    executablePath: executablePath,
                    arguments: arguments,
                    environment: environment,
                    commandTimeout: commandTimeout
                )
            }
        )
    }

    private static func resolveViaShell(environment: [String: String]) -> String? {
        let probeCommand = "printf '%s' \"$CLAUDE_CONFIG_DIR\""

        for shellPath in shellCandidates(from: environment) {
            guard testHooks.isExecutableFile(shellPath) else { continue }

            if let path = runShellProbe(executablePath: shellPath, arguments: ["-lc", probeCommand]) {
                return path
            }

            if let path = runShellProbe(executablePath: shellPath, arguments: ["-ic", probeCommand]) {
                return path
            }
        }

        return nil
    }

    private static func runShellProbe(executablePath: String, arguments: [String]) -> String? {
        guard let output = testHooks.runProcess(executablePath, arguments, nil) else {
            return nil
        }

        return normalize(path: extractAbsolutePath(from: output))
    }

    private static func normalize(path rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }

        return URL(fileURLWithPath: expanded, isDirectory: true)
            .standardizedFileURL
            .path
    }

    private static func shellCandidates(from environment: [String: String]) -> [String] {
        var seenShells: Set<String> = []
        return [environment["SHELL"], "/bin/zsh", "/bin/bash"]
            .compactMap { $0 }
            .filter { seenShells.insert($0).inserted }
    }
}

enum ClaudeCLIResolver {
    struct TestHooks {
        var environment: () -> [String: String]
        var isExecutableFile: (String) -> Bool
        var runProcess: (
            _ executablePath: String,
            _ arguments: [String],
            _ environment: [String: String]?
        ) -> String?
    }

    private static let commandTimeout: TimeInterval = 2
    static var testHooks = makeDefaultTestHooks()

    static func resolveUserAgent() -> String? {
        for claudePath in knownExecutablePaths() {
            guard let version = resolveVersion(at: claudePath) else { continue }
            return "claude-code/\(version)"
        }

        return nil
    }

    static func resetTestingHooks() {
        testHooks = makeDefaultTestHooks()
    }

    private static func makeDefaultTestHooks() -> TestHooks {
        TestHooks(
            environment: { ProcessInfo.processInfo.environment },
            isExecutableFile: { path in
                FileManager.default.isExecutableFile(atPath: path)
            },
            runProcess: { executablePath, arguments, environment in
                runProcessWithTimeout(
                    executablePath: executablePath,
                    arguments: arguments,
                    environment: environment,
                    commandTimeout: commandTimeout
                )
            }
        )
    }

    private static func knownExecutablePaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let environment = testHooks.environment()
        let explicitPaths = [
            "\(home)/.local/bin/claude",
            ClaudeConfigDirectoryResolver.resolve().claudeBinaryPath,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        let pathDerivedCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/claude" }
        let shellResolvedPath = resolveCommandPathViaShell(environment: environment).map { [$0] } ?? []

        var resolvedPaths: [String] = []
        var seenPaths: Set<String> = []

        for path in explicitPaths + pathDerivedCandidates + shellResolvedPath {
            guard path.hasPrefix("/") else { continue }
            guard !seenPaths.contains(path) else { continue }
            guard testHooks.isExecutableFile(path) else { continue }
            seenPaths.insert(path)
            resolvedPaths.append(path)
        }

        return resolvedPaths
    }

    static func resolveCommandPathViaShell(environment: [String: String]) -> String? {
        for shellPath in shellCandidates(from: environment) {
            guard testHooks.isExecutableFile(shellPath) else { continue }
            if let resolvedPath = resolveCommandPathViaShell(
                executablePath: shellPath,
                arguments: ["-lc", "command -v claude"]
            ) {
                return resolvedPath
            }

            // nvm commonly exposes claude from interactive rc files like .zshrc, not login-only startup files.
            if let resolvedPath = resolveCommandPathViaShell(
                executablePath: shellPath,
                arguments: ["-ic", "command -v claude"]
            ) {
                return resolvedPath
            }
        }

        return nil
    }

    private static func resolveCommandPathViaShell(
        executablePath: String,
        arguments: [String]
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
        let environment = versionProbeEnvironment(for: path)
        if let version = resolveVersion(
            executablePath: path,
            arguments: ["--version"],
            environment: environment
        ) {
            return version
        }

        return resolveVersionViaShell(at: path, environment: environment)
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

    private static func shellCandidates(from environment: [String: String]) -> [String] {
        var seenShells: Set<String> = []
        return [environment["SHELL"], "/bin/zsh", "/bin/bash"]
            .compactMap { $0 }
            .filter { seenShells.insert($0).inserted }
    }

    private static func versionProbeEnvironment(for path: String) -> [String: String] {
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
        environment: [String: String]
    ) -> String? {
        for shellPath in shellCandidates(from: environment) {
            guard testHooks.isExecutableFile(shellPath) else { continue }

            let shellArg0 = URL(fileURLWithPath: shellPath).lastPathComponent
            if let version = resolveVersion(
                executablePath: shellPath,
                arguments: ["-lc", "\"$1\" --version", shellArg0, path],
                environment: environment
            ) {
                return version
            }

            if let version = resolveVersion(
                executablePath: shellPath,
                arguments: ["-ic", "\"$1\" --version", shellArg0, path],
                environment: environment
            ) {
                return version
            }
        }

        return nil
    }

    private static func resolveVersion(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) -> String? {
        guard let output = testHooks.runProcess(executablePath, arguments, environment) else {
            return nil
        }

        return extractVersion(from: output)
    }

}

private enum ClaudeUsageAccessTokenSource {
    case environment
    case cached
    case recoveredFromCredentials
}

private enum ClaudeUsageAuthFailureResolution {
    case retry(String)
    case reconnect(String)
    case waitForClaudeCode(String)
}

private struct ClaudeUsageAccessTokenResolution {
    let token: String
    let source: ClaudeUsageAccessTokenSource
    let credentials: ClaudeOAuthCredentials?
}

extension ClaudeUsageServiceDependencies {
    static let live = Self(
        fetchUsage: { request in
            try await URLSession.shared.data(for: request)
        },
        getOAuthTokenFromEnvironment: {
            let rawToken = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let rawToken, !rawToken.isEmpty else {
                return nil
            }
            return rawToken
        },
        getCachedOAuthToken: { allowInteraction in
            KeychainManager.getCachedOAuthToken(allowInteraction: allowInteraction)
        },
        getOAuthCredentials: { allowInteraction in
            KeychainManager.getOAuthCredentials(allowInteraction: allowInteraction)
        },
        cacheOAuthToken: { token in
            KeychainManager.cacheOAuthToken(token)
        },
        refreshAccessTokenSilently: {
            KeychainManager.refreshAccessTokenSilently()
        },
        clearCachedOAuthToken: {
            KeychainManager.clearCachedOAuthToken()
        },
        loadRecoverySnapshot: {
            AppSettings.claudeUsageRecoverySnapshot
        },
        saveRecoverySnapshot: { snapshot in
            AppSettings.claudeUsageRecoverySnapshot = snapshot
        },
        clearRecoverySnapshot: {
            AppSettings.claudeUsageRecoverySnapshot = nil
        },
        resolveUserAgent: {
            ClaudeCLIResolver.resolveUserAgent()
        },
        pollJitter: {
            Double.random(in: -2...2)
        },
        now: {
            Date()
        },
        schedulePoll: { interval, handler in
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
                handler()
            }
            return LivePollTimer(timer: timer)
        }
    )
}

@MainActor @Observable
final class ClaudeUsageService {
    static let shared = ClaudeUsageService()

    var currentUsage: QuotaPeriod?
    var isLoading = false
    var error: String?
    var statusMessage: String?
    var isConnected = false
    var isUsageStale = false
    var recoveryAction: ClaudeUsageRecoveryAction = .none

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let maxBackoffInterval: TimeInterval = 600
    private static let oauthRecheckPollCount = 10
    private static let headersFallbackOAuthProbeInterval: TimeInterval = 600
    private static let headersFallbackRefreshInterval: TimeInterval = 60
    private static let resumeReconnectDelay: TimeInterval = 2

    private let dependencies: ClaudeUsageServiceDependencies
    private var resolvedUserAgent: String?
    private var pollTimer: (any ClaudeUsagePollTimer)?
    private var pendingResumeReconnectTimer: (any ClaudeUsagePollTimer)?
    private let pollInterval: TimeInterval = 60
    private var consecutiveRateLimits = 0
    private var cachedToken: String?
    private var preferHeadersFallback = false
    private var oauthRecheckCounter = 0
    private var oauthBackoffUntil: Date?
    private var oauthHeadersFallbackProbeUntil: Date?
    private var isHeadersFallbackActive = false
    private var didAttemptHeadersFallbackInOAuthBackoff = false

    init() {
        self.dependencies = .live
    }

    init(dependencies: ClaudeUsageServiceDependencies) {
        self.dependencies = dependencies
    }

    func connectAndStartPolling() {
        AppSettings.isUsageEnabled = true
        clearTransientState()
        clearOAuthBackoffState()
        preferHeadersFallback = false
        oauthRecheckCounter = 0
        stopPolling()

        Task {
            guard let resolution = resolveStoredAccessToken(
                allowsCredentialRecovery: true,
                prefersRecoveredCredentials: true
            ) else {
                presentReconnectRequired(message: "Claude authentication needs attention. Tap to reconnect.")
                AppSettings.isUsageEnabled = false
                return
            }
            cachedToken = resolution.token
            await performFetch(
                with: resolution.token,
                userInitiated: true,
                consultCredentialMetadata: true,
                cachedCredentials: resolution.credentials
            )
        }
    }

    func handleClaudeResumeTrigger(_ trigger: ClaudeUsageResumeTrigger) {
        guard AppSettings.isUsageEnabled else {
            return
        }

        guard recoveryAction == .waitForClaudeCode else {
            return
        }

        guard !isLoading else {
            logger.info("Ignoring \(trigger.rawValue, privacy: .public) usage retry while a fetch is already in flight")
            return
        }

        guard pendingResumeReconnectTimer == nil else {
            logger.info("Ignoring \(trigger.rawValue, privacy: .public) while a Claude usage retry is already pending")
            return
        }

        logger.info("Scheduling Claude usage reconnect 2s after \(trigger.rawValue, privacy: .public)")
        pendingResumeReconnectTimer = dependencies.schedulePoll(Self.resumeReconnectDelay) { [weak self] in
            Task { @MainActor [weak self] in
                self?.performDelayedResumeReconnect(trigger: trigger)
            }
        }
    }

    func startPolling(afterSystemWake: Bool = false) {
        stopPolling()

        Task {
            if afterSystemWake,
               isHeadersFallbackActive,
               let accessToken = cachedToken {
                resetHeadersFallbackProbeWindowFromWake()
                logger.info("System woke during active headers refresh mode; deferring OAuth re-probe for another \(Int(Self.headersFallbackOAuthProbeInterval))s")
                await refreshActiveHeadersFallback(with: accessToken)
                return
            }

            guard let resolution = resolveStoredAccessToken(allowsCredentialRecovery: true) else {
                logger.info("No cached token, user must connect manually")
                isConnected = false
                AppSettings.isUsageEnabled = false
                clearOAuthBackoffState()
                if currentUsage != nil {
                    presentReconnectRequired(message: "Claude authentication needs attention. Tap to reconnect.")
                } else {
                    clearTransientState()
                }
                return
            }

            AppSettings.isUsageEnabled = true
            cachedToken = resolution.token

            restoreRecoverySnapshotIfNeeded()

            if isHeadersFallbackActive {
                if let remainingProbe = activeHeadersFallbackProbeRemaining() {
                    scheduleHeadersFallbackActiveTimer(remainingProbe: remainingProbe)
                } else {
                    await performFetch(
                        with: resolution.token,
                        consultCredentialMetadata: resolution.source == .recoveredFromCredentials,
                        cachedCredentials: resolution.credentials
                    )
                }
                return
            }

            if let remainingBackoff = activeOAuthBackoffRemaining() {
                presentOAuthBackoffState(remaining: remainingBackoff)
                scheduleBackoffTimer(remaining: remainingBackoff)
                return
            }

            await performFetch(
                with: resolution.token,
                consultCredentialMetadata: resolution.source == .recoveredFromCredentials,
                cachedCredentials: resolution.credentials
            )
        }
    }

    private func resolveStoredAccessToken(
        allowsCredentialRecovery: Bool,
        prefersRecoveredCredentials: Bool = false
    ) -> ClaudeUsageAccessTokenResolution? {
        var recoveredCredentials: ClaudeOAuthCredentials?
        var attemptedCredentialRecovery = false

        // Trim here even though the live dependency trims too, because tests
        // and custom dependencies may inject raw values.
        if let environmentToken = dependencies.getOAuthTokenFromEnvironment()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentToken.isEmpty {
            return ClaudeUsageAccessTokenResolution(token: environmentToken, source: .environment, credentials: nil)
        }

        if prefersRecoveredCredentials, allowsCredentialRecovery {
            attemptedCredentialRecovery = true
            recoveredCredentials = dependencies.getOAuthCredentials(false)
            if let silentCredentials = recoveredCredentials {
                let recoveredToken = silentCredentials.accessToken
                dependencies.cacheOAuthToken(recoveredToken)
                logger.info("Recovered cached OAuth token from Claude Code credentials")
                return ClaudeUsageAccessTokenResolution(token: recoveredToken, source: .recoveredFromCredentials, credentials: silentCredentials)
            }
        }

        if let cachedToken = dependencies.getCachedOAuthToken(false) {
            return ClaudeUsageAccessTokenResolution(token: cachedToken, source: .cached, credentials: nil)
        }

        guard allowsCredentialRecovery else {
            return nil
        }

        if !attemptedCredentialRecovery {
            recoveredCredentials = dependencies.getOAuthCredentials(false)
        }

        if let silentCredentials = recoveredCredentials {
            let recoveredToken = silentCredentials.accessToken
            dependencies.cacheOAuthToken(recoveredToken)
            logger.info("Recovered cached OAuth token from Claude Code credentials")
            return ClaudeUsageAccessTokenResolution(token: recoveredToken, source: .recoveredFromCredentials, credentials: silentCredentials)
        }

        return nil
    }

    func retryNow() {
        guard !isLoading else { return }
        if isHeadersFallbackActive {
            logger.info("Retry tapped during active headers refresh mode")
            if let remainingProbe = activeHeadersFallbackProbeRemaining() {
                scheduleHeadersFallbackActiveTimer(remainingProbe: remainingProbe)
            } else {
                Task {
                    guard let accessToken = cachedToken else {
                        connectAndStartPolling()
                        return
                    }
                    await performFetch(
                        with: accessToken,
                        userInitiated: true,
                        consultCredentialMetadata: false
                    )
                }
            }
            return
        }
        if let remainingBackoff = activeOAuthBackoffRemaining() {
            logger.info("Retry tapped during active OAuth backoff")
            Task {
                guard let accessToken = cachedToken else {
                    connectAndStartPolling()
                    return
                }
                await handleRetryDuringOAuthBackoff(
                    with: accessToken,
                    remaining: remainingBackoff
                )
            }
            return
        }

        clearTransientState()
        stopPolling()
        Task {
            guard let accessToken = cachedToken else {
                connectAndStartPolling()
                return
            }
            await performFetch(
                with: accessToken,
                userInitiated: true,
                consultCredentialMetadata: false
            )
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        clearPendingResumeReconnect()
    }

    private func schedulePollTimer(interval: TimeInterval? = nil, minimumInterval: TimeInterval? = nil) {
        pollTimer?.invalidate()
        let baseInterval = interval ?? pollInterval
        let jitter = dependencies.pollJitter()
        let effectiveInterval = max(10, baseInterval + jitter, minimumInterval ?? 0)
        pollTimer = dependencies.schedulePoll(effectiveInterval) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.fetchUsage()
            }
        }
        logger.info("Next usage poll in \(Int(effectiveInterval))s")
    }

    private func fetchUsage() async {
        guard let accessToken = cachedToken else {
            logger.warning("No cached token available, stopping polling")
            stopPolling()
            return
        }

        if isHeadersFallbackActive {
            if let remainingProbe = activeHeadersFallbackProbeRemaining() {
                logger.info("Refreshing usage via headers while OAuth re-probe is \(Int(remainingProbe))s away")
                await refreshActiveHeadersFallback(with: accessToken)
            } else {
                logger.info("Headers refresh window reached OAuth re-probe deadline")
                await performFetch(with: accessToken, consultCredentialMetadata: false)
            }
            return
        }

        if let remainingBackoff = activeOAuthBackoffRemaining() {
            logger.info("Skipping OAuth fetch while \(Int(remainingBackoff))s of backoff remain")
            presentOAuthBackoffState(remaining: remainingBackoff)
            scheduleBackoffTimer(remaining: remainingBackoff)
            return
        }

        await performFetch(with: accessToken, consultCredentialMetadata: false)
    }

    private enum FetchResult {
        case success
        case handled
        case enterprise403
        case noHeadersFallback
    }

    private enum OAuth403Classification {
        case authScopeFailure(rawMessage: String, errorType: String?, requestID: String?)
        case enterpriseFallback(errorType: String?, requestID: String?)
    }

    private enum PreflightResult {
        case proceed(String)
        case handled
    }

    private enum HeadersFetchContext {
        case normalRetrying
        case normalNoRetry
        case oauthBackoffEntry
        case activeFallbackRefresh
    }

    // Internal for unit tests that verify service state transitions directly.
    func performFetch(
        with accessToken: String,
        userInitiated: Bool = false,
        consultCredentialMetadata: Bool = true,
        cachedCredentials: ClaudeOAuthCredentials? = nil,
        allow403EmptyHeadersRecovery: Bool = true,
        allowPreflightRefreshRecovery: Bool = true
    ) async {
        if userInitiated { isLoading = true }

        defer { if userInitiated { isLoading = false } }

        guard let userAgent = resolveUserAgent() else {
            presentReconnectRequired(message: "Install Claude Code CLI to continue")
            stopPolling()
            return
        }

        let effectiveAccessToken: String
        if consultCredentialMetadata {
            let preflight = await preflightCredentials(
                for: accessToken,
                userInitiated: userInitiated,
                allowPreflightRefreshRecovery: allowPreflightRefreshRecovery,
                cachedCredentials: cachedCredentials
            )
            switch preflight {
            case let .proceed(token):
                effectiveAccessToken = token
            case .handled:
                return
            }
        } else {
            effectiveAccessToken = accessToken
        }

        if await performPreferredEnterpriseHeadersFetchIfNeeded(
            with: effectiveAccessToken,
            userAgent: userAgent,
            userInitiated: userInitiated,
            allowPreflightRefreshRecovery: allowPreflightRefreshRecovery
        ) {
            return
        }

        let result = await fetchViaOAuth(
            with: effectiveAccessToken,
            userAgent: userAgent,
            userInitiated: userInitiated,
            allowPreflightRefreshRecovery: allowPreflightRefreshRecovery
        )

        if case .enterprise403 = result {
            await handleEnterprise403Fallback(
                with: effectiveAccessToken,
                userAgent: userAgent,
                userInitiated: userInitiated,
                allow403EmptyHeadersRecovery: allow403EmptyHeadersRecovery,
                allowPreflightRefreshRecovery: allowPreflightRefreshRecovery
            )
        }
    }

    private func performPreferredEnterpriseHeadersFetchIfNeeded(
        with accessToken: String,
        userAgent: String,
        userInitiated: Bool,
        allowPreflightRefreshRecovery: Bool
    ) async -> Bool {
        guard preferHeadersFallback else {
            return false
        }

        oauthRecheckCounter += 1
        if oauthRecheckCounter >= Self.oauthRecheckPollCount {
            oauthRecheckCounter = 0
            return false
        }

        _ = await fetchViaHeaders(
            with: accessToken,
            userAgent: userAgent,
            userInitiated: userInitiated,
            context: .normalRetrying,
            allowPreflightRefreshRecovery: allowPreflightRefreshRecovery
        )
        return true
    }

    private func handleEnterprise403Fallback(
        with accessToken: String,
        userAgent: String,
        userInitiated: Bool,
        allow403EmptyHeadersRecovery: Bool,
        allowPreflightRefreshRecovery: Bool
    ) async {
        preferHeadersFallback = true
        oauthRecheckCounter = 0
        let fallbackResult = await fetchViaHeaders(
            with: accessToken,
            userAgent: userAgent,
            userInitiated: userInitiated,
            context: .normalNoRetry,
            allowPreflightRefreshRecovery: allowPreflightRefreshRecovery
        )
        if case .noHeadersFallback = fallbackResult {
            preferHeadersFallback = false
            if allow403EmptyHeadersRecovery {
                await recoverFromEmptyHeadersFallback(afterOAuth403With: accessToken, userInitiated: userInitiated)
            } else {
                presentReconnectRequired(message: "Claude authentication needs attention. Tap to reconnect.")
                stopPolling()
            }
        }
    }

    private func fetchViaOAuth(
        with accessToken: String,
        userAgent: String,
        userInitiated: Bool,
        allowPreflightRefreshRecovery: Bool
    ) async -> FetchResult {
        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        logger.info("Fetching usage via OAuth — User-Agent: \(userAgent)")

        do {
            let (data, response) = try await dependencies.fetchUsage(request)

            guard let httpResponse = response as? HTTPURLResponse else {
                presentRetryableIssue(
                    noUsageMessage: "Invalid response, retrying in \(Int(pollInterval))s",
                    staleMessage: "Updating soon"
                )
                schedulePollTimer()
                return .handled
            }

            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 429 {
                    consecutiveRateLimits += 1

                    if consecutiveRateLimits >= 3,
                       let freshToken = dependencies.refreshAccessTokenSilently(),
                       freshToken != accessToken {
                        cachedToken = freshToken
                        consecutiveRateLimits = 0
                        logger.info("Token refreshed after persistent 429s")
                        await performFetch(
                            with: freshToken,
                            userInitiated: userInitiated,
                            consultCredentialMetadata: false
                        )
                        return .handled
                    }

                    let exponentialDelay = pollInterval * pow(2.0, Double(consecutiveRateLimits))
                    var backoffDelay = min(exponentialDelay, Self.maxBackoffInterval)
                    if let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After"),
                       let retrySeconds = TimeInterval(retryAfter), retrySeconds > 0 {
                        backoffDelay = min(max(backoffDelay, retrySeconds), Self.maxBackoffInterval)
                    }

                    beginOAuthBackoff(delay: backoffDelay)
                    logger.warning("OAuth 429 entered backoff for \(Int(backoffDelay))s (attempt \(self.consecutiveRateLimits))")

                    if !didAttemptHeadersFallbackInOAuthBackoff {
                        didAttemptHeadersFallbackInOAuthBackoff = true
                        let hadCurrentUsage = currentUsage != nil
                        let fallbackResult = await fetchViaHeaders(
                            with: accessToken,
                            userAgent: userAgent,
                            userInitiated: userInitiated,
                            context: .oauthBackoffEntry,
                            allowPreflightRefreshRecovery: allowPreflightRefreshRecovery
                        )
                        if case .success = fallbackResult {
                            logger.info(
                                "OAuth 429 entered headers refresh mode: refresh every \(Int(Self.headersFallbackRefreshInterval))s, OAuth probe in \(Int(Self.headersFallbackOAuthProbeInterval))s"
                            )
                            return .handled
                        }
                        if hadCurrentUsage {
                            clearTransientState()
                            beginHeadersFallbackProbeWindow()
                            logger.info("OAuth 429 keeping the last good usage visible while headers refreshes continue")
                            scheduleHeadersFallbackActiveTimer()
                            return .handled
                        }
                    }

                    presentOAuthBackoffState(remaining: backoffDelay)
                    scheduleBackoffTimer(remaining: backoffDelay)
                    return .handled
                }

                let headers = httpResponse.allHeaderFields.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                logger.warning("OAuth HTTP \(httpResponse.statusCode) — headers: \(headers)")

                if httpResponse.statusCode == 403 {
                    return handleOAuthForbidden(data: data, response: httpResponse)
                }

                if httpResponse.statusCode == 401 {
                    await handleAuthFailure(
                        currentToken: accessToken,
                        userInitiated: userInitiated
                    )
                    return .handled
                }

                clearOAuthBackoffState()
                presentRetryableIssue(
                    noUsageMessage: "HTTP \(httpResponse.statusCode), retrying in \(Int(pollInterval))s",
                    staleMessage: "Updating soon"
                )
                schedulePollTimer()
                logger.warning("API error: HTTP \(httpResponse.statusCode)")
                return .handled
            }

            let usageResponse = try JSONDecoder().decode(UsageResponse.self, from: data)
            consecutiveRateLimits = 0
            clearOAuthBackoffState()
            isConnected = true
            preferHeadersFallback = false
            clearTransientState()
            currentUsage = usageResponse.fiveHour
            logger.info("Usage fetched via OAuth: \(self.currentUsage?.usagePercentage ?? 0)%")
            schedulePollTimer()
            return .success

        } catch {
            presentRetryableIssue(
                noUsageMessage: "Network error, retrying in \(Int(pollInterval))s",
                staleMessage: "Updating soon"
            )
            logger.error("OAuth fetch failed: \(error.localizedDescription)")
            schedulePollTimer()
            return .handled
        }
    }

    @discardableResult
    private func fetchViaHeaders(
        with accessToken: String,
        userAgent: String,
        userInitiated: Bool,
        context: HeadersFetchContext = .normalRetrying,
        allowPreflightRefreshRecovery: Bool = true
    ) async -> FetchResult {
        var request = URLRequest(url: Self.messagesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "x"]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        logger.info("Fetching usage via headers fallback")

        do {
            let (_, response) = try await dependencies.fetchUsage(request)

            guard let httpResponse = response as? HTTPURLResponse else {
                switch context {
                case .activeFallbackRefresh:
                    return handleActiveHeadersFallbackMiss(logMessage: "Headers fallback returned invalid response during active fallback refresh")
                case .oauthBackoffEntry:
                    logger.warning("Headers fallback returned invalid response during OAuth backoff")
                    return .noHeadersFallback
                case .normalRetrying, .normalNoRetry:
                    presentRetryableIssue(
                        noUsageMessage: "Invalid response, retrying in \(Int(pollInterval))s",
                        staleMessage: "Updating soon"
                    )
                    schedulePollTimer()
                    return .handled
                }
            }

            if httpResponse.statusCode == 401 {
                await handleAuthFailure(
                    currentToken: accessToken,
                    userInitiated: userInitiated
                )
                return .handled
            }

            guard let utilization = parseHeaderUtilization(from: httpResponse) else {
                logger.debug("No unified rate limit headers in response")
                switch context {
                case .activeFallbackRefresh:
                    return handleActiveHeadersFallbackMiss(logMessage: "No unified rate limit headers in active fallback refresh response")
                case .oauthBackoffEntry, .normalNoRetry:
                    return .noHeadersFallback
                case .normalRetrying:
                    presentRetryableIssue(
                        noUsageMessage: "No rate limit headers, retrying in \(Int(pollInterval))s",
                        staleMessage: "Updating soon"
                    )
                    schedulePollTimer()
                    return .noHeadersFallback
                }
            }

            let resetDate = parseHeaderResetDate(from: httpResponse)
            let usage = QuotaPeriod(utilization: (utilization * 100).rounded(), resetDate: resetDate)
            isConnected = true
            currentUsage = usage

            switch context {
            case .activeFallbackRefresh:
                clearTransientState()
                persistRecoverySnapshotIfNeeded()
                logger.info("Usage refreshed via active headers mode: \(usage.usagePercentage)%")
                scheduleHeadersFallbackActiveTimer()
                return .success
            case .oauthBackoffEntry:
                clearTransientState()
                beginHeadersFallbackProbeWindow()
                logger.info("Usage fetched via headers during OAuth backoff: \(usage.usagePercentage)%")
                scheduleHeadersFallbackActiveTimer()
                return .success
            case .normalRetrying, .normalNoRetry:
                consecutiveRateLimits = 0
                clearOAuthBackoffState()
                clearTransientState()
                logger.info("Usage fetched via headers: \(usage.usagePercentage)%")
                schedulePollTimer()
                return .success
            }

        } catch {
            switch context {
            case .activeFallbackRefresh:
                return handleActiveHeadersFallbackMiss(logMessage: "Headers fetch failed during active fallback refresh: \(error.localizedDescription)")
            case .oauthBackoffEntry:
                logger.error("Headers fetch failed during OAuth backoff: \(error.localizedDescription)")
                return .noHeadersFallback
            case .normalRetrying, .normalNoRetry:
                presentRetryableIssue(
                    noUsageMessage: "Network error, retrying in \(Int(pollInterval))s",
                    staleMessage: "Updating soon"
                )
                logger.error("Headers fetch failed: \(error.localizedDescription)")
                schedulePollTimer()
                return .handled
            }
        }
    }

    private func refreshActiveHeadersFallback(with accessToken: String) async {
        guard let userAgent = resolveUserAgent() else {
            presentReconnectRequired(message: "Install Claude Code CLI to continue")
            stopPolling()
            return
        }

        _ = await fetchViaHeaders(
            with: accessToken,
            userAgent: userAgent,
            userInitiated: false,
            context: .activeFallbackRefresh
        )
    }

    private func handleAuthFailure(
        currentToken: String,
        userInitiated: Bool
    ) async {
        cachedToken = nil
        clearOAuthBackoffState()
        preferHeadersFallback = false
        oauthRecheckCounter = 0
        dependencies.clearCachedOAuthToken()

        switch resolveAuthFailureResolution(after401With: currentToken) {
        case let .retry(freshToken):
            cachedToken = freshToken
            consecutiveRateLimits = 0
            await performFetch(
                with: freshToken,
                userInitiated: userInitiated,
                consultCredentialMetadata: false,
                allowPreflightRefreshRecovery: false
            )

        case let .reconnect(message):
            presentReconnectRequired(message: message)
            stopPolling()

        case let .waitForClaudeCode(message):
            presentWaitForClaudeCode(message: message)
            stopPolling()
        }
    }

    private func preflightCredentials(
        for accessToken: String,
        userInitiated: Bool,
        allowPreflightRefreshRecovery: Bool,
        cachedCredentials: ClaudeOAuthCredentials?
    ) async -> PreflightResult {
        guard let credentials = cachedCredentials ?? dependencies.getOAuthCredentials(false) else {
            return .proceed(accessToken)
        }

        let usesCredentialMetadata: Bool
        let effectiveAccessToken: String

        if userInitiated {
            usesCredentialMetadata = true
            effectiveAccessToken = credentials.accessToken
            if effectiveAccessToken != accessToken {
                cachedToken = effectiveAccessToken
            }
        } else if credentials.accessToken == accessToken {
            usesCredentialMetadata = true
            effectiveAccessToken = accessToken
        } else {
            usesCredentialMetadata = false
            effectiveAccessToken = accessToken
            logger.info("Silent OAuth credential metadata token mismatch; using cached token")
        }

        if usesCredentialMetadata,
           !credentials.scopes.isEmpty,
           !credentials.scopes.contains("user:profile") {
            presentReconnectRequired(message: "Claude authentication needs attention. Tap to reconnect.")
            stopPolling()
            return .handled
        }

        if usesCredentialMetadata,
           let expiresAt = credentials.expiresAt,
           expiresAt <= dependencies.now() {
            logger.info("Local OAuth credential metadata shows expired token before request")

            if userInitiated {
                return .proceed(effectiveAccessToken)
            }

            if allowPreflightRefreshRecovery,
               let freshToken = dependencies.refreshAccessTokenSilently(),
               freshToken != effectiveAccessToken {
                cachedToken = freshToken
                consecutiveRateLimits = 0
                logger.info("Token refreshed silently from local credential preflight")
                await performFetch(
                    with: freshToken,
                    userInitiated: userInitiated,
                    consultCredentialMetadata: false,
                    allowPreflightRefreshRecovery: false
                )
                return .handled
            }

            presentWaitForClaudeCode(message: "Start a Claude Code session to refresh credentials")
            stopPolling()
            return .handled
        }

        return .proceed(effectiveAccessToken)
    }

    private func resolveAuthFailureResolution(after401With currentToken: String) -> ClaudeUsageAuthFailureResolution {
        guard let credentials = dependencies.getOAuthCredentials(false) else {
            return .reconnect("Token expired. Tap to reconnect.")
        }

        if credentialsRequireReconnect(credentials) {
            return .reconnect("Claude authentication needs attention. Tap to reconnect.")
        }

        let credentialToken = credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !credentialToken.isEmpty, credentialToken != currentToken {
            dependencies.cacheOAuthToken(credentialToken)
            logger.info("Recovered newer Claude Code credentials after OAuth 401")
            return .retry(credentialToken)
        }

        if let expiresAt = credentials.expiresAt,
           expiresAt <= dependencies.now() {
            logger.info("Claude Code credential metadata is still expired after OAuth 401")
        }

        return .waitForClaudeCode("Start a Claude Code session to refresh credentials")
    }

    private func recoverFromEmptyHeadersFallback(afterOAuth403With currentToken: String, userInitiated: Bool) async {
        logger.info("OAuth 403 with empty headers fallback triggered silent refresh recovery")
        cachedToken = nil
        clearOAuthBackoffState()
        dependencies.clearCachedOAuthToken()

        if let freshToken = dependencies.refreshAccessTokenSilently(),
           freshToken != currentToken {
            cachedToken = freshToken
            consecutiveRateLimits = 0
            await performFetch(
                with: freshToken,
                userInitiated: userInitiated,
                consultCredentialMetadata: false,
                allow403EmptyHeadersRecovery: false
            )
            return
        }

        presentReconnectRequired(message: "Claude authentication needs attention. Tap to reconnect.")
        stopPolling()
    }

    private func handleOAuthForbidden(data: Data, response: HTTPURLResponse) -> FetchResult {
        let classification = classifyOAuth403(data: data, response: response)

        switch classification {
        case let .authScopeFailure(rawMessage, errorType, requestID):
            let errorTypeLog = errorType ?? "unknown"
            let requestIDLog = requestID ?? "none"
            logger.warning(
                "OAuth 403 requires reconnect - errorType: \(errorTypeLog, privacy: .public), requestID: \(requestIDLog, privacy: .public), message: \(rawMessage, privacy: .public)"
            )
            presentReconnectRequired(message: "Claude authentication needs attention. Tap to reconnect.")
            stopPolling()
            return .handled

        case let .enterpriseFallback(errorType, requestID):
            let errorTypeLog = errorType ?? "unknown"
            let requestIDLog = requestID ?? "none"
            logger.info(
                "OAuth 403 trying headers fallback - errorType: \(errorTypeLog, privacy: .public), requestID: \(requestIDLog, privacy: .public)"
            )
            return .enterprise403
        }
    }

    private func classifyOAuth403(data: Data, response: HTTPURLResponse) -> OAuth403Classification {
        guard !data.isEmpty,
              let envelope = try? JSONDecoder().decode(AnthropicErrorEnvelope.self, from: data) else {
            return .enterpriseFallback(
                errorType: nil,
                requestID: response.value(forHTTPHeaderField: "request-id")
            )
        }

        let errorType = envelope.error?.type?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = envelope.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestID = envelope.requestID ?? response.value(forHTTPHeaderField: "request-id")

        guard errorType == "permission_error",
              let message,
              isExplicitOAuthScopeFailure(message: message) else {
            return .enterpriseFallback(errorType: errorType, requestID: requestID)
        }

        return .authScopeFailure(
            rawMessage: message,
            errorType: errorType,
            requestID: requestID
        )
    }

    private func isExplicitOAuthScopeFailure(message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("user:profile")
            || normalized.contains("missing scope")
            || normalized.contains("scope requirement")
            || (normalized.contains("oauth") && normalized.contains("scope"))
    }

    private func credentialsRequireReconnect(_ credentials: ClaudeOAuthCredentials) -> Bool {
        !credentials.scopes.isEmpty && !credentials.scopes.contains("user:profile")
    }

    private func parseHeaderUtilization(from response: HTTPURLResponse) -> Double? {
        guard let value = response.value(forHTTPHeaderField: "anthropic-ratelimit-unified-5h-utilization") else {
            return nil
        }
        return Double(value.trimmingCharacters(in: .whitespaces))
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoBasic = ISO8601DateFormatter()

    private func parseHeaderResetDate(from response: HTTPURLResponse) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "anthropic-ratelimit-unified-5h-reset"),
              !value.isEmpty else {
            return nil
        }
        if let epoch = TimeInterval(value) {
            return Date(timeIntervalSince1970: epoch)
        }
        return Self.isoFractional.date(from: value) ?? Self.isoBasic.date(from: value)
    }

    private func resolveUserAgent() -> String? {
        if let resolvedUserAgent {
            return resolvedUserAgent
        }

        guard let resolved = dependencies.resolveUserAgent() else {
            return nil
        }

        resolvedUserAgent = resolved
        logger.info("User-Agent resolved: \(resolved)")
        return resolved
    }

    private func clearTransientState() {
        clearPendingResumeReconnect()
        error = nil
        statusMessage = nil
        isUsageStale = false
        recoveryAction = .none
    }

    private func clearPendingResumeReconnect() {
        pendingResumeReconnectTimer?.invalidate()
        pendingResumeReconnectTimer = nil
    }

    private func performDelayedResumeReconnect(trigger: ClaudeUsageResumeTrigger) {
        pendingResumeReconnectTimer = nil

        guard AppSettings.isUsageEnabled else {
            logger.info("Skipping \(trigger.rawValue, privacy: .public) usage retry because Claude usage is disabled")
            return
        }

        guard recoveryAction == .waitForClaudeCode else {
            logger.info("Skipping \(trigger.rawValue, privacy: .public) usage retry because Claude usage no longer waits for Claude Code")
            return
        }

        guard !isLoading else {
            logger.info("Skipping \(trigger.rawValue, privacy: .public) usage retry because a fetch is already in flight")
            return
        }

        logger.info("Retrying Claude usage after \(trigger.rawValue, privacy: .public)")
        connectAndStartPolling()
    }

    private func activeOAuthBackoffRemaining() -> TimeInterval? {
        guard let oauthBackoffUntil else {
            return nil
        }

        let remaining = oauthBackoffUntil.timeIntervalSince(dependencies.now())
        if remaining > 0 {
            return remaining
        }

        clearOAuthBackoffState()
        return nil
    }

    private func activeHeadersFallbackProbeRemaining() -> TimeInterval? {
        guard isHeadersFallbackActive,
              let currentProbeUntil = oauthHeadersFallbackProbeUntil else {
            return nil
        }

        let remaining = currentProbeUntil.timeIntervalSince(dependencies.now())
        if remaining > 0 {
            return remaining
        }
        return nil
    }

    private func beginOAuthBackoff(delay: TimeInterval) {
        let now = dependencies.now()
        let newBackoffUntil = now.addingTimeInterval(delay)
        isHeadersFallbackActive = false
        oauthHeadersFallbackProbeUntil = nil
        if let currentBackoffUntil = oauthBackoffUntil,
           currentBackoffUntil > now {
            oauthBackoffUntil = max(currentBackoffUntil, newBackoffUntil)
            return
        }

        oauthBackoffUntil = newBackoffUntil
        didAttemptHeadersFallbackInOAuthBackoff = false
        persistRecoverySnapshotIfNeeded()
    }

    private func clearOAuthBackoffState() {
        oauthBackoffUntil = nil
        oauthHeadersFallbackProbeUntil = nil
        isHeadersFallbackActive = false
        didAttemptHeadersFallbackInOAuthBackoff = false
        dependencies.clearRecoverySnapshot()
    }

    private func beginHeadersFallbackProbeWindow() {
        oauthBackoffUntil = nil
        consecutiveRateLimits = 0
        isHeadersFallbackActive = true
        oauthHeadersFallbackProbeUntil = dependencies.now().addingTimeInterval(Self.headersFallbackOAuthProbeInterval)
        didAttemptHeadersFallbackInOAuthBackoff = false
        persistRecoverySnapshotIfNeeded()
    }

    private func resetHeadersFallbackProbeWindowFromWake() {
        guard isHeadersFallbackActive else { return }
        oauthHeadersFallbackProbeUntil = dependencies.now().addingTimeInterval(Self.headersFallbackOAuthProbeInterval)
        persistRecoverySnapshotIfNeeded()
    }

    private func scheduleBackoffTimer(remaining: TimeInterval) {
        let baseInterval = max(remaining, pollInterval)
        schedulePollTimer(interval: baseInterval, minimumInterval: remaining)
    }

    private func scheduleHeadersFallbackActiveTimer(remainingProbe: TimeInterval? = nil) {
        let probeRemaining = remainingProbe ?? activeHeadersFallbackProbeRemaining()
        guard let probeRemaining else {
            clearOAuthBackoffState()
            schedulePollTimer()
            return
        }
        let nextInterval = min(Self.headersFallbackRefreshInterval, probeRemaining)
        schedulePollTimer(interval: nextInterval, minimumInterval: nextInterval)
    }

    private func presentOAuthBackoffState(remaining: TimeInterval) {
        clearPendingResumeReconnect()
        recoveryAction = .retry
        let roundedDelay = Int(ceil(remaining))

        if currentUsage == nil {
            error = "Rate limited, retrying in \(roundedDelay)s"
            statusMessage = nil
            isUsageStale = false
            return
        }

        error = nil
        statusMessage = "Updating in \(roundedDelay)s"
        isUsageStale = true
    }

    private func handleRetryDuringOAuthBackoff(with accessToken: String, remaining: TimeInterval) async {
        if !didAttemptHeadersFallbackInOAuthBackoff {
            guard let userAgent = resolveUserAgent() else {
                presentReconnectRequired(message: "Install Claude Code CLI to continue")
                stopPolling()
                return
            }

            didAttemptHeadersFallbackInOAuthBackoff = true
            let fallbackResult = await fetchViaHeaders(
                with: accessToken,
                userAgent: userAgent,
                userInitiated: true,
                context: .oauthBackoffEntry
            )
            if case .success = fallbackResult {
                return
            }
        }

        presentOAuthBackoffState(remaining: remaining)
        scheduleBackoffTimer(remaining: remaining)
    }

    private func handleActiveHeadersFallbackMiss(logMessage: String) -> FetchResult {
        logger.warning("\(logMessage, privacy: .public)")

        let now = dependencies.now()
        guard isUsageStillValid(currentUsage, now: now) else {
            currentUsage = nil
            clearOAuthBackoffState()
            presentRetryableIssue(
                noUsageMessage: "No rate limit headers, retrying in \(Int(pollInterval))s",
                staleMessage: "Updating soon"
            )
            schedulePollTimer()
            return .handled
        }

        clearTransientState()
        persistRecoverySnapshotIfNeeded()
        scheduleHeadersFallbackActiveTimer()
        return .handled
    }

    private func restoreRecoverySnapshotIfNeeded() {
        guard let snapshot = dependencies.loadRecoverySnapshot() else {
            return
        }

        let now = dependencies.now()
        let hasActiveHeadersFallback = snapshot.isHeadersFallbackActive
            && snapshot.oauthHeadersFallbackProbeUntil.map({ $0 > now }) ?? false
        let hasActiveOAuthBackoff = snapshot.oauthBackoffUntil.map({ $0 > now }) ?? false

        guard hasActiveHeadersFallback || hasActiveOAuthBackoff else {
            dependencies.clearRecoverySnapshot()
            return
        }

        currentUsage = isUsageStillValid(snapshot.lastGoodUsage, now: now) ? snapshot.lastGoodUsage : nil
        oauthBackoffUntil = hasActiveOAuthBackoff ? snapshot.oauthBackoffUntil : nil
        oauthHeadersFallbackProbeUntil = hasActiveHeadersFallback ? snapshot.oauthHeadersFallbackProbeUntil : nil
        isHeadersFallbackActive = hasActiveHeadersFallback
        didAttemptHeadersFallbackInOAuthBackoff = false

        if hasActiveHeadersFallback, currentUsage != nil {
            isConnected = true
            clearTransientState()
            logger.info("Restored active headers refresh mode from persistence")
        } else if hasActiveOAuthBackoff {
            logger.info("Restored OAuth recovery window from persistence")
        }
    }

    private func persistRecoverySnapshotIfNeeded() {
        guard let snapshot = makeRecoverySnapshot() else {
            dependencies.clearRecoverySnapshot()
            return
        }
        dependencies.saveRecoverySnapshot(snapshot)
    }

    private func makeRecoverySnapshot() -> ClaudeUsageRecoverySnapshot? {
        guard oauthBackoffUntil != nil
            || (isHeadersFallbackActive && oauthHeadersFallbackProbeUntil != nil) else {
            return nil
        }

        let usageToPersist = isUsageStillValid(currentUsage, now: dependencies.now()) ? currentUsage : nil
        return ClaudeUsageRecoverySnapshot(
            oauthBackoffUntil: oauthBackoffUntil,
            oauthHeadersFallbackProbeUntil: oauthHeadersFallbackProbeUntil,
            isHeadersFallbackActive: isHeadersFallbackActive,
            lastGoodUsage: usageToPersist
        )
    }

    private func isUsageStillValid(_ usage: QuotaPeriod?, now: Date) -> Bool {
        guard let usage, let resetDate = usage.resetDate else {
            return false
        }
        return resetDate > now
    }

    private func presentRetryableIssue(noUsageMessage: String, staleMessage: String) {
        clearPendingResumeReconnect()
        recoveryAction = .retry
        if currentUsage == nil {
            error = noUsageMessage
            statusMessage = nil
            isUsageStale = false
        } else {
            error = nil
            statusMessage = staleMessage
            isUsageStale = true
        }
    }

    private func presentReconnectRequired(message: String) {
        clearPendingResumeReconnect()
        recoveryAction = .reconnect
        isConnected = false
        if currentUsage == nil {
            error = message
            statusMessage = nil
            isUsageStale = false
        } else {
            error = nil
            statusMessage = message
            isUsageStale = true
        }
    }

    private func presentWaitForClaudeCode(message: String) {
        clearPendingResumeReconnect()
        recoveryAction = .waitForClaudeCode
        isConnected = false
        if currentUsage == nil {
            error = message
            statusMessage = nil
            isUsageStale = false
        } else {
            error = nil
            statusMessage = message
            isUsageStale = true
        }
    }
}
