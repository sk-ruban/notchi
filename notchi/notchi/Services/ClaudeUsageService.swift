import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "ClaudeUsageService")

@MainActor @Observable
final class ClaudeUsageService {
    static let shared = ClaudeUsageService()

    var currentUsage: QuotaPeriod?
    var isLoading = false
    var error: String?
    var isConnected = false

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 60
    private var cachedToken: String?
    private var preferHeadersFetch = false
    private var pollsSinceOAuthCheck = 0
    private static let oauthRecheckInterval = 10

    private static let isoFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatter = ISO8601DateFormatter()

    private init() {}

    func connectAndStartPolling() {
        AppSettings.isUsageEnabled = true
        error = nil
        preferHeadersFetch = false
        pollsSinceOAuthCheck = 0
        stopPolling()

        Task {
            guard let accessToken = KeychainManager.getAccessToken() else {
                error = "Keychain access required"
                isConnected = false
                AppSettings.isUsageEnabled = false
                return
            }
            await fetchAndStartPolling(with: accessToken)
        }
    }

    func startPolling() {
        stopPolling()

        Task {
            guard let accessToken = KeychainManager.getCachedOAuthToken() else {
                logger.info("No cached token, user must connect manually")
                isConnected = false
                AppSettings.isUsageEnabled = false
                return
            }
            AppSettings.isUsageEnabled = true
            await fetchAndStartPolling(with: accessToken)
        }
    }

    func retryNow() {
        error = nil
        stopPolling()
        Task {
            guard let accessToken = cachedToken else {
                connectAndStartPolling()
                return
            }
            await performFetch(with: accessToken)
            schedulePollTimer()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func fetchAndStartPolling(with accessToken: String) async {
        cachedToken = accessToken
        await performFetch(with: accessToken)
        schedulePollTimer()
    }

    private func schedulePollTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchUsage()
            }
        }
        logger.info("Started usage polling (every \(self.pollInterval)s)")
    }

    private func fetchUsage() async {
        guard let accessToken = cachedToken else {
            logger.warning("No cached token available, stopping polling")
            stopPolling()
            return
        }

        await performFetch(with: accessToken)
    }

    private enum FetchResult {
        case success
        case authFailure
        case rateLimited
        case error(String)
    }

    private func performFetch(with accessToken: String) async {
        isLoading = true
        defer { isLoading = false }

        // Enterprise fast path: skip OAuth when headers previously worked
        if preferHeadersFetch && pollsSinceOAuthCheck < Self.oauthRecheckInterval {
            pollsSinceOAuthCheck += 1
            if case .success = await fetchFromHeaders(with: accessToken) { return }
            preferHeadersFetch = false
        }

        // Primary: OAuth usage endpoint (Pro/Max)
        pollsSinceOAuthCheck = 0
        let oauthResult = await fetchFromOAuth(with: accessToken)
        if case .success = oauthResult { return }

        // Fallback: Messages API headers (Enterprise)
        if case .success = await fetchFromHeaders(with: accessToken) {
            preferHeadersFetch = true
            return
        }

        // Both failed
        switch oauthResult {
        case .authFailure:
            await handleAuthFailure(currentToken: accessToken)
        case .rateLimited:
            break // Already handled in fetchFromOAuth
        case .error(let message):
            error = message
        case .success:
            break
        }
    }

    private func fetchFromOAuth(with accessToken: String) async -> FetchResult {
        var request = URLRequest(url: Self.usageURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Notchi", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .error("Invalid response")
            }

            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 429 {
                    if currentUsage == nil {
                        error = "Rate limited, polling every \(Int(pollInterval))s"
                    } else {
                        error = nil
                    }
                    logger.debug("Rate limited (429), will retry next poll cycle")
                    return .rateLimited
                }

                if httpResponse.statusCode == 401 {
                    return .authFailure
                }

                logger.warning("OAuth API error: HTTP \(httpResponse.statusCode)")
                return .error("HTTP \(httpResponse.statusCode)")
            }

            let usageResponse = try JSONDecoder().decode(UsageResponse.self, from: data)
            isConnected = true
            error = nil
            currentUsage = usageResponse.fiveHour
            logger.info("Usage fetched via OAuth: \(self.currentUsage?.usagePercentage ?? 0)%")
            return .success

        } catch {
            logger.error("OAuth fetch failed: \(error.localizedDescription)")
            return .error("Network error")
        }
    }

    /// Makes a minimal Messages API call (Haiku, max_tokens=1) and extracts
    /// enterprise rate limit info from the `anthropic-ratelimit-unified-*` headers.
    private func fetchFromHeaders(with accessToken: String) async -> FetchResult {
        var request = URLRequest(url: Self.messagesURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Notchi", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "x"]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else { return .error("Invalid response") }

            guard let h5Util = headerDouble(httpResponse, key: "anthropic-ratelimit-unified-5h-utilization") else {
                logger.debug("No unified rate limit headers in response")
                return .error("No rate limit headers")
            }

            let h5Reset = headerDate(httpResponse, key: "anthropic-ratelimit-unified-5h-reset")

            // Headers return utilization as 0.0-1.0, convert to 0-100
            let usage = QuotaPeriod(utilization: (h5Util * 100).rounded(), resetDate: h5Reset)
            currentUsage = usage
            isConnected = true
            error = nil
            logger.info("Usage fetched via headers: \(usage.usagePercentage)%")
            return .success

        } catch {
            logger.error("Headers fetch failed: \(error.localizedDescription)")
            return .error("Network error")
        }
    }

    private func handleAuthFailure(currentToken: String) async {
        cachedToken = nil
        KeychainManager.clearCachedOAuthToken()

        if let freshToken = KeychainManager.refreshAccessTokenSilently(),
           freshToken != currentToken {
            logger.info("Token refreshed silently from Claude Code keychain")
            await fetchAndStartPolling(with: freshToken)
            return
        }

        error = "Token expired"
        isConnected = false
        stopPolling()
    }

    private func headerDouble(_ response: HTTPURLResponse, key: String) -> Double? {
        guard let value = response.value(forHTTPHeaderField: key) else { return nil }
        return Double(value)
    }

    private func headerDate(_ response: HTTPURLResponse, key: String) -> Date? {
        guard let value = response.value(forHTTPHeaderField: key) else { return nil }
        // Try epoch timestamp
        if let epoch = TimeInterval(value) {
            return Date(timeIntervalSince1970: epoch)
        }
        // Try ISO 8601
        return Self.isoFormatterWithFractionalSeconds.date(from: value)
            ?? Self.isoFormatter.date(from: value)
    }
}
