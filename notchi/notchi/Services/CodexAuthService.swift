import AppKit
import Foundation
import os.log

nonisolated private let logger = Logger(subsystem: "com.ruban.notchi", category: "CodexAuthService")

nonisolated private enum CodexDateParser {
    nonisolated static func parse(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        let fractionalISO8601Formatter = ISO8601DateFormatter()
        fractionalISO8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let basicISO8601Formatter = ISO8601DateFormatter()

        return fractionalISO8601Formatter.date(from: value)
            ?? basicISO8601Formatter.date(from: value)
    }
}

nonisolated enum CodexAuthMode: String, Equatable, Sendable {
    case chatgpt
    case apikey
    case chatgptAuthTokens

    nonisolated init?(normalizedValue: String?) {
        guard let normalized = normalizedValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }
        self.init(rawValue: normalized)
    }

    var displayName: String {
        switch self {
        case .chatgpt, .chatgptAuthTokens:
            return "ChatGPT"
        case .apikey:
            return "API Key"
        }
    }
}

nonisolated struct CodexAuthFileMetadata: Equatable, Sendable {
    let authMode: CodexAuthMode?
    let lastRefresh: Date?
}

nonisolated struct CodexAuthSnapshot: Equatable, Sendable {
    let isConnected: Bool
    let authMode: CodexAuthMode?
    let planType: String?
    let email: String?
    let lastRefresh: Date?

    static let disconnected = CodexAuthSnapshot(
        isConnected: false,
        authMode: nil,
        planType: nil,
        email: nil,
        lastRefresh: nil
    )
}

nonisolated private struct CodexAuthFile: Decodable {
    let authMode: String?
    let lastRefresh: String?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case lastRefresh = "last_refresh"
    }
}

extension CodexAuthFileMetadata {
    nonisolated static func decode(from data: Data) -> CodexAuthFileMetadata? {
        guard let file = try? JSONDecoder().decode(CodexAuthFile.self, from: data) else {
            return nil
        }

        return CodexAuthFileMetadata(
            authMode: CodexAuthMode(normalizedValue: file.authMode),
            lastRefresh: CodexDateParser.parse(file.lastRefresh)
        )
    }
}

nonisolated struct CodexCLIStatus: Equatable, Sendable {
    let isConnected: Bool
    let authMode: CodexAuthMode?

    nonisolated static func parse(output: String) -> CodexCLIStatus? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.localizedCaseInsensitiveContains("Logged in using ChatGPT") {
            return CodexCLIStatus(isConnected: true, authMode: .chatgpt)
        }

        if trimmed.localizedCaseInsensitiveContains("Logged in using an API key") {
            return CodexCLIStatus(isConnected: true, authMode: .apikey)
        }

        if trimmed.localizedCaseInsensitiveContains("Not logged in") {
            return CodexCLIStatus(isConnected: false, authMode: nil)
        }

        return nil
    }
}

nonisolated private struct CodexAppServerResponse<Result: Decodable>: Decodable {
    let id: Int?
    let result: Result?
}

nonisolated private struct CodexAppServerInitializeResult: Decodable {
    let codexHome: String?
}

nonisolated private struct CodexAppServerAccountReadResult: Decodable {
    let account: CodexAppServerAccount?
    let requiresOpenaiAuth: Bool
}

nonisolated private struct CodexAppServerAccount: Decodable {
    let type: String
    let email: String?
    let planType: String?
}

nonisolated private final class ProcessLineBuffer {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    func hasCompleteLine() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return buffer.contains(0x0A)
    }

    func popLine() -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard let newlineIndex = buffer.firstIndex(of: 0x0A) else {
            return nil
        }

        let lineData = buffer.prefix(upTo: newlineIndex)
        buffer.removeSubrange(...newlineIndex)

        let normalizedData: Data
        if lineData.last == 0x0D {
            normalizedData = lineData.dropLast()
        } else {
            normalizedData = Data(lineData)
        }

        guard !normalizedData.isEmpty else { return "" }
        return String(data: normalizedData, encoding: .utf8)
    }
}

