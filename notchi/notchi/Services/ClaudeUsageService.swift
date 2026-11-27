import Foundation
import os.log

nonisolated private let logger = Logger(subsystem: "com.ruban.notchi", category: "ClaudeUsageService")

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

@MainActor @Observable
final class ClaudeUsageService {
    static let shared = ClaudeUsageService()

    var currentUsage: QuotaPeriod?
    var currentWeeklyUsage: QuotaPeriod?
    var currentModelUsage: QuotaPeriod?
    var currentModelUsageName: String?
    var currentExtraUsage: ExtraUsage?
    var isUsingExtraUsage = false
    var isLoading = false
    var error: String?
    var statusMessage: String?
    var isConnected = false
    var isUsageStale = false

    // Headers refreshes only carry session usage, so in either headers mode (backoff-driven or
    // enterprise preferred) weekly data is held over from the last OAuth success.
    var isWeeklyUsageHeldOver: Bool { isUsageStale || isHeadersFallbackActive || preferHeadersFallback }
    var hasUsageData: Bool {
        UsageMetrics.claudeHasData(
            usage: currentUsage,
            weeklyUsage: currentWeeklyUsage,
            modelUsage: currentModelUsage,
            extraUsage: currentExtraUsage
        )
    }
    var recoveryAction: ClaudeUsageRecoveryAction = .none

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let maxBackoffInterval: TimeInterval = 600
    private static let oauthRecheckPollCount = 10
    private static let headersFallbackOAuthProbeInterval: TimeInterval = 600
    private static let headersFallbackRefreshInterval: TimeInterval = 60
    private static let resumeReconnectDelay: TimeInterval = 2
    private static let selfHealRetryInterval: TimeInterval = 300

    private let dependencies: ClaudeUsageServiceDependencies
    private var resolvedUserAgent: String?
    private var pollTimer: (any ClaudeUsagePollTimer)?
    private var pendingResumeReconnectTimer: (any ClaudeUsagePollTimer)?
    private var selfHealRetryTimer: (any ClaudeUsagePollTimer)?
    private let pollInterval: TimeInterval = 60
    // Bumped whenever polling stops or is rescheduled, so a timer or credential read begun earlier knows it was superseded.
    private var pollScheduleGeneration: UInt64 = 0
    /// The latest connect owns `isLoading`, so an older one finishing can't clear a newer one's spinner.
    private var connectGeneration: UInt64 = 0
    private var consecutiveRateLimits = 0
    private var cachedToken: String?
    private var preferHeadersFallback = false
    private var oauthRecheckCounter = 0
    private var oauthBackoffUntil: Date?
    private var oauthHeadersFallbackProbeUntil: Date?
    private var isHeadersFallbackActive = false
    private var didAttemptHeadersFallbackInOAuthBackoff = false
    private var lastObservedExtraUsageCredits: Double?
    private var extraUsageResetMarker: String?

    init() {
        self.dependencies = .live
    }

    init(dependencies: ClaudeUsageServiceDependencies) {
        self.dependencies = dependencies
    }

    // The isolated-deinit back-deploy shim aborts on macOS 15; this deinit only releases stored properties.
    nonisolated deinit {}

    /// Whether this account's usage is on: the usage switch, minus an account whose login failed.
    var isUsageEnabled: Bool {
        dependencies.isUsageEnabled()
    }

