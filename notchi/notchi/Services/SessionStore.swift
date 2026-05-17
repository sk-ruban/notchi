import Foundation

extension Notification.Name {
    static let sessionStoreActiveSessionCountDidChange = Notification.Name("sessionStoreActiveSessionCountDidChange")
}

@MainActor
@Observable
final class SessionStore {
    static let shared = SessionStore()

    private(set) var sessions: [ProviderSessionKey: SessionData] = [:]
    private(set) var selectedSessionKey: ProviderSessionKey?
    private var displaySessionNumbersById: [String: Int] = [:]
    private var resolveCodexMetadata: @Sendable (String) -> CodexThreadMetadata? = { transcriptPath in
        CodexThreadMetadataResolver.metadata(for: transcriptPath)
    }
    private var resolveCodexCompactionSignals: @Sendable ([String]) -> [String: CodexCompactionSignal] = { threadIds in
        CodexCompactionSignalResolver.latestSignals(threadIds: threadIds)
    }

    private init() {}

    var selectedSessionId: String? {
        selectedSessionKey?.stableId
    }

    var sortedSessions: [SessionData] {
        sessions.values.sorted { lhs, rhs in
            if lhs.isProcessing != rhs.isProcessing {
                return lhs.isProcessing
            }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    var activeSessionCount: Int {
        sessions.count
    }

    var selectedSession: SessionData? {
        guard let selectedSessionKey else { return nil }
        return sessions[selectedSessionKey]
    }

    var effectiveSession: SessionData? {
        if let selected = selectedSession {
            return selected
        }
        if sessions.count == 1 {
            return sessions.values.first
        }
        return sortedSessions.first
    }

    func selectSession(_ sessionKey: ProviderSessionKey) {
        guard sessions[sessionKey] != nil else { return }
        selectedSessionKey = sessionKey
    }

    @discardableResult
    func selectSession(matchingStableId stableId: String) -> SessionData? {
        guard let sessionKey = ProviderSessionKey(stableId: stableId) else { return nil }
        selectSession(sessionKey)
        return sessions[sessionKey]
    }

    func clearSelectedSession() {
        selectedSessionKey = nil
    }

    func process(_ event: HookEvent, sessionStartTimeOverride: Date? = nil) -> SessionData {
        let isInteractive = event.interactive ?? true
        // Remember the active provider so the next launch wave uses the last mascot.
        if AppSettings.lastUsedAgentProvider != event.provider {
            AppSettings.lastUsedAgentProvider = event.provider
        }
        let session = getOrCreateSession(
            sessionKey: event.sessionKey,
            cwd: event.cwd,
            isInteractive: isInteractive,
            sessionStartTime: sessionStartTimeOverride
        )
        let isProcessing = Self.isProcessingStatus(event.status)
        session.updateProcessingState(isProcessing: isProcessing)

        if let mode = event.permissionMode {
            session.updatePermissionMode(mode)
        }

        session.updateClaudeRuntime(processId: event.claudeProcessId)
        session.updateCodexRuntime(processId: event.codexProcessId, origin: event.codexOrigin)
        if event.provider == .codex, let transcriptPath = event.transcriptPath {
            session.updateCodexThreadMetadata(
                transcriptPath: transcriptPath,
                metadata: nil
            )
        }

        switch event.event {
        case .userPromptSubmitted:
            if event.userPrompt != nil || event.userPromptHasAttachments {
                session.recordUserPrompt(event.userPrompt, hasAttachments: event.userPromptHasAttachments)
            }
            session.clearRecentEvents()
            session.clearAssistantMessages()
            session.clearPendingQuestions()
            if Self.isLocalSlashCommand(event.userPrompt) {
                session.updateTask(.idle)
            } else {
                session.advanceSpinnerVerbForReply()
                session.updateTask(.working)
            }

        case .preCompact:
            session.updateTask(.compacting)

        case .sessionStarted:
            if isProcessing {
                session.updateTask(.working)
            }

        case .preToolUse:
            let toolInput = event.toolInput?.mapValues { $0.value }
            session.recordPreToolUse(tool: event.tool, toolInput: toolInput, toolUseId: event.toolUseId)
            if event.tool == "AskUserQuestion" {
                session.updateTask(.waiting)
                session.setPendingQuestions(Self.parseQuestions(from: event.toolInput))
            } else {
                session.clearPendingQuestions()
                session.updateTask(.working)
            }

        case .permissionRequest:
            let question = Self.buildPermissionQuestion(tool: event.tool, toolInput: event.toolInput)
            session.updateTask(.waiting)
            session.setPendingQuestions([question])

        case .postToolUse:
            let success = event.status != "error"
            session.recordPostToolUse(tool: event.tool, toolUseId: event.toolUseId, success: success)
            session.clearPendingQuestions()
            session.updateTask(.working)

        case .stop, .subagentStop:
            session.clearPendingQuestions()
            session.updateTask(.idle)

        case .sessionEnded:
            session.endSession()
            removeSession(event.sessionKey)
        }

        return session
    }

    func displaySessionNumber(for session: SessionData) -> Int {
        displaySessionNumbersById[session.id] ?? 1
    }

    func displaySessionLabel(for session: SessionData) -> String {
        "\(session.projectName) #\(displaySessionNumber(for: session))"
    }

    func displayTitle(for session: SessionData) -> String {
        let label = displaySessionLabel(for: session)
        if let detail = session.codexTitle ?? session.lastUserPrompt {
            return "\(label) - \(detail)"
        }
        return label
    }

    private func getOrCreateSession(
        sessionKey: ProviderSessionKey,
        cwd: String,
        isInteractive: Bool,
        sessionStartTime: Date?
    ) -> SessionData {
        if let existing = sessions[sessionKey] {
            return existing
        }

        let existingXPositions = sessions.values.map(\.spriteXPosition)
        let session = SessionData(
            sessionKey: sessionKey,
            cwd: cwd,
            isInteractive: isInteractive,
            existingXPositions: existingXPositions,
            sessionStartTime: sessionStartTime ?? Date()
        )
        sessions[sessionKey] = session
        recomputeDisplaySessionNumbers()
        postActiveSessionCountChange()

        if activeSessionCount == 1 {
            selectedSessionKey = session.sessionKey
        } else {
            selectedSessionKey = nil
        }

        return session
    }

    private func removeSession(_ sessionKey: ProviderSessionKey) {
        sessions.removeValue(forKey: sessionKey)
        recomputeDisplaySessionNumbers()
        postActiveSessionCountChange()

        if selectedSessionKey == sessionKey {
            selectedSessionKey = nil
        }

        if selectedSessionKey == nil, activeSessionCount == 1 {
            selectedSessionKey = sessions.keys.first
        }
    }

    func dismissSession(_ sessionKey: ProviderSessionKey) {
        sessions[sessionKey]?.endSession()
        removeSession(sessionKey)
    }

    func dismissSession(matchingStableId stableId: String) {
        guard let sessionKey = ProviderSessionKey(stableId: stableId) else { return }
        dismissSession(sessionKey)
    }

    func codexThreadMetadataRequests() -> [CodexThreadMetadataRequest] {
        sessions.values.compactMap { session in
            guard let transcriptPath = session.codexTranscriptPath else { return nil }
            return CodexThreadMetadataRequest(
                sessionKey: session.sessionKey,
                transcriptPath: transcriptPath
            )
        }
    }

    func codexCompactionSignalRequests() -> [CodexCompactionSignalRequest] {
        sessions.values.compactMap { session in
            guard session.isCodexThreadBacked else { return nil }
            return CodexCompactionSignalRequest(
                sessionKey: session.sessionKey,
                threadId: session.rawSessionId
            )
        }
    }

    func resolveCodexThreadMetadata(_ requests: [CodexThreadMetadataRequest]) async -> [CodexThreadMetadataUpdate] {
        let resolver = resolveCodexMetadata
        return await Task.detached(priority: .utility) {
            requests.map { request in
                CodexThreadMetadataUpdate(
                    sessionKey: request.sessionKey,
                    transcriptPath: request.transcriptPath,
                    metadata: resolver(request.transcriptPath)
                )
            }
        }.value
    }

    func resolveCodexCompactionSignals(_ requests: [CodexCompactionSignalRequest]) async -> [CodexCompactionSignalUpdate] {
        let resolver = resolveCodexCompactionSignals
        return await Task.detached(priority: .utility) {
            let signalsByThreadId = resolver(Array(Set(requests.map(\.threadId))))
            return requests.map { request in
                CodexCompactionSignalUpdate(
                    sessionKey: request.sessionKey,
                    signal: signalsByThreadId[request.threadId]
                )
            }
        }.value
    }

    func applyCodexThreadMetadata(_ updates: [CodexThreadMetadataUpdate]) -> [SessionData] {
        var archivedSessions: [SessionData] = []

        for update in updates {
            guard let session = sessions[update.sessionKey],
                  session.codexTranscriptPath == update.transcriptPath else {
                continue
            }

            session.updateCodexThreadMetadata(
                transcriptPath: update.transcriptPath,
                metadata: update.metadata
            )

            if session.codexArchived {
                archivedSessions.append(session)
            }
        }

        return archivedSessions
    }

    func applyCodexCompactionSignals(_ updates: [CodexCompactionSignalUpdate]) {
        for update in updates {
            sessions[update.sessionKey]?.updateCodexCompactionSignal(update.signal)
        }
    }

    func recordAssistantMessages(_ messages: [AssistantMessage], for sessionKey: ProviderSessionKey) {
        guard let session = sessions[sessionKey] else { return }
        session.recordAssistantMessages(messages)
    }

    func session(for sessionKey: ProviderSessionKey) -> SessionData? {
        sessions[sessionKey]
    }

#if DEBUG
    func refreshCodexThreadMetadataForTesting() -> [SessionData] {
        let updates = codexThreadMetadataRequests().map { request in
            CodexThreadMetadataUpdate(
                sessionKey: request.sessionKey,
                transcriptPath: request.transcriptPath,
                metadata: resolveCodexMetadata(request.transcriptPath)
            )
        }
        return applyCodexThreadMetadata(updates)
    }

    func refreshCodexCompactionSignalsForTesting() {
        let requests = codexCompactionSignalRequests()
        let signalsByThreadId = resolveCodexCompactionSignals(Array(Set(requests.map(\.threadId))))
        let updates = requests.map { request in
            CodexCompactionSignalUpdate(
                sessionKey: request.sessionKey,
                signal: signalsByThreadId[request.threadId]
            )
        }
        applyCodexCompactionSignals(updates)
    }

    func setCodexMetadataResolverForTesting(_ resolver: @escaping @Sendable (String) -> CodexThreadMetadata?) {
        resolveCodexMetadata = resolver
    }

    func setCodexCompactionSignalResolverForTesting(_ resolver: @escaping @Sendable ([String]) -> [String: CodexCompactionSignal]) {
        resolveCodexCompactionSignals = resolver
    }

    func resetTestingHooks() {
        resolveCodexMetadata = { transcriptPath in
            CodexThreadMetadataResolver.metadata(for: transcriptPath)
        }
        resolveCodexCompactionSignals = { threadIds in
            CodexCompactionSignalResolver.latestSignals(threadIds: threadIds)
        }
    }
#endif

    private func postActiveSessionCountChange() {
        NotificationCenter.default.post(
            name: .sessionStoreActiveSessionCountDidChange,
            object: self
        )
    }

    private func recomputeDisplaySessionNumbers() {
        let groupedSessions = Dictionary(grouping: sessions.values, by: \.projectName)
        var displayNumbers: [String: Int] = [:]

        for projectSessions in groupedSessions.values {
            let orderedSessions = projectSessions.sorted { lhs, rhs in
                if lhs.sessionStartTime != rhs.sessionStartTime {
                    return lhs.sessionStartTime < rhs.sessionStartTime
                }
                return lhs.id < rhs.id
            }

            for (index, session) in orderedSessions.enumerated() {
                displayNumbers[session.id] = index + 1
            }
        }

        displaySessionNumbersById = displayNumbers
    }

    private static func parseQuestions(from toolInput: [String: AnyCodable]?) -> [PendingQuestion] {
        guard let input = toolInput?.mapValues({ $0.value }),
              let questions = input["questions"] as? [[String: Any]] else { return [] }

        return questions.compactMap { q in
            guard let questionText = q["question"] as? String else { return nil }
            let header = q["header"] as? String
            let rawOptions = q["options"] as? [[String: Any]] ?? []
            let options = rawOptions.compactMap { opt -> (label: String, description: String?)? in
                guard let label = opt["label"] as? String else { return nil }
                return (label: label, description: opt["description"] as? String)
            }
            return PendingQuestion(question: questionText, header: header, options: options)
        }
    }

    private static let localSlashCommands: Set<String> = [
        "/clear", "/help", "/cost", "/status",
        "/vim", "/fast", "/model", "/login", "/logout",
    ]

    static func isLocalSlashCommand(_ prompt: String?) -> Bool {
        guard let prompt, prompt.hasPrefix("/") else { return false }
        let command = String(prompt.prefix(while: { !$0.isWhitespace }))
        return localSlashCommands.contains(command)
    }

    private static func buildPermissionQuestion(tool: String?, toolInput: [String: AnyCodable]?) -> PendingQuestion {
        let toolName = tool ?? "Tool"
        let input = toolInput?.mapValues { $0.value }
        let description = SessionEvent.deriveDescription(tool: tool, toolInput: input)
        return PendingQuestion(
            question: description ?? "\(toolName) wants to proceed",
            header: "Permission Request",
            // Claude Code permission prompts always present these three choices
            options: [
                (label: "Yes", description: nil),
                (label: "Yes, and don't ask again", description: nil),
                (label: "No", description: nil),
            ]
        )
    }

    private static func isProcessingStatus(_ status: String) -> Bool {
        status != "waiting_for_input" && status != "ended"
    }
}

nonisolated struct CodexThreadMetadata: Sendable, Equatable {
    let title: String?
    let archived: Bool
}

nonisolated struct CodexThreadMetadataRequest: Sendable, Equatable {
    let sessionKey: ProviderSessionKey
    let transcriptPath: String
}

nonisolated struct CodexThreadMetadataUpdate: Sendable, Equatable {
    let sessionKey: ProviderSessionKey
    let transcriptPath: String
    let metadata: CodexThreadMetadata?
}

nonisolated struct CodexCompactionSignal: Sendable, Equatable {
    let observedAt: Date
    let totalUsageTokens: Int
    let estimatedTokenCount: Int?
    let autoCompactLimit: Int
    let tokenLimitReached: Bool
}

nonisolated struct CodexCompactionSignalRequest: Sendable, Equatable {
    let sessionKey: ProviderSessionKey
    let threadId: String
}

nonisolated struct CodexCompactionSignalUpdate: Sendable, Equatable {
    let sessionKey: ProviderSessionKey
    let signal: CodexCompactionSignal?
}

nonisolated enum CodexFileSystem {
    static let sqliteSeparator = "\u{1F}"

    private static var codexDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    static func latestSQLiteURL(prefix: String) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: codexDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }

        return entries.compactMap { url -> (version: Int, url: URL)? in
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(prefix),
                  url.pathExtension == "sqlite",
                  let version = Int(name.dropFirst(prefix.count)) else {
                return nil
            }
            return (version, url)
        }
        .max { lhs, rhs in lhs.version < rhs.version }?
        .url
    }

