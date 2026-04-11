import Foundation
import os.log
import SQLite3

actor CodexSessionMonitor {
    static let shared = CodexSessionMonitor()
    nonisolated private static let logger = Logger(
        subsystem: "com.ruban.notchi",
        category: "CodexSessionMonitor"
    )

    private let discoveryWindow: TimeInterval = 600
    private let activeFileFallbackWindow: TimeInterval = 3600
    private let pollInterval: Duration = .seconds(1)
    private let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")
    private let sessionIndexURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/session_index.jsonl")
    private let stateDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/state_5.sqlite")
    private let databaseFallbackLimit = 200
    private let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()
    private let fractionalISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let basicISO8601Formatter = ISO8601DateFormatter()

    private var pollTask: Task<Void, Never>?
    private var startedAt = Date()
    private var trackedSessionFiles: [String: URL] = [:]
    private var trackedSessionCWDs: [String: String] = [:]
    private var lastOffsets: [String: UInt64] = [:]
    private var toolNamesByCallID: [String: [String: String]] = [:]
    private var messageSequenceBySession: [String: Int] = [:]

    func start() {
        guard pollTask == nil else { return }

        startedAt = Date()
        pollTask = Task {
            while !Task.isCancelled {
                await scan()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    private func scan() async {
        discoverRecentSessions()

        for (sessionId, fileURL) in trackedSessionFiles {
            await processChanges(for: sessionId, fileURL: fileURL)
        }
    }

    private func discoverRecentSessions() {
        let threshold = startedAt.addingTimeInterval(-discoveryWindow)

        for candidate in recentSessionCandidates() {
            guard trackedSessionFiles[candidate.id] == nil else { continue }

            guard let fileURL = locateSessionFile(for: candidate) else {
                continue
            }

            let shouldTrack = candidate.updatedAt >= threshold
                || isRecentlyModified(fileURL, since: threshold.addingTimeInterval(-activeFileFallbackWindow))
            guard shouldTrack else { continue }

            trackedSessionFiles[candidate.id] = fileURL
            if let cwd = candidate.cwd {
                trackedSessionCWDs[candidate.id] = canonicalizeCodexPath(cwd)
            }
            Self.logger.info(
                "Tracking Codex session \(candidate.id, privacy: .public) at \(fileURL.path, privacy: .public)"
            )
        }
    }

    private func recentSessionCandidates() -> [CodexSessionCandidate] {
        var mergedCandidates: [String: CodexSessionCandidate] = [:]

        for candidate in loadSessionIndexCandidates() {
            mergedCandidates[candidate.id] = candidate
        }

        for candidate in loadStateDatabaseCandidates() {
            if let existing = mergedCandidates[candidate.id] {
                mergedCandidates[candidate.id] = existing.merging(candidate)
            } else {
                mergedCandidates[candidate.id] = candidate
            }
        }

        return mergedCandidates.values.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    private func loadSessionIndexCandidates() -> [CodexSessionCandidate] {
        guard let data = try? Data(contentsOf: sessionIndexURL),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        return content.split(separator: "\n").compactMap { line in
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let sessionId = json["id"] as? String,
                  let updatedAtString = json["updated_at"] as? String,
                  let updatedAt = parseISO8601Date(from: updatedAtString) else {
                return nil
            }

            return CodexSessionCandidate(id: sessionId, updatedAt: updatedAt)
        }
    }

    private func loadStateDatabaseCandidates() -> [CodexSessionCandidate] {
        guard FileManager.default.fileExists(atPath: stateDatabaseURL.path) else {
            return []
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(stateDatabaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            sqlite3_close(database)
            return []
        }
        defer { sqlite3_close(database) }

        let query = """
        SELECT id, rollout_path, updated_at, cwd
        FROM threads
        WHERE archived = 0
        ORDER BY updated_at DESC
        LIMIT ?
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(databaseFallbackLimit))

        var candidates: [CodexSessionCandidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawId = sqlite3_column_text(statement, 0) else { continue }

            let id = String(cString: rawId)
            let rolloutPath = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let updatedAtSeconds = sqlite3_column_int64(statement, 2)
            let cwd = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let updatedAt = Date(timeIntervalSince1970: TimeInterval(updatedAtSeconds))

            candidates.append(
                CodexSessionCandidate(
                    id: id,
                    updatedAt: updatedAt,
                    rolloutPath: rolloutPath,
                    cwd: cwd
                )
            )
        }

        return candidates
    }

    private func locateSessionFile(for candidate: CodexSessionCandidate) -> URL? {
        if let rolloutPath = candidate.rolloutPath {
            let rolloutURL = URL(fileURLWithPath: rolloutPath)
            if FileManager.default.fileExists(atPath: rolloutURL.path) {
                return rolloutURL
            }
        }

        for dayDirectory in candidateSessionDirectories(for: candidate.updatedAt) {
            if let fileURL = findSessionFile(in: dayDirectory, sessionId: candidate.id) {
                return fileURL
            }
        }

        return findSessionFile(in: sessionsRoot, sessionId: candidate.id)
    }

    private func processChanges(for sessionId: String, fileURL: URL) async {
        guard let fileHandle = FileHandle(forReadingAtPath: fileURL.path) else {
            return
        }
        defer { try? fileHandle.close() }

        let fileSize: UInt64
        do {
            fileSize = try fileHandle.seekToEnd()
        } catch {
            return
        }

        var currentOffset = lastOffsets[sessionId] ?? 0
        if fileSize < currentOffset {
            currentOffset = 0
            toolNamesByCallID[sessionId] = [:]
        }

        guard fileSize > currentOffset else { return }

        do {
            try fileHandle.seek(toOffset: currentOffset)
        } catch {
            return
        }

        guard let newData = try? fileHandle.readToEnd() else {
            return
        }

        guard let lastNewlineIndex = newData.lastIndex(of: 0x0A) else {
            lastOffsets[sessionId] = currentOffset
            return
        }

        let processableData = newData.prefix(through: lastNewlineIndex)
        guard let newContent = String(data: processableData, encoding: .utf8) else {
            return
        }

        for line in newContent.split(separator: "\n") {
            await processLine(String(line), trackedSessionID: sessionId)
        }

        lastOffsets[sessionId] = currentOffset + UInt64(processableData.count)
    }

    private func processLine(_ line: String, trackedSessionID: String) async {
        guard let lineData = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "session_meta":
            await handleSessionMeta(json)
        case "response_item":
            await handleResponseItem(json, sessionId: trackedSessionID)
        case "event_msg":
            await handleEventMessage(json, sessionId: trackedSessionID)
        default:
            break
        }
    }

    private func handleSessionMeta(_ json: [String: Any]) async {
        guard let payload = json["payload"] as? [String: Any],
              let sessionId = payload["id"] as? String,
              let rawCWD = payload["cwd"] as? String else {
            return
        }

        let cwd = canonicalizeCodexPath(rawCWD)
        trackedSessionCWDs[sessionId] = cwd
        Self.logger.info(
            "Codex session metadata loaded for \(sessionId, privacy: .public) at \(cwd, privacy: .public)"
        )
        await dispatch(
            .event(
                HookEvent(
                    provider: .codex,
                    sessionId: sessionId,
                    cwd: cwd,
                    event: "SessionStart",
                    status: "waiting_for_input",
                    interactive: true
                )
            )
        )
    }

    private func handleResponseItem(_ json: [String: Any], sessionId: String) async {
        guard let payload = json["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String else {
            return
        }

        switch payloadType {
        case "message":
            await handleMessage(payload, sessionId: sessionId)
        case "function_call":
            await handleFunctionCall(payload, sessionId: sessionId)
        case "function_call_output":
            await handleFunctionCallOutput(payload, sessionId: sessionId)
        case "custom_tool_call":
            await handleCustomToolCall(payload, sessionId: sessionId)
        case "custom_tool_call_output":
            await handleCustomToolCallOutput(payload, sessionId: sessionId)
        default:
            break
        }
    }

    private func handleEventMessage(_ json: [String: Any], sessionId: String) async {
        guard let payload = json["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String,
              payloadType == "task_complete",
              let cwd = trackedSessionCWDs[sessionId] else {
            return
        }

        await dispatch(
            .event(
                HookEvent(
                    provider: .codex,
                    sessionId: sessionId,
                    cwd: cwd,
                    event: "Stop",
                    status: "waiting_for_input",
                    interactive: true
                )
            )
        )
    }

    private func handleMessage(_ payload: [String: Any], sessionId: String) async {
        guard let role = payload["role"] as? String,
              let text = extractMessageText(from: payload["content"]) else {
            return
        }

        switch role {
        case "user":
            guard !shouldIgnoreUserMessage(text),
                  let cwd = trackedSessionCWDs[sessionId] else {
                return
            }

            await dispatch(
                .event(
                    HookEvent(
                        provider: .codex,
                        sessionId: sessionId,
                        cwd: cwd,
                        event: "UserPromptSubmit",
                        status: "processing",
                        userPrompt: text,
                        interactive: true
                    )
                )
            )
        case "assistant":
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let sequence = nextMessageSequence(for: sessionId)
            let message = AssistantMessage(
                id: "\(sessionId)-codex-\(sequence)",
                text: trimmed,
                timestamp: parseTimestamp(from: payload["timestamp"])
            )
            await dispatch(.assistant(sessionId, message))
        default:
            break
        }
    }

    private func handleFunctionCall(_ payload: [String: Any], sessionId: String) async {
        guard let name = payload["name"] as? String,
              let callID = payload["call_id"] as? String,
              let cwd = trackedSessionCWDs[sessionId] else {
            return
        }

        let rawInput = parseArguments(from: payload["arguments"] as? String)
        let normalizedTool = normalizeToolName(name)
        toolNamesByCallID[sessionId, default: [:]][callID] = normalizedTool
        let wrappedInput = rawInput.reduce(into: [String: AnyCodable]()) { partialResult, entry in
            partialResult[entry.key] = AnyCodable(entry.value)
        }

        await dispatch(
            .event(
                HookEvent(
                    provider: .codex,
                    sessionId: sessionId,
                    cwd: cwd,
                    event: "PreToolUse",
                    status: "running_tool",
                    tool: normalizedTool,
                    toolInput: wrappedInput,
                    toolUseId: callID,
                    interactive: true
                )
            )
        )
    }

    private func handleFunctionCallOutput(_ payload: [String: Any], sessionId: String) async {
        guard let callID = payload["call_id"] as? String,
              let cwd = trackedSessionCWDs[sessionId] else {
            return
        }

        let toolName = toolNamesByCallID[sessionId]?[callID]
        let output = payload["output"] as? String

        await dispatch(
            .event(
                HookEvent(
                    provider: .codex,
                    sessionId: sessionId,
                    cwd: cwd,
                    event: "PostToolUse",
                    status: isSuccessfulToolOutput(output) ? "processing" : "error",
                    tool: toolName,
                    toolUseId: callID,
                    interactive: true
                )
            )
        )
    }

    private func handleCustomToolCall(_ payload: [String: Any], sessionId: String) async {
        guard let name = payload["name"] as? String,
              let callID = payload["call_id"] as? String,
              let cwd = trackedSessionCWDs[sessionId] else {
            return
        }

        let rawInput = parseArguments(from: payload["input"] as? String)
        let normalizedTool = normalizeToolName(name)
        toolNamesByCallID[sessionId, default: [:]][callID] = normalizedTool
        let wrappedInput = rawInput.reduce(into: [String: AnyCodable]()) { partialResult, entry in
            partialResult[entry.key] = AnyCodable(entry.value)
        }

        await dispatch(
            .event(
                HookEvent(
                    provider: .codex,
                    sessionId: sessionId,
                    cwd: cwd,
                    event: "PreToolUse",
                    status: "running_tool",
                    tool: normalizedTool,
                    toolInput: wrappedInput,
                    toolUseId: callID,
                    interactive: true
                )
            )
        )
    }

    private func handleCustomToolCallOutput(_ payload: [String: Any], sessionId: String) async {
        guard let callID = payload["call_id"] as? String,
              let cwd = trackedSessionCWDs[sessionId] else {
            return
        }

        let toolName = toolNamesByCallID[sessionId]?[callID]
        let output = payload["output"] as? String

        await dispatch(
            .event(
                HookEvent(
                    provider: .codex,
                    sessionId: sessionId,
                    cwd: cwd,
                    event: "PostToolUse",
                    status: isSuccessfulToolOutput(output) ? "processing" : "error",
                    tool: toolName,
                    toolUseId: callID,
                    interactive: true
                )
            )
        )
    }

    private func dispatch(_ update: CodexSessionUpdate) async {
        await MainActor.run {
            switch update {
            case .event(let event):
                NotchiStateMachine.shared.handleEvent(event)
            case .assistant(let sessionId, let message):
                SessionStore.shared.recordAssistantMessages([message], for: sessionId)
            }
        }
    }

    private func parseArguments(from rawArguments: String?) -> [String: Any] {
        guard let rawArguments,
              let data = rawArguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func extractMessageText(from rawContent: Any?) -> String? {
        if let blocks = rawContent as? [[String: Any]] {
            let text = blocks.compactMap { block -> String? in
                if let text = block["text"] as? String {
                    return text
                }
                if let inputText = block["input_text"] as? String {
                    return inputText
                }
                if let outputText = block["output_text"] as? String {
                    return outputText
                }
                return nil
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

            return text.isEmpty ? nil : text
        }

        if let text = rawContent as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return nil
    }

    private func shouldIgnoreUserMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("# AGENTS.md instructions")
            || trimmed.hasPrefix("<environment_context>")
            || trimmed.hasPrefix("<INSTRUCTIONS>")
    }

    private func nextMessageSequence(for sessionId: String) -> Int {
        let nextValue = messageSequenceBySession[sessionId, default: 0] + 1
        messageSequenceBySession[sessionId] = nextValue
        return nextValue
    }

    private func normalizeToolName(_ name: String) -> String {
        switch name {
        case "request_user_input":
            return "AskUserQuestion"
        default:
            return name
        }
    }

    private func isSuccessfulToolOutput(_ output: String?) -> Bool {
        guard let output else { return true }
        guard let exitCodeRange = output.range(of: "Process exited with code ") else {
            return true
        }

        let codeText = output[exitCodeRange.upperBound...]
            .prefix(while: { $0.isNumber })
        return Int(codeText) == 0
    }

    private func parseTimestamp(from rawValue: Any?) -> Date {
        guard let string = rawValue as? String else { return Date() }
        return parseISO8601Date(from: string) ?? Date()
    }

    private func isRecentlyModified(_ fileURL: URL, since threshold: Date) -> Bool {
        guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
              let modificationDate = values.contentModificationDate else {
            return false
        }
        return modificationDate >= threshold
    }

    private func parseISO8601Date(from string: String) -> Date? {
        fractionalISO8601Formatter.date(from: string) ?? basicISO8601Formatter.date(from: string)
    }

    private func canonicalizeCodexPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func candidateSessionDirectories(for updatedAt: Date) -> [URL] {
        let localCalendar = Calendar.current
        let calendars = [utcCalendar, localCalendar]
        let dayOffsets = [0, -1, 1]
        var seenPaths = Set<String>()
        var directories: [URL] = []

        for calendar in calendars {
            for offset in dayOffsets {
                guard let candidateDate = calendar.date(byAdding: .day, value: offset, to: updatedAt),
                      let directory = sessionDirectory(for: candidateDate, using: calendar) else {
                    continue
                }

                let path = directory.path
                if seenPaths.insert(path).inserted {
                    directories.append(directory)
                }
            }
        }

        return directories
    }

    private func sessionDirectory(for date: Date, using calendar: Calendar) -> URL? {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return nil
        }

        return sessionsRoot
            .appendingPathComponent(String(year))
            .appendingPathComponent(String(format: "%02d", month))
            .appendingPathComponent(String(format: "%02d", day))
    }

    private func findSessionFile(in directory: URL, sessionId: String) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            if fileURL.lastPathComponent.contains(sessionId) {
                return fileURL
            }
        }

        return nil
    }
}

private struct CodexSessionCandidate: Sendable {
    let id: String
    let updatedAt: Date
    let rolloutPath: String?
    let cwd: String?

    nonisolated init(id: String, updatedAt: Date, rolloutPath: String? = nil, cwd: String? = nil) {
        self.id = id
        self.updatedAt = updatedAt
        self.rolloutPath = rolloutPath
        self.cwd = cwd
    }

    nonisolated func merging(_ other: CodexSessionCandidate) -> CodexSessionCandidate {
        CodexSessionCandidate(
            id: id,
            updatedAt: max(updatedAt, other.updatedAt),
            rolloutPath: rolloutPath ?? other.rolloutPath,
            cwd: cwd ?? other.cwd
        )
    }
}

private enum CodexSessionUpdate {
    case event(HookEvent)
    case assistant(String, AssistantMessage)
}