    func connectAndStartPolling() {
        dependencies.setUsageEnabled(true)
        clearTransientState()
        clearOAuthBackoffState()
        restorePersistedExtraUsageObservationIfNeeded()
        preferHeadersFallback = false
        oauthRecheckCounter = 0
        stopPolling()
        let generation = pollScheduleGeneration
        connectGeneration &+= 1
        let connect = connectGeneration

        Task {
            // The credential read can take seconds; loading covers it so retry and self-heal wait it out.
            isLoading = true
            defer { if connectGeneration == connect { isLoading = false } }
            let resolution = await resolveStoredAccessToken(
                allowsCredentialRecovery: true,
                prefersRecoveredCredentials: true
            )
            guard pollScheduleGeneration == generation else { return }
            guard let resolution else {
                presentReconnectRequired(message: String(localized: "Claude authentication needs attention."))
                if currentUsage != nil {
                    scheduleSelfHealRetry()
                } else {
                    dependencies.setUsageEnabled(false)
                }
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
        guard dependencies.isUsageEnabled() else {
            return
        }

        guard recoveryAction == .waitForClaudeCode else {
            return
        }

        guard !isLoading else {
            return
        }

        guard pendingResumeReconnectTimer == nil else {
            return
        }

        pendingResumeReconnectTimer = dependencies.schedulePoll(Self.resumeReconnectDelay) { [weak self] in
            Task { @MainActor [weak self] in
                self?.performDelayedResumeReconnect()
            }
        }
    }

    func startPolling(afterSystemWake: Bool = false) {
        stopPolling()
        let generation = pollScheduleGeneration

        Task {
            if afterSystemWake, let accessToken = cachedToken {
                if isHeadersFallbackActive {
                    resetHeadersFallbackProbeWindowFromWake()
                    await refreshActiveHeadersFallback(with: accessToken)
                } else {
                    await performFetch(with: accessToken, consultCredentialMetadata: false)
                }
                return
            }

            let resolution = await resolveStoredAccessToken(allowsCredentialRecovery: true)
            guard pollScheduleGeneration == generation else { return }
            guard let resolution else {
                isConnected = false
                clearOAuthBackoffState()
                if currentUsage != nil {
                    presentReconnectRequired(message: String(localized: "Claude authentication needs attention."))
                    scheduleSelfHealRetry()
                } else {
                    dependencies.setUsageEnabled(false)
                    clearTransientState()
                }
                return
            }

            dependencies.setUsageEnabled(true)
            cachedToken = resolution.token

            restorePersistedExtraUsageObservationIfNeeded()
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
    ) async -> ClaudeUsageAccessTokenResolution? {
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
            recoveredCredentials = await dependencies.getOAuthCredentials(false)
            if let silentCredentials = recoveredCredentials {
                let recoveredToken = silentCredentials.accessToken
                dependencies.cacheOAuthToken(recoveredToken)
                return ClaudeUsageAccessTokenResolution(token: recoveredToken, source: .recoveredFromCredentials, credentials: silentCredentials)
            }
        }

        if let cachedToken = dependencies.getCachedOAuthToken() {
            return ClaudeUsageAccessTokenResolution(token: cachedToken, source: .cached, credentials: nil)
        }

        guard allowsCredentialRecovery else {
            return nil
        }

        if !attemptedCredentialRecovery {
            recoveredCredentials = await dependencies.getOAuthCredentials(false)
        }

        if let silentCredentials = recoveredCredentials {
            let recoveredToken = silentCredentials.accessToken
            dependencies.cacheOAuthToken(recoveredToken)
            return ClaudeUsageAccessTokenResolution(token: recoveredToken, source: .recoveredFromCredentials, credentials: silentCredentials)
        }

        return nil
    }

    func retryNow() {
        guard !isLoading else { return }
        if isHeadersFallbackActive {
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
        pollScheduleGeneration &+= 1
        clearPendingResumeReconnect()

        if recoveryAction == .reconnect {
            scheduleSelfHealRetry()
        }
    }

    private func scheduleSelfHealRetry() {
        guard dependencies.isUsageEnabled() else { return }
        selfHealRetryTimer?.invalidate()
        selfHealRetryTimer = dependencies.schedulePoll(Self.selfHealRetryInterval) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.attemptSelfHeal()
            }
        }
    }

    private func attemptSelfHeal() async {
        selfHealRetryTimer = nil
        guard dependencies.isUsageEnabled(), pollTimer == nil, !isLoading else { return }
        let generation = pollScheduleGeneration

        let resolution = await resolveStoredAccessToken(
            allowsCredentialRecovery: true,
            prefersRecoveredCredentials: true
        )
        guard pollScheduleGeneration == generation else { return }
        guard let resolution else {
            scheduleSelfHealRetry()
            return
        }

        cachedToken = resolution.token
        await performFetch(
            with: resolution.token,
            consultCredentialMetadata: resolution.source == .recoveredFromCredentials,
            cachedCredentials: resolution.credentials
        )
    }

    private func schedulePollTimer(interval: TimeInterval? = nil, minimumInterval: TimeInterval? = nil) {
        selfHealRetryTimer?.invalidate()
        selfHealRetryTimer = nil
        pollTimer?.invalidate()
        let baseInterval = interval ?? pollInterval
        let jitter = dependencies.pollJitter()
        let effectiveInterval = max(10, baseInterval + jitter, minimumInterval ?? 0)
        pollScheduleGeneration &+= 1
        let generation = pollScheduleGeneration
        pollTimer = dependencies.schedulePoll(effectiveInterval) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.pollScheduleGeneration == generation else { return }
                await self.fetchUsage()
            }
        }
    }

    private func fetchUsage() async {
        guard let accessToken = cachedToken else {
            logger.warning("No cached token available, stopping polling")
            stopPolling()
            return
        }

        if isHeadersFallbackActive {
            if activeHeadersFallbackProbeRemaining() != nil {
                await refreshActiveHeadersFallback(with: accessToken)
            } else {
                await performFetch(with: accessToken, consultCredentialMetadata: false)
            }
            return
        }

        if let remainingBackoff = activeOAuthBackoffRemaining() {
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

        guard let userAgent = await resolveUserAgent() else {
            presentReconnectRequired(message: String(localized: "Install Claude Code CLI to continue"))
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
            userInitiated: userInitiated
        ) {
            return
        }

        let result = await fetchViaOAuth(
            with: effectiveAccessToken,
            userAgent: userAgent,
            userInitiated: userInitiated
        )

        if case .enterprise403 = result {
            await handleEnterprise403Fallback(
                with: effectiveAccessToken,
                userAgent: userAgent,
                userInitiated: userInitiated,
                allow403EmptyHeadersRecovery: allow403EmptyHeadersRecovery
            )
        }
    }

    private func performPreferredEnterpriseHeadersFetchIfNeeded(
        with accessToken: String,
        userAgent: String,
        userInitiated: Bool
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
            context: .normalRetrying
        )
        return true
    }

    private func handleEnterprise403Fallback(
        with accessToken: String,
        userAgent: String,
        userInitiated: Bool,
        allow403EmptyHeadersRecovery: Bool
    ) async {
        preferHeadersFallback = true
        oauthRecheckCounter = 0
        let fallbackResult = await fetchViaHeaders(
            with: accessToken,
            userAgent: userAgent,
            userInitiated: userInitiated,
            context: .normalNoRetry
        )
        if case .noHeadersFallback = fallbackResult {
            preferHeadersFallback = false
            if allow403EmptyHeadersRecovery {
                await recoverFromEmptyHeadersFallback(afterOAuth403With: accessToken, userInitiated: userInitiated)
            } else {
                presentReconnectRequired(message: String(localized: "Claude authentication needs attention."))
                stopPolling()
            }
        }
    }

    private func fetchViaOAuth(
        with accessToken: String,
        userAgent: String,
        userInitiated: Bool
    ) async -> FetchResult {
        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await dependencies.fetchUsage(request)

            guard let httpResponse = response as? HTTPURLResponse else {
                presentRetryableIssue(
                    noUsageMessage: String(localized: "Invalid response, retrying in \(Int(pollInterval))s"),
                    staleMessage: String(localized: "Stale data")
                )
                schedulePollTimer()
                return .handled
            }

            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 429 {
                    consecutiveRateLimits += 1

                    if consecutiveRateLimits >= 3,
                       let freshToken = await dependencies.refreshAccessTokenSilently(),
                       freshToken != accessToken {
                        cachedToken = freshToken
                        consecutiveRateLimits = 0
                        logger.info("Token refreshed after persistent OAuth 429 responses")
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
                            context: .oauthBackoffEntry
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
                    noUsageMessage: String(localized: "HTTP \(httpResponse.statusCode), retrying in \(Int(pollInterval))s"),
                    staleMessage: String(localized: "Stale data")
                )
                schedulePollTimer()
                logger.warning("API error: HTTP \(httpResponse.statusCode)")
                return .handled
            }

            let usageResponse = try JSONDecoder().decode(UsageResponse.self, from: data)
            consecutiveRateLimits = 0
            clearOAuthBackoffState()
            isConnected = true
            dependencies.setUsageEnabled(true)
            preferHeadersFallback = false
            clearTransientState()
            currentUsage = usageResponse.fiveHour
            currentWeeklyUsage = usageResponse.sevenDay
            let modelWeekly = usageResponse.modelWeekly
            currentModelUsage = modelWeekly?.period
            currentModelUsageName = modelWeekly?.name
            reconcileExtraUsageState(
                with: usageResponse.extraUsage,
                usage: usageResponse.fiveHour
            )
            schedulePollTimer()
            return .success

        } catch {
            presentRetryableIssue(
                noUsageMessage: String(localized: "Network error, retrying in \(Int(pollInterval))s"),
                staleMessage: String(localized: "Stale data")
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
        context: HeadersFetchContext = .normalRetrying
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
                        noUsageMessage: String(localized: "Invalid response, retrying in \(Int(pollInterval))s"),
                        staleMessage: String(localized: "Stale data")
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
                switch context {
                case .activeFallbackRefresh:
                    return handleActiveHeadersFallbackMiss(logMessage: "No unified rate limit headers in active fallback refresh response")
                case .oauthBackoffEntry, .normalNoRetry:
                    return .noHeadersFallback
                case .normalRetrying:
                    presentRetryableIssue(
                        noUsageMessage: String(localized: "No rate limit headers, retrying in \(Int(pollInterval))s"),
                        staleMessage: String(localized: "Stale data")
                    )
                    schedulePollTimer()
                    return .noHeadersFallback
                }
            }

            let resetDate = parseHeaderResetDate(from: httpResponse)
            let usage = QuotaPeriod(utilization: (utilization * 100).rounded(), resetDate: resetDate)
            isConnected = true
            currentUsage = usage
            reconcileExtraUsageStateForHeaders(using: usage)

            switch context {
            case .activeFallbackRefresh:
                clearTransientState()
                persistRecoverySnapshotIfNeeded()
                scheduleHeadersFallbackActiveTimer()
                return .success
            case .oauthBackoffEntry:
                clearTransientState()
                beginHeadersFallbackProbeWindow()
                scheduleHeadersFallbackActiveTimer()
                return .success
            case .normalRetrying, .normalNoRetry:
                consecutiveRateLimits = 0
                clearOAuthBackoffState()
                clearTransientState()
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
                    noUsageMessage: String(localized: "Network error, retrying in \(Int(pollInterval))s"),
                    staleMessage: String(localized: "Stale data")
                )
                logger.error("Headers fetch failed: \(error.localizedDescription)")
                schedulePollTimer()
                return .handled
            }
        }
    }

    private func refreshActiveHeadersFallback(with accessToken: String) async {
        guard let userAgent = await resolveUserAgent() else {
            presentReconnectRequired(message: String(localized: "Install Claude Code CLI to continue"))
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

        switch await resolveAuthFailureResolution(after401With: currentToken) {
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
        var credentials = cachedCredentials
        if credentials == nil {
            credentials = await dependencies.getOAuthCredentials(false)
        }
        guard let credentials else {
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
        }

        if usesCredentialMetadata,
           !credentials.scopes.isEmpty,
           !credentials.scopes.contains("user:profile") {
            presentReconnectRequired(message: String(localized: "Claude authentication needs attention."))
            stopPolling()
            return .handled
        }

        if usesCredentialMetadata,
           let expiresAt = credentials.expiresAt,
           expiresAt <= dependencies.now() {
            if userInitiated {
                return .proceed(effectiveAccessToken)
            }

            if allowPreflightRefreshRecovery,
               let freshToken = await dependencies.refreshAccessTokenSilently(),
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

            presentWaitForClaudeCode(message: String(localized: "Start a Claude Code session to track usage"))
            stopPolling()
            return .handled
        }

        return .proceed(effectiveAccessToken)
    }

    private func resolveAuthFailureResolution(after401With currentToken: String) async -> ClaudeUsageAuthFailureResolution {
        guard let credentials = await dependencies.getOAuthCredentials(false) else {
            return .reconnect(String(localized: "Token expired."))
        }

        if credentialsRequireReconnect(credentials) {
            return .reconnect(String(localized: "Claude authentication needs attention."))
        }

        let credentialToken = credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !credentialToken.isEmpty, credentialToken != currentToken {
            dependencies.cacheOAuthToken(credentialToken)
            logger.info("Recovered newer Claude Code credentials after OAuth 401")
            return .retry(credentialToken)
        }

        return .waitForClaudeCode(String(localized: "Start a Claude Code session to track usage"))
    }

    private func recoverFromEmptyHeadersFallback(afterOAuth403With currentToken: String, userInitiated: Bool) async {
        logger.info("OAuth 403 with empty headers fallback triggered silent refresh recovery")
        cachedToken = nil
        clearOAuthBackoffState()
        dependencies.clearCachedOAuthToken()

        if let freshToken = await dependencies.refreshAccessTokenSilently(),
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

        presentReconnectRequired(message: String(localized: "Claude authentication needs attention."))
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
            presentReconnectRequired(message: String(localized: "Claude authentication needs attention."))
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

    private func resolveUserAgent() async -> String? {
        if let resolvedUserAgent {
            return resolvedUserAgent
        }

        guard let resolved = await dependencies.resolveUserAgent() else {
            return nil
        }

        resolvedUserAgent = resolved
        return resolved
    }

    private func clearTransientState() {
        clearPendingResumeReconnect()
        error = nil
        statusMessage = nil
        isUsageStale = false
        recoveryAction = .none
    }

    private func reconcileExtraUsageState(
        with extraUsage: ExtraUsage?,
        usage: QuotaPeriod?
    ) {
        synchronizeExtraUsageWindow(with: usage)
        currentExtraUsage = extraUsage
        let isAtQuota = (usage?.usagePercentage ?? 0) >= 100

        guard let extraUsage else {
            if !isAtQuota {
                isUsingExtraUsage = false
            }
            lastObservedExtraUsageCredits = nil
            persistExtraUsageObservationIfNeeded()
            return
        }

        guard extraUsage.isEnabled else {
            isUsingExtraUsage = false
            lastObservedExtraUsageCredits = extraUsage.usedCredits
            persistExtraUsageObservationIfNeeded()
            return
        }

        if !isAtQuota {
            isUsingExtraUsage = false
        } else {
            // OAuth responses expose extra_usage directly, so a 100% window
            // with extra usage enabled should present the same state as the
            // headers fallback path.
            isUsingExtraUsage = true
        }

        lastObservedExtraUsageCredits = extraUsage.usedCredits

        persistExtraUsageObservationIfNeeded()
    }

    private func reconcileExtraUsageStateForHeaders(using usage: QuotaPeriod?) {
        synchronizeExtraUsageWindow(with: usage)
        let isAtQuota = (usage?.usagePercentage ?? 0) >= 100

        // Headers fallback does not expose the extra_usage object, so once
        // we're limited to unified rate-limit headers we treat 100% usage as
        // extra usage to match Claude Code's visible state more closely.
        isUsingExtraUsage = isAtQuota

        persistExtraUsageObservationIfNeeded()
    }

    private func synchronizeExtraUsageWindow(with usage: QuotaPeriod?) {
        let nextResetMarker = usage?.resetsAt
        if let previousResetMarker = extraUsageResetMarker,
           let nextResetMarker,
           previousResetMarker != nextResetMarker {
            isUsingExtraUsage = false
        }
        extraUsageResetMarker = nextResetMarker
    }

    private func clearPendingResumeReconnect() {
        pendingResumeReconnectTimer?.invalidate()
        pendingResumeReconnectTimer = nil
    }

    private func performDelayedResumeReconnect() {
        pendingResumeReconnectTimer = nil

        guard dependencies.isUsageEnabled() else {
            return
        }

        guard recoveryAction == .waitForClaudeCode else {
            return
        }

        guard !isLoading else {
            return
        }

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

        if currentUsage == nil, currentWeeklyUsage == nil, currentModelUsage == nil {
            error = String(localized: "Rate limited, retrying in \(roundedDelay)s")
            statusMessage = nil
            isUsageStale = false
            return
        }

        error = nil
        statusMessage = String(localized: "Updating in \(roundedDelay)s")
        isUsageStale = true
    }

    private func handleRetryDuringOAuthBackoff(with accessToken: String, remaining: TimeInterval) async {
        if !didAttemptHeadersFallbackInOAuthBackoff {
            guard let userAgent = await resolveUserAgent() else {
                presentReconnectRequired(message: String(localized: "Install Claude Code CLI to continue"))
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
            currentWeeklyUsage = nil
            currentModelUsage = nil
            currentModelUsageName = nil
            clearOAuthBackoffState()
            presentRetryableIssue(
                noUsageMessage: String(localized: "No rate limit headers, retrying in \(Int(pollInterval))s"),
                staleMessage: String(localized: "Stale data")
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
        currentWeeklyUsage = isUsageStillValid(snapshot.lastGoodWeeklyUsage, now: now) ? snapshot.lastGoodWeeklyUsage : nil
        currentModelUsage = isUsageStillValid(snapshot.lastGoodModelUsage, now: now) ? snapshot.lastGoodModelUsage : nil
        currentModelUsageName = currentModelUsage == nil ? nil : snapshot.lastGoodModelUsageName
        currentExtraUsage = snapshot.lastGoodExtraUsage
        lastObservedExtraUsageCredits = snapshot.lastObservedExtraUsageCredits
        extraUsageResetMarker = snapshot.extraUsageResetMarker
        isUsingExtraUsage = snapshot.isUsingExtraUsage ?? false
        oauthBackoffUntil = hasActiveOAuthBackoff ? snapshot.oauthBackoffUntil : nil
        oauthHeadersFallbackProbeUntil = hasActiveHeadersFallback ? snapshot.oauthHeadersFallbackProbeUntil : nil
        isHeadersFallbackActive = hasActiveHeadersFallback
        didAttemptHeadersFallbackInOAuthBackoff = false

        if hasActiveHeadersFallback, currentUsage != nil {
            isConnected = true
            clearTransientState()
        }
    }

    private func restorePersistedExtraUsageObservationIfNeeded() {
        guard let observation = dependencies.loadExtraUsageObservation() else {
            return
        }

        guard isExtraUsageWindowStillValid(resetMarker: observation.extraUsageResetMarker, now: dependencies.now()) else {
            dependencies.saveExtraUsageObservation(nil)
            return
        }

        currentExtraUsage = observation.extraUsage
        lastObservedExtraUsageCredits = observation.lastObservedExtraUsageCredits
        extraUsageResetMarker = observation.extraUsageResetMarker
        isUsingExtraUsage = observation.isUsingExtraUsage
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

        let now = dependencies.now()
        let usageToPersist = isUsageStillValid(currentUsage, now: now) ? currentUsage : nil
        let weeklyToPersist = isUsageStillValid(currentWeeklyUsage, now: now) ? currentWeeklyUsage : nil
        let modelToPersist = isUsageStillValid(currentModelUsage, now: now) ? currentModelUsage : nil
        return ClaudeUsageRecoverySnapshot(
            oauthBackoffUntil: oauthBackoffUntil,
            oauthHeadersFallbackProbeUntil: oauthHeadersFallbackProbeUntil,
            isHeadersFallbackActive: isHeadersFallbackActive,
            lastGoodUsage: usageToPersist,
            lastGoodWeeklyUsage: weeklyToPersist,
            lastGoodModelUsage: modelToPersist,
            lastGoodModelUsageName: modelToPersist == nil ? nil : currentModelUsageName,
            lastGoodExtraUsage: currentExtraUsage,
            lastObservedExtraUsageCredits: lastObservedExtraUsageCredits,
            extraUsageResetMarker: extraUsageResetMarker,
            isUsingExtraUsage: isUsingExtraUsage
        )
    }

    private func persistExtraUsageObservationIfNeeded() {
        guard let observation = makeExtraUsageObservation() else {
            dependencies.saveExtraUsageObservation(nil)
            return
        }

        dependencies.saveExtraUsageObservation(observation)
    }

    private func makeExtraUsageObservation() -> ClaudeExtraUsageObservation? {
        guard isExtraUsageWindowStillValid(resetMarker: extraUsageResetMarker, now: dependencies.now()),
              currentExtraUsage != nil || lastObservedExtraUsageCredits != nil || isUsingExtraUsage else {
            return nil
        }

        return ClaudeExtraUsageObservation(
            extraUsage: currentExtraUsage,
            lastObservedExtraUsageCredits: lastObservedExtraUsageCredits,
            extraUsageResetMarker: extraUsageResetMarker,
            isUsingExtraUsage: isUsingExtraUsage
        )
    }

    private func isExtraUsageWindowStillValid(resetMarker: String?, now: Date) -> Bool {
        guard let resetMarker else {
            return false
        }

        let resetDate = Self.isoFractional.date(from: resetMarker) ?? Self.isoBasic.date(from: resetMarker)
        return resetDate.map { $0 > now } ?? false
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
        if currentUsage == nil, currentWeeklyUsage == nil, currentModelUsage == nil {
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
        if currentUsage == nil, currentWeeklyUsage == nil, currentModelUsage == nil {
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
        if currentUsage == nil, currentWeeklyUsage == nil, currentModelUsage == nil {
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