nonisolated private enum CodexAuthProbe {
    nonisolated private static let refreshThreshold: TimeInterval = 8 * 24 * 60 * 60
    nonisolated private static let responseTimeout: TimeInterval = 2.0

    nonisolated static func loadSnapshot(forceTokenRefresh: Bool) -> CodexAuthSnapshot {
        guard let executableURL = CodexCLIFinder.resolveExecutableURL() else {
            return fileFallbackSnapshot()
        }

        if let snapshot = probeWithAppServer(at: executableURL, forceTokenRefresh: forceTokenRefresh) {
            return snapshot
        }

        if let snapshot = probeWithLoginStatus(at: executableURL) {
            return snapshot
        }

        return fileFallbackSnapshot()
    }

    nonisolated private static func probeWithAppServer(
        at executableURL: URL,
        forceTokenRefresh: Bool
    ) -> CodexAuthSnapshot? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let lineBuffer = ProcessLineBuffer()
        let lineSemaphore = DispatchSemaphore(value: 0)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                lineSemaphore.signal()
                return
            }

            lineBuffer.append(data)
            if lineBuffer.hasCompleteLine() {
                lineSemaphore.signal()
            }
        }

        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            try? stdinPipe.fileHandleForWriting.close()
            terminate(process)
        }

        do {
            try process.run()

            try sendJSON(
                [
                    "id": 1,
                    "method": "initialize",
                    "params": [
                        "clientInfo": [
                            "name": "notchi",
                            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                        ],
                        "capabilities": [:],
                    ],
                ],
                to: stdinPipe.fileHandleForWriting
            )

            guard let initializeResult = readResponse(
                expectedID: 1,
                from: lineBuffer,
                semaphore: lineSemaphore,
                timeout: responseTimeout,
                type: CodexAppServerInitializeResult.self
            ) else {
                logProbeError("initialize", process: process)
                return nil
            }

            let codexHome = codexHomeURL(from: initializeResult.codexHome)
            let metadata = loadAuthFileMetadata(at: codexHome)
            let shouldRefresh = forceTokenRefresh || needsRefresh(metadata: metadata)

            try sendJSON(
                [
                    "id": 2,
                    "method": "account/read",
                    "params": [
                        "refreshToken": shouldRefresh,
                    ],
                ],
                to: stdinPipe.fileHandleForWriting
            )

            guard let accountResult = readResponse(
                expectedID: 2,
                from: lineBuffer,
                semaphore: lineSemaphore,
                timeout: responseTimeout,
                type: CodexAppServerAccountReadResult.self
            ) else {
                logProbeError("account/read", process: process)
                return nil
            }

            return snapshot(from: accountResult, metadata: metadata)
        } catch {
            logger.error("Codex app-server probe failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    nonisolated private static func probeWithLoginStatus(at executableURL: URL) -> CodexAuthSnapshot? {
        guard let result = runProcess(
            at: executableURL,
            arguments: ["login", "status"],
            timeout: responseTimeout
        ),
        result.terminationStatus == 0,
        let status = CodexCLIStatus.parse(output: result.stdout) else {
            return nil
        }

        let metadata = loadAuthFileMetadata(at: defaultCodexHomeURL())
        return CodexAuthSnapshot(
            isConnected: status.isConnected,
            authMode: status.authMode ?? metadata?.authMode,
            planType: nil,
            email: nil,
            lastRefresh: metadata?.lastRefresh
        )
    }

    nonisolated private static func fileFallbackSnapshot() -> CodexAuthSnapshot {
        let metadata = loadAuthFileMetadata(at: defaultCodexHomeURL())
        return CodexAuthSnapshot(
            isConnected: metadata?.authMode != nil,
            authMode: metadata?.authMode,
            planType: nil,
            email: nil,
            lastRefresh: metadata?.lastRefresh
        )
    }

    nonisolated private static func snapshot(
        from result: CodexAppServerAccountReadResult,
        metadata: CodexAuthFileMetadata?
    ) -> CodexAuthSnapshot {
        guard let account = result.account else {
            return CodexAuthSnapshot(
                isConnected: false,
                authMode: metadata?.authMode,
                planType: nil,
                email: nil,
                lastRefresh: metadata?.lastRefresh
            )
        }

        let authMode = CodexAuthMode(normalizedValue: account.type) ?? metadata?.authMode

        return CodexAuthSnapshot(
            isConnected: true,
            authMode: authMode,
            planType: account.planType,
            email: account.email,
            lastRefresh: metadata?.lastRefresh
        )
    }

    nonisolated private static func needsRefresh(metadata: CodexAuthFileMetadata?) -> Bool {
        guard let lastRefresh = metadata?.lastRefresh else { return false }
        return Date().timeIntervalSince(lastRefresh) >= refreshThreshold
    }

    nonisolated private static func loadAuthFileMetadata(at codexHome: URL) -> CodexAuthFileMetadata? {
        let authFileURL = codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authFileURL) else {
            return nil
        }
        return CodexAuthFileMetadata.decode(from: data)
    }

    nonisolated private static func defaultCodexHomeURL() -> URL {
        if let rawCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawCodexHome.isEmpty {
            return URL(fileURLWithPath: rawCodexHome).standardizedFileURL
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
    }

    nonisolated private static func codexHomeURL(from rawPath: String?) -> URL {
        guard let rawPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return defaultCodexHomeURL()
        }
        return URL(fileURLWithPath: rawPath).standardizedFileURL
    }

    nonisolated private static func sendJSON(_ object: Any, to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }

    nonisolated private static func readResponse<Result: Decodable>(
        expectedID: Int,
        from buffer: ProcessLineBuffer,
        semaphore: DispatchSemaphore,
        timeout: TimeInterval,
        type _: Result.Type
    ) -> Result? {
        let deadline = DispatchTime.now() + timeout

        while true {
            while let line = buffer.popLine() {
                guard let data = line.data(using: .utf8),
                      let response = try? JSONDecoder().decode(CodexAppServerResponse<Result>.self, from: data),
                      response.id == expectedID,
                      let result = response.result else {
                    continue
                }
                return result
            }

            if semaphore.wait(timeout: deadline) != .success {
                return nil
            }
        }
    }

    nonisolated private static func runProcess(
        at executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) -> (terminationStatus: Int32, stdout: String, stderr: String)? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        do {
            try process.run()
        } catch {
            logger.error(
                "Failed to run Codex command \(arguments.joined(separator: " "), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            terminate(process)
            logger.error("Timed out running Codex command \(arguments.joined(separator: " "), privacy: .public)")
            return nil
        }

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        return (process.terminationStatus, stdout, stderr)
    }

    nonisolated private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    nonisolated private static func logProbeError(_ phase: String, process: Process) {
        if process.terminationReason == .exit {
            logger.error(
                "Codex auth probe failed during \(phase, privacy: .public) with exit code \(process.terminationStatus, privacy: .public)"
            )
        } else {
            logger.error("Codex auth probe failed during \(phase, privacy: .public)")
        }
    }
}

