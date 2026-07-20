import Foundation
import os

extension Notification.Name {
    static let sessionStoreActiveSessionCountDidChange = Notification.Name("sessionStoreActiveSessionCountDidChange")
}

@MainActor
@Observable
final class SessionStore {
    static let shared = SessionStore()

    private(set) var sessions: [ProviderSessionKey: SessionData] = [:]
    private(set) var selectedSessionKey: ProviderSessionKey?
    private(set) var selectedAt: Date?
    private var displaySessionNumbersById: [String: Int] = [:]
    private var resolveCodexMetadata: @Sendable ([String]) -> [String: CodexThreadMetadata] = { transcriptPaths in
        CodexThreadMetadataResolver.metadata(forTranscriptPaths: transcriptPaths)
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

    func latestSession(for provider: AgentProvider) -> SessionData? {
        sortedSessions.first { $0.provider == provider }
    }

    func latestSession(excluding provider: AgentProvider?) -> SessionData? {
        if let pinned = pinnedSelectedSession, pinned.provider != provider {
            return pinned
        }
        return sortedSessions.first { $0.provider != provider }
    }

    private var pinnedSelectedSession: SessionData? {
        guard let selected = selectedSession else { return nil }
        let otherActivities = sessions.values
            .filter { $0.sessionKey != selected.sessionKey }
            .map(\.lastActivity)
        return Self.pinnedSession(
            selected: selected,
            selectedAt: selectedAt,
            otherSessionActivities: otherActivities
        )
    }

    static func pinnedSession(
        selected: SessionData?,
        selectedAt: Date?,
        otherSessionActivities: [Date]
    ) -> SessionData? {
        guard let selected, let selectedAt else { return nil }
        let overridden = otherSessionActivities.contains { $0 > selectedAt }
        return overridden ? nil : selected
    }

    func selectSession(_ sessionKey: ProviderSessionKey) {
        guard sessions[sessionKey] != nil else { return }
        selectedSessionKey = sessionKey
        selectedAt = Date()
    }

    @discardableResult
    func selectSession(matchingStableId stableId: String) -> SessionData? {
        guard let sessionKey = ProviderSessionKey(stableId: stableId) else { return nil }
        selectSession(sessionKey)
        return sessions[sessionKey]
    }

    func clearSelectedSession() {
        selectedSessionKey = nil
        selectedAt = nil
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
                session.setPendingQuestions(
                    Self.parseQuestions(from: event.toolInput),
                    responseContext: Self.buildQuestionResponseContext(for: event, kind: .askUserQuestion)
                )
            } else {
                session.clearPendingQuestions()
                session.updateTask(.working)
            }

        case .permissionRequest:
            session.updateTask(.waiting)
            if event.tool == "AskUserQuestion" {
                session.setPendingQuestions(
                    Self.parseQuestions(from: event.toolInput),
                    responseContext: Self.buildQuestionResponseContext(for: event, kind: .askUserQuestion)
                )
            } else {
                let question = Self.buildPermissionQuestion(
                    provider: event.provider,
                    tool: event.tool,
                    toolInput: event.toolInput,
                    permissionSuggestions: event.permissionSuggestions
                )
                session.setPendingQuestions(
                    [question],
                    responseContext: Self.buildQuestionResponseContext(for: event, kind: .permissionRequest)
                )
            }

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
            selectedAt = Date()
        } else {
            selectedSessionKey = nil
            selectedAt = nil
        }