    static func runSQLite(query: String, databasePath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-batch", "-noheader", "-separator", sqliteSeparator, databasePath, query]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain stdout before waiting so sqlite3 cannot block on a full pipe
        // while Notchi waits for the process to exit.
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return output?.isEmpty == false ? output : nil
    }
}

nonisolated enum CodexThreadMetadataResolver {
    private static var stateURL: URL? {
        CodexFileSystem.latestSQLiteURL(prefix: "state_")
    }

    static func metadata(for transcriptPath: String) -> CodexThreadMetadata? {
        let trimmedPath = transcriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty,
              let stateURL,
              FileManager.default.fileExists(atPath: stateURL.path) else {
            return nil
        }

        let query = "SELECT id, rollout_path, hex(title), archived FROM threads;"
        guard let output = CodexFileSystem.runSQLite(query: query, databasePath: stateURL.path) else {
            return nil
        }

        return metadata(fromSQLiteOutput: output, matchingTranscriptPath: trimmedPath)
    }

    static func metadata(fromSQLiteOutput output: String, matchingTranscriptPath transcriptPath: String) -> CodexThreadMetadata? {
        let threadId = codexThreadId(from: transcriptPath)

        for row in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = row.split(separator: Character(CodexFileSystem.sqliteSeparator), omittingEmptySubsequences: false)
            guard parts.count >= 4 else { continue }

            let rowId = String(parts[0])
            let rolloutPath = String(parts[1])
            let matchesThreadId = threadId.map { $0 == rowId } ?? false
            guard rolloutPath == transcriptPath || matchesThreadId else { continue }

            let title = decodeHexString(String(parts[2]))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let archived = String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines) != "0"

            return CodexThreadMetadata(
                title: title?.isEmpty == false ? title : nil,
                archived: archived
            )
        }

        return nil
    }

    private static func codexThreadId(from transcriptPath: String) -> String? {
        let fileName = URL(fileURLWithPath: transcriptPath).deletingPathExtension().lastPathComponent
        let components = fileName.split(separator: "-")
        guard components.count >= 5 else { return nil }

        let idComponents = components.suffix(5)
        let id = idComponents.joined(separator: "-")
        return id.count == 36 ? id : nil
    }

    private static func decodeHexString(_ hexString: String) -> String? {
        guard !hexString.isEmpty, hexString.count.isMultiple(of: 2) else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)

        var index = hexString.startIndex
        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = nextIndex
        }

        return String(bytes: bytes, encoding: .utf8)
    }
}