@MainActor
@Observable
final class CodexAuthService {
    static let shared = CodexAuthService()

    private(set) var isConnected = false
    private(set) var authMode: CodexAuthMode?
    private(set) var planType: String?
    private(set) var email: String?
    private(set) var lastRefresh: Date?

    private var refreshTask: Task<Void, Never>?

    private init() {}

    var statusText: String {
        guard isConnected else { return "Not Connected" }

        switch authMode {
        case .chatgpt, .chatgptAuthTokens:
            if let planName = planType?.codexPlanDisplayName {
                return "ChatGPT \(planName)"
            }
            return "ChatGPT"
        case .apikey:
            return "API Key"
        case nil:
            return "Connected"
        }
    }

    func start() {
        Task { [weak self] in
            await self?.refresh()
        }

        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    func refresh(forceTokenRefresh: Bool = false) async {
        let snapshot = await loadSnapshot(forceTokenRefresh: forceTokenRefresh)
        apply(snapshot)
    }

    func handleAction() {
        Task { [weak self] in
            guard let self else { return }
            await self.refresh(forceTokenRefresh: true)

            guard !self.isConnected else { return }

            if !self.openLoginInTerminal() {
                NSWorkspace.shared.open(URL(string: "https://chatgpt.com")!)
            }
        }
    }

    private func apply(_ snapshot: CodexAuthSnapshot) {
        isConnected = snapshot.isConnected
        authMode = snapshot.authMode
        planType = snapshot.planType
        email = snapshot.email
        lastRefresh = snapshot.lastRefresh
    }

    private func loadSnapshot(forceTokenRefresh: Bool) async -> CodexAuthSnapshot {
        await Task.detached(priority: .utility) {
            CodexAuthProbe.loadSnapshot(forceTokenRefresh: forceTokenRefresh)
        }.value
    }

    private func openLoginInTerminal() -> Bool {
        let script: String
        if let executableURL = CodexCLIFinder.resolveExecutableURL() {
            let appleScriptPath = executableURL.path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            script = """
            tell application "Terminal"
                activate
                do script (quoted form of "\(appleScriptPath)") & " login"
            end tell
            """
        } else {
            script = """
            tell application "Terminal"
                activate
                do script "codex login"
            end tell
            """
        }

        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if result != nil {
            return true
        }

        if let error {
            logger.error("Failed to launch codex login in Terminal: \(error, privacy: .public)")
        }
        return false
    }
}

private extension String {
    var codexPlanDisplayName: String? {
        switch self {
        case "free":
            return "Free"
        case "go":
            return "Go"
        case "plus":
            return "Plus"
        case "pro":
            return "Pro"
        case "team":
            return "Team"
        case "self_serve_business_usage_based", "business":
            return "Business"
        case "enterprise_cbp_usage_based", "enterprise":
            return "Enterprise"
        case "edu":
            return "Edu"
        default:
            return nil
        }
    }
}