        return session
    }

    private func removeSession(_ sessionKey: ProviderSessionKey) {
        sessions.removeValue(forKey: sessionKey)
        recomputeDisplaySessionNumbers()
        postActiveSessionCountChange()

        if selectedSessionKey == sessionKey {
            selectedSessionKey = nil
            selectedAt = nil
        }

        if selectedSessionKey == nil, activeSessionCount == 1 {
            selectedSessionKey = sessions.keys.first
            selectedAt = Date()
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
            Self.makeCodexThreadMetadataUpdates(requests: requests, resolver: resolver)
        }.value
    }

    private nonisolated static func makeCodexThreadMetadataUpdates(
        requests: [CodexThreadMetadataRequest],
        resolver: @Sendable ([String]) -> [String: CodexThreadMetadata]
    ) -> [CodexThreadMetadataUpdate] {
        let metadataByPath = resolver(requests.map(\.transcriptPath))
        return requests.map { request in
            CodexThreadMetadataUpdate(
                sessionKey: request.sessionKey,
                transcriptPath: request.transcriptPath,
                metadata: metadataByPath[request.transcriptPath]
            )
        }
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

    @discardableResult
    func answerPendingQuestions(
        in sessionKey: ProviderSessionKey,
        selectedOptionIndexesByQuestion: [Int: Int],
        customAnswersByQuestion: [Int: String] = [:]
    ) -> Bool {
        guard let session = sessions[sessionKey],
              let context = session.pendingQuestionResponseContext,
              !session.pendingQuestions.isEmpty else {
            return false
        }

        if context.kind == .permissionRequest {
            return answerPermissionRequest(
                session: session,
                context: context,
                selectedOptionIndexesByQuestion: selectedOptionIndexesByQuestion
            )
        }

        var answers: [String: String] = [:]
        for questionIndex in session.pendingQuestions.indices {
            if let customAnswer = customAnswersByQuestion[questionIndex]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !customAnswer.isEmpty {
                let question = session.pendingQuestions[questionIndex]
                answers[question.question] = customAnswer
                continue
            }

            guard let optionIndex = selectedOptionIndexesByQuestion[questionIndex] else {
                return false
            }

            let question = session.pendingQuestions[questionIndex]
            guard question.options.indices.contains(optionIndex) else { return false }

            let option = question.options[optionIndex]
            guard !PendingQuestion.isFreeTextOptionLabel(option.label) else {
                return false
            }

            answers[question.question] = option.label
        }

        guard let responseData = HookInteractionResponse.makeAskUserQuestionResponse(
            hookEventName: context.hookEventName,
            toolInput: context.toolInput,
            answers: answers
        ) else {
            return false
        }

        guard HookInteractionResponseBroker.shared.submitResponse(
            responseData,
            for: context.requestId
        ) else {
            session.clearPendingQuestions()
            session.updateTask(.idle)
            return false
        }

        session.clearPendingQuestions()
        session.updateTask(.working)
        return true
    }

    private func answerPermissionRequest(
        session: SessionData,
        context: PendingQuestionResponseContext,
        selectedOptionIndexesByQuestion: [Int: Int]
    ) -> Bool {
        guard selectedOptionIndexesByQuestion.count == 1,
              let optionIndex = selectedOptionIndexesByQuestion[0],
              let question = session.pendingQuestions.first,
              question.options.indices.contains(optionIndex),
              let decision = PermissionRequestDecision(optionLabel: question.options[optionIndex].label),
              let responseData = HookInteractionResponse.makePermissionRequestResponse(
                decision: decision,
                hookEventName: context.hookEventName,
                toolInput: context.toolInput,
                permissionSuggestions: context.permissionSuggestions
              ) else {
            return false
        }

        guard HookInteractionResponseBroker.shared.submitResponse(
            responseData,
            for: context.requestId
        ) else {
            session.clearPendingQuestions()
            session.updateTask(.idle)
            return false
        }

        session.clearPendingQuestions()
        session.updateTask(.working)
        return true
    }

    @discardableResult
    func cancelPendingQuestion(in sessionKey: ProviderSessionKey) -> Bool {
        guard let session = sessions[sessionKey],
              !session.pendingQuestions.isEmpty else {
            return false
        }

        // .working only when the broker actually relays the deny back to the hook;
        // otherwise Claude isn't waiting on us, so drop to .idle.
        let denySubmitted: Bool
        if let context = session.pendingQuestionResponseContext,
           let responseData = Self.cancellationResponse(for: context) {
            denySubmitted = HookInteractionResponseBroker.shared.submitResponse(
                responseData,
                for: context.requestId
            )
        } else {
            denySubmitted = false
        }

        session.clearPendingQuestions()
        session.updateTask(denySubmitted ? .working : .idle)
        return true
    }

    private static func cancellationResponse(for context: PendingQuestionResponseContext) -> Data? {
        switch context.kind {
        case .askUserQuestion:
            HookInteractionResponse.makeAskUserQuestionCancellationResponse(
                hookEventName: context.hookEventName
            )
        case .permissionRequest:
            HookInteractionResponse.makePermissionRequestResponse(
                decision: .deny,
                hookEventName: context.hookEventName,
                toolInput: context.toolInput,
                permissionSuggestions: context.permissionSuggestions
            )
        }
    }

#if DEBUG
    func refreshCodexThreadMetadataForTesting() -> [SessionData] {
        let updates = Self.makeCodexThreadMetadataUpdates(
            requests: codexThreadMetadataRequests(),
            resolver: resolveCodexMetadata
        )
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
        resolveCodexMetadata = { transcriptPaths in
            var metadataByPath: [String: CodexThreadMetadata] = [:]
            for transcriptPath in transcriptPaths {
                metadataByPath[transcriptPath] = resolver(transcriptPath)
            }
            return metadataByPath
        }
    }

    func setCodexMetadataBatchResolverForTesting(
        _ resolver: @escaping @Sendable ([String]) -> [String: CodexThreadMetadata]
    ) {
        resolveCodexMetadata = resolver
    }

    func setCodexCompactionSignalResolverForTesting(_ resolver: @escaping @Sendable ([String]) -> [String: CodexCompactionSignal]) {
        resolveCodexCompactionSignals = resolver
    }

    func resetTestingHooks() {
        resolveCodexMetadata = { transcriptPaths in
            CodexThreadMetadataResolver.metadata(forTranscriptPaths: transcriptPaths)
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
            return PendingQuestion(
                question: questionText,
                header: header,
                options: Self.optionsWithFreeTextChoice(options)
            )
        }
    }

    private static func optionsWithFreeTextChoice(
        _ options: [(label: String, description: String?)]
    ) -> [(label: String, description: String?)] {
        let alreadyIncludesFreeText = options.contains { option in
            PendingQuestion.isFreeTextOptionLabel(option.label)
        }

        guard !alreadyIncludesFreeText else { return options }
        return options + [(label: PendingQuestion.freeTextOptionLabel, description: nil)]
    }

    private static func buildQuestionResponseContext(
        for event: HookEvent,
        kind: PendingQuestionResponseContext.Kind
    ) -> PendingQuestionResponseContext? {
        guard event.provider == .claude,
              let requestId = event.interactionRequestId else {
            return nil
        }

        return PendingQuestionResponseContext(
            requestId: requestId,
            hookEventName: event.event.rawValue,
            toolInput: event.toolInput,
            permissionSuggestions: event.permissionSuggestions,
            kind: kind
        )
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

    private static func buildPermissionQuestion(
        provider: AgentProvider,
        tool: String?,
        toolInput: [String: AnyCodable]?,
        permissionSuggestions: [AnyCodable]?
    ) -> PendingQuestion {
        let toolName = tool ?? "Tool"
        let input = toolInput?.mapValues { $0.value }
        let description = Self.permissionQuestionText(provider: provider, tool: tool, toolInput: input)
        var options: [(label: String, description: String?)] = [
            (label: PermissionRequestDecision.allowOnceLabel, description: nil),
        ]
        if HookInteractionResponse.hasRememberablePermissionSuggestion(permissionSuggestions) {
            options.append((label: PermissionRequestDecision.allowAndRememberLabel, description: nil))
        }
        options.append((label: PermissionRequestDecision.denyLabel, description: nil))

        return PendingQuestion(
            question: description ?? "\(toolName) wants to proceed",
            header: "Permission Request",
            options: options
        )
    }

    private static func permissionQuestionText(
        provider: AgentProvider,
        tool: String?,
        toolInput: [String: Any]?
    ) -> String? {
        if provider == .codex,
           let justification = toolInput?["justification"] as? String,
           !justification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return justification
        }

        return SessionEvent.deriveDescription(tool: tool, toolInput: toolInput)
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

nonisolated final class CodexSQLiteURLCache: Sendable {
    private struct Entry {
        let url: URL
        let cachedAt: Date
    }

    static let shared = CodexSQLiteURLCache(
        ttl: 60,
        list: { CodexFileSystem.scanLatestSQLiteURL(prefix: $0) },
        fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        now: { Date() }
    )

    private let ttl: TimeInterval
    private let list: @Sendable (String) -> URL?
    private let fileExists: @Sendable (URL) -> Bool
    private let now: @Sendable () -> Date
    private let entries = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

    init(
        ttl: TimeInterval,
        list: @escaping @Sendable (String) -> URL?,
        fileExists: @escaping @Sendable (URL) -> Bool,
        now: @escaping @Sendable () -> Date
    ) {
        self.ttl = ttl
        self.list = list
        self.fileExists = fileExists
        self.now = now
    }

    func url(prefix: String) -> URL? {
        let currentTime = now()
        if let entry = entries.withLock({ $0[prefix] }),
           currentTime.timeIntervalSince(entry.cachedAt) < ttl,
           fileExists(entry.url) {
            return entry.url
        }

        let resolved = list(prefix)
        entries.withLock { state in
            state[prefix] = resolved.map { Entry(url: $0, cachedAt: currentTime) }
        }
        return resolved
    }
}

nonisolated enum CodexFileSystem {
    static let sqliteSeparator = "\u{1F}"

    private static var codexDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    static func latestSQLiteURL(prefix: String) -> URL? {
        CodexSQLiteURLCache.shared.url(prefix: prefix)
    }

    static func scanLatestSQLiteURL(prefix: String) -> URL? {
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

nonisolated enum HookInteractionRequest {
    static let responseWaitTimeout: TimeInterval = 300

    // PermissionRequest events lack a tool_use_id, so this method may generate
    // a fresh fallback id. Store the result on HookEvent instead of
    // recomputing it later.
    static func id(for envelope: AgentHookEnvelope) -> String? {
        guard envelope.provider == .claude,
              let event = NormalizedAgentEvent.claudeEvent(named: envelope.event) else {
            return nil
        }

        let toolUseId: String
        switch event {
        case .permissionRequest:
            toolUseId = envelope.toolUseId ?? UUID().uuidString
        default:
            return nil
        }

        return id(
            provider: envelope.provider,
            rawSessionId: envelope.sessionId,
            hookEventName: envelope.event,
            toolUseId: toolUseId
        )
    }

    static func id(
        provider: AgentProvider,
        rawSessionId: String,
        hookEventName: String,
        toolUseId: String
    ) -> String {
        [
            provider.rawValue,
            rawSessionId,
            hookEventName,
            toolUseId,
        ].joined(separator: ":")
    }
}

nonisolated final class HookInteractionResponseBroker: @unchecked Sendable {
    static let shared = HookInteractionResponseBroker()

    private let condition = NSCondition()
    private var pendingRequestIds: Set<String> = []
    private var responsesByRequestId: [String: Data] = [:]

    func waitForResponse(requestId: String, timeout: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)

        condition.lock()
        pendingRequestIds.insert(requestId)
        defer {
            pendingRequestIds.remove(requestId)
            responsesByRequestId.removeValue(forKey: requestId)
            condition.unlock()
        }

        while responsesByRequestId[requestId] == nil, Date() < deadline {
            condition.wait(until: deadline)
        }

        return responsesByRequestId[requestId]
    }

    @discardableResult
    func submitResponse(_ response: Data, for requestId: String) -> Bool {
        condition.lock()
        defer { condition.unlock() }

        guard pendingRequestIds.contains(requestId) else { return false }
        responsesByRequestId[requestId] = response
        condition.broadcast()
        return true
    }

#if DEBUG
    func isWaitingForResponse(requestId: String) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return pendingRequestIds.contains(requestId)
    }
#endif
}

nonisolated enum PermissionRequestDecision {
    static let allowOnceLabel = "Yes"
    static let allowAndRememberLabel = "Yes, and don't ask again"
    static let denyLabel = "No"

    case allowOnce
    case allowAndRemember
    case deny

    init?(optionLabel: String) {
        switch optionLabel {
        case Self.allowOnceLabel:
            self = .allowOnce
        case Self.allowAndRememberLabel:
            self = .allowAndRemember
        case Self.denyLabel:
            self = .deny
        default:
            return nil
        }
    }
}

nonisolated enum HookInteractionResponse {
    private static let userCanceledQuestionReason = "Question canceled by user."

    static func makeAskUserQuestionResponse(
        hookEventName: String,
        toolInput: [String: AnyCodable]?,
        answers: [String: String]
    ) -> Data? {
        var updatedInput = recursivelyUnwrapped(toolInput) as? [String: Any] ?? [:]
        var updatedAnswers = updatedInput["answers"] as? [String: Any] ?? [:]
        for (question, answer) in answers {
            updatedAnswers[question] = answer
        }
        updatedInput["answers"] = updatedAnswers

        let output: [String: Any]
        if hookEventName == NormalizedAgentEvent.permissionRequest.rawValue {
            // Claude versions observed in the wild can surface AskUserQuestion
            // through PermissionRequest; keep the matching response shape.
            output = [
                "hookSpecificOutput": [
                    "hookEventName": hookEventName,
                    "decision": [
                        "behavior": "allow",
                        "updatedInput": updatedInput,
                    ],
                ],
            ]
        } else {
            output = [
                "hookSpecificOutput": [
                    "hookEventName": hookEventName,
                    "permissionDecision": "allow",
                    "updatedInput": updatedInput,
                ],
            ]
        }

        return try? JSONSerialization.data(withJSONObject: output)
    }

    static func makeAskUserQuestionCancellationResponse(hookEventName: String) -> Data? {
        let output: [String: Any]
        if hookEventName == NormalizedAgentEvent.permissionRequest.rawValue {
            // PermissionRequest has a distinct deny shape from PreToolUse.
            output = [
                "hookSpecificOutput": [
                    "hookEventName": hookEventName,
                    "decision": [
                        "behavior": "deny",
                        "message": userCanceledQuestionReason,
                        "interrupt": false,
                    ],
                ],
            ]
        } else {
            output = [
                "hookSpecificOutput": [
                    "hookEventName": hookEventName,
                    "permissionDecision": "deny",
                    "permissionDecisionReason": userCanceledQuestionReason,
                ],
            ]
        }

        return try? JSONSerialization.data(withJSONObject: output)
    }

    static func makePermissionRequestResponse(
        decision: PermissionRequestDecision,
        hookEventName: String,
        toolInput: [String: AnyCodable]?,
        permissionSuggestions: [AnyCodable]?
    ) -> Data? {
        let hookDecision: [String: Any]
        switch decision {
        case .allowOnce:
            hookDecision = [
                "behavior": "allow",
                "updatedInput": recursivelyUnwrapped(toolInput) as? [String: Any] ?? [:],
            ]
        case .allowAndRemember:
            guard let permissionUpdate = preferredPermissionUpdate(from: permissionSuggestions) else {
                return nil
            }
            hookDecision = [
                "behavior": "allow",
                "updatedInput": recursivelyUnwrapped(toolInput) as? [String: Any] ?? [:],
                "updatedPermissions": [permissionUpdate],
            ]
        case .deny:
            hookDecision = [
                "behavior": "deny",
                "message": "User denied this action.",
                "interrupt": false,
            ]
        }

        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": hookEventName,
                "decision": hookDecision,
            ],
        ]

        return try? JSONSerialization.data(withJSONObject: output)
    }

    static func hasRememberablePermissionSuggestion(_ suggestions: [AnyCodable]?) -> Bool {
        preferredPermissionUpdate(from: suggestions) != nil
    }

    private static func preferredPermissionUpdate(from suggestions: [AnyCodable]?) -> [String: Any]? {
        guard let suggestions = recursivelyUnwrapped(suggestions) as? [[String: Any]] else { return nil }

        return suggestions.first { suggestion in
            suggestion["behavior"] as? String == "allow"
                && suggestion["destination"] as? String == "localSettings"
        } ?? suggestions.first { suggestion in
            suggestion["behavior"] as? String == "allow"
        }
    }

    private static func recursivelyUnwrapped(_ value: Any?) -> Any {
        switch value {
        case nil:
            return NSNull()
        case let value as AnyCodable:
            return recursivelyUnwrapped(value.value)
        case let dict as [String: AnyCodable]:
            return dict.mapValues { recursivelyUnwrapped($0) }
        case let dict as [String: Any]:
            return dict.mapValues { recursivelyUnwrapped($0) }
        case let array as [AnyCodable]:
            return array.map { recursivelyUnwrapped($0) }
        case let array as [Any]:
            return array.map { recursivelyUnwrapped($0) }
        default:
            return value ?? NSNull()
        }
    }
}