// WHY: Codex does not currently emit a documented compaction hook, and the
// rollout JSONL exposes token counts but not a stable "compacting" state. Until
// there is a public event, use Codex's local token-usage log as a best-effort
// internal signal and fail closed if its shape changes.
nonisolated enum CodexCompactionSignalResolver {
    private static var logsURL: URL? {
        CodexFileSystem.latestSQLiteURL(prefix: "logs_")
    }

    static func latestSignals(threadIds: [String]) -> [String: CodexCompactionSignal] {
        let validThreadIds = Array(Set(threadIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { UUID(uuidString: $0) != nil }

        guard !validThreadIds.isEmpty,
              let logsURL,
              FileManager.default.fileExists(atPath: logsURL.path) else {
            return [:]
        }

        let threadIdList = validThreadIds
            .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
            .joined(separator: ", ")
        let query = """
        SELECT thread_id, ts, ts_nanos, feedback_log_body
        FROM (
            SELECT thread_id, ts, ts_nanos, feedback_log_body,
                   ROW_NUMBER() OVER (
                       PARTITION BY thread_id
                       ORDER BY ts DESC, ts_nanos DESC, id DESC
                   ) AS row_number
            FROM logs
            WHERE thread_id IN (\(threadIdList))
              AND target = 'codex_core::session::turn'
              AND feedback_log_body LIKE '%post sampling token usage%'
        )
        WHERE row_number = 1;
        """

        guard let output = CodexFileSystem.runSQLite(query: query, databasePath: logsURL.path) else {
            return [:]
        }

        return latestSignals(fromSQLiteOutput: output)
    }

    static func latestSignals(fromSQLiteOutput output: String) -> [String: CodexCompactionSignal] {
        var signals: [String: CodexCompactionSignal] = [:]

        for row in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = row.split(separator: Character(CodexFileSystem.sqliteSeparator), maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4,
                  UUID(uuidString: String(parts[0])) != nil,
                  let seconds = TimeInterval(String(parts[1])),
                  let nanoseconds = TimeInterval(String(parts[2])),
                  let signal = parseLogBody(
                    String(parts[3]),
                    observedAt: Date(timeIntervalSince1970: seconds + (nanoseconds / 1_000_000_000))
                  ) else {
                continue
            }

            signals[String(parts[0])] = signal
        }

        return signals
    }

    private static func parseLogBody(_ body: String, observedAt: Date) -> CodexCompactionSignal? {
        guard let totalUsageTokens = intValue(named: "total_usage_tokens", in: body),
              let autoCompactLimit = intValue(named: "auto_compact_limit", in: body),
              let tokenLimitReached = boolValue(named: "token_limit_reached", in: body) else {
            return nil
        }

        return CodexCompactionSignal(
            observedAt: observedAt,
            totalUsageTokens: totalUsageTokens,
            estimatedTokenCount: optionalIntValue(named: "estimated_token_count", in: body),
            autoCompactLimit: autoCompactLimit,
            tokenLimitReached: tokenLimitReached
        )
    }

    private static func intValue(named name: String, in text: String) -> Int? {
        guard let range = text.range(
            of: "\\b\(name)=([0-9]+)",
            options: .regularExpression
        ) else {
            return nil
        }

        let value = text[range].dropFirst(name.count + 1)
        return Int(value)
    }

    private static func optionalIntValue(named name: String, in text: String) -> Int? {
        guard let range = text.range(
            of: "\\b\(name)=Some\\(([0-9]+)\\)",
            options: .regularExpression
        ) else {
            return nil
        }

        let matched = text[range]
        let prefix = "\(name)=Some("
        return Int(matched.dropFirst(prefix.count).dropLast())
    }

    private static func boolValue(named name: String, in text: String) -> Bool? {
        guard let range = text.range(
            of: "\\b\(name)=(true|false)",
            options: .regularExpression
        ) else {
            return nil
        }

        return text[range].hasSuffix("true")
    }

}