nonisolated enum CodexThreadMetadataResolver {
    private static var stateURL: URL? {
        CodexFileSystem.latestSQLiteURL(prefix: "state_")
    }

    // WHY: One sqlite3 spawn resolves every tracked session; the monitor loop
    // calls this on a 5s cadence, so per-session spawns multiply quickly.
    static func metadata(forTranscriptPaths transcriptPaths: [String]) -> [String: CodexThreadMetadata] {
        let requestedPaths = transcriptPaths.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !requestedPaths.isEmpty,
              let stateURL,
              FileManager.default.fileExists(atPath: stateURL.path) else {
            return [:]
        }

        let query = threadsQuery(matchingTranscriptPaths: requestedPaths)
        guard let output = CodexFileSystem.runSQLite(query: query, databasePath: stateURL.path) else {
            return [:]
        }

        return metadata(fromSQLiteOutput: output, matchingTranscriptPaths: requestedPaths)
    }

    static func metadata(
        fromSQLiteOutput output: String,
        matchingTranscriptPaths transcriptPaths: [String]
    ) -> [String: CodexThreadMetadata] {
        var metadataByPath: [String: CodexThreadMetadata] = [:]
        for transcriptPath in transcriptPaths {
            let trimmedPath = transcriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty else { continue }
            metadataByPath[transcriptPath] = metadata(
                fromSQLiteOutput: output,
                matchingTranscriptPath: trimmedPath
            )
        }
        return metadataByPath
    }

    // WHY: Dumping every thread row makes the periodic monitor loop re-parse the
    // whole table; filtering in SQLite keeps the output to the tracked sessions'
    // row(s) while still resolving every session in one sqlite invocation.
    static func threadsQuery(matchingTranscriptPaths transcriptPaths: [String]) -> String {
        let trimmedPaths = transcriptPaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let rolloutLiterals = trimmedPaths.map { "'\(sqlEscaped($0))'" }
        let threadIdLiterals = trimmedPaths.compactMap(codexThreadId).map { "'\(sqlEscaped($0))'" }

        var conditions = ["rollout_path IN (\(rolloutLiterals.joined(separator: ", ")))"]
        if !threadIdLiterals.isEmpty {
            conditions.append("id IN (\(threadIdLiterals.joined(separator: ", ")))")
        }

        return "SELECT id, rollout_path, hex(title), archived FROM threads " +
            "WHERE \(conditions.joined(separator: " OR "));"
    }

    private static func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
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
