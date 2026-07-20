import Foundation
import Darwin
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "StateMachine")

@MainActor
@Observable
final class NotchiStateMachine {
    static let shared = NotchiStateMachine()

    let sessionStore = SessionStore.shared

    private var emotionDecayTimer: Task<Void, Never>?
    private var pendingSyncTasks: [ProviderSessionKey: Task<Void, Never>] = [:]
    private var pendingPositionMarks: [ProviderSessionKey: Task<Void, Never>] = [:]
    private var pendingSessionStartTimes: [ProviderSessionKey: Date] = [:]
    private var codexProcessMonitorTask: Task<Void, Never>?
    private var codexThreadMetadataMonitorTask: Task<Void, Never>?
    private var codexThreadMetadataRefreshTask: Task<Void, Never>?
    private var codexCompactionSignalRefreshTask: Task<Void, Never>?
    private var codexCompactionSignalRefreshGeneration = 0
    private var lastCodexCompactionSignalRefreshAt: ContinuousClock.Instant?
    private var codexThreadMetadataImmediateRefreshKeys: Set<ProviderSessionKey> = []
    private var codexThreadMetadataAutoRefreshEnabled = true
    private var codexProcessMissCounts: [ProviderSessionKey: Int] = [:]
    private var fileWatchers: [ProviderSessionKey: (source: DispatchSourceFileSystemObject, fd: Int32)] = [:]
    var handleClaudeUsageResumeTrigger: (ClaudeUsageResumeTrigger) -> Void = { trigger in
        ClaudeUsageService.shared.handleClaudeResumeTrigger(trigger)
    }
    var isCodexProcessAlive: (Int) -> Bool
    var onCodexSessionsEnded: () -> Void = {
        Task { await CodexUsageService.shared.refreshFromAPI() }
    }

    private static let syncDebounce: Duration = .milliseconds(100)
    private static let waitingClearGuard: TimeInterval = 2.0
    private static let codexProcessMonitorInterval: Duration = .seconds(2)
    private static let codexThreadMetadataMonitorInterval: Duration = .seconds(5)
    private nonisolated static let codexCompactionSignalRefreshDebounce: Duration = .milliseconds(150)
    private nonisolated static let codexCompactionSignalMinRefreshInterval: Duration = .seconds(2)
    private static let codexProcessMissLimit = 2
    private static let pendingSessionStartMaxAge: TimeInterval = 10 * 60

    var currentState: NotchiState {
        sessionStore.effectiveSession?.state ?? .idle
    }

    private init() {
        isCodexProcessAlive = Self.defaultCodexProcessAlive
        startEmotionDecayTimer()
    }

    func handleEvent(_ event: HookEvent) {
        trimPendingSessionStartTimes()

        let transcriptPath = ConversationParser.resolvedTranscriptPath(
            for: event.provider,
            sessionId: event.rawSessionId,
            cwd: event.cwd,
            transcriptPath: event.transcriptPath
        )
        let isDone = event.status == "waiting_for_input"

        // WHY: SessionStart fires before there is any user-visible content for a
        // brand new chat. Track it immediately, but don't surface a blank session
        // until later events give us real prompt/reply/tool content.
        if event.event == .sessionStarted,
           sessionStore.session(for: event.sessionKey) == nil {
            pendingSessionStartTimes[event.sessionKey] = Date()

            switch event.provider {
            case .codex:
                refreshCodexSessionStartTracking(
                    sessionKey: event.sessionKey,
                    transcriptPath: transcriptPath,
                    isInteractive: event.interactive ?? true
                )
            default:
                if event.provider.capabilities.supportsUsageResumeTriggers {
                    handleClaudeUsageResumeTrigger(.sessionStart)
                }
            }

            return
        }

        let sessionStartTimeOverride = pendingSessionStartTimeOverride(for: event)
        let session = sessionStore.process(event, sessionStartTimeOverride: sessionStartTimeOverride)
        refreshCodexProcessMonitoring()
        refreshCodexThreadMetadataMonitoring()
        scheduleInitialCodexThreadMetadataRefreshIfNeeded(for: event)

        if event.event != .sessionEnded, session.codexArchived {
            endCodexArchivedSessions([session])
            return
        }

        switch event.event {
        case .userPromptSubmitted:
            if let transcriptPath {
                pendingPositionMarks[event.sessionKey] = Task {
                    await ConversationParser.shared.markCurrentPosition(
                        sessionKey: event.sessionKey,
                        transcriptPath: transcriptPath
                    )
                }
            } else {
                pendingPositionMarks.removeValue(forKey: event.sessionKey)?.cancel()
            }

            if session.isInteractive, let transcriptPath {
                startFileWatcher(sessionKey: event.sessionKey, transcriptPath: transcriptPath)
            }

            if session.isInteractive,
               event.provider.capabilities.supportsPromptEmotionAnalysis,
               let prompt = event.userPrompt {
                Task {
                    guard let result = await EmotionAnalyzer.shared.analyze(prompt) else { return }
                    session.emotionState.recordEmotion(result.emotion, intensity: result.intensity, prompt: prompt)
                }
            }

            if session.isInteractive,
               event.provider.capabilities.supportsUsageResumeTriggers,
               !SessionStore.isLocalSlashCommand(event.userPrompt) {
                handleClaudeUsageResumeTrigger(.userPromptSubmit)
            }

        case .preToolUse:
            if isDone {
                SoundService.shared.playNotificationSound(sessionKey: event.sessionKey, isInteractive: session.isInteractive)
            }

        case .permissionRequest:
            if event.provider.capabilities.supportsPermissionPrompts {
                SoundService.shared.playNotificationSound(sessionKey: event.sessionKey, isInteractive: session.isInteractive)
            }

        case .postToolUse:
            if let transcriptPath {
                scheduleFileSync(sessionKey: event.sessionKey, transcriptPath: transcriptPath)
            }

        case .sessionStarted:
            if event.provider == .codex {
                // WHY: Existing Codex sessions can emit SessionStart on resume,
                // and we still want to refresh the parser baseline/watcher even
                // though the visible session already exists.
                refreshCodexSessionStartTracking(
                    sessionKey: event.sessionKey,
                    transcriptPath: transcriptPath,
                    isInteractive: session.isInteractive
                )
            }

            if event.provider.capabilities.supportsUsageResumeTriggers {
                handleClaudeUsageResumeTrigger(.sessionStart)
            }

        case .stop:
            SoundService.shared.playNotificationSound(sessionKey: event.sessionKey, isInteractive: session.isInteractive)
            stopFileWatcher(sessionKey: event.sessionKey)
            if let transcriptPath {
                scheduleFileSync(sessionKey: event.sessionKey, transcriptPath: transcriptPath)
            }

        case .sessionEnded:
            pendingSessionStartTimes.removeValue(forKey: event.sessionKey)
            codexThreadMetadataImmediateRefreshKeys.remove(event.sessionKey)
            stopFileWatcher(sessionKey: event.sessionKey)
            pendingSyncTasks.removeValue(forKey: event.sessionKey)?.cancel()
            pendingPositionMarks.removeValue(forKey: event.sessionKey)?.cancel()
            SoundService.shared.clearCooldown(for: event.sessionKey)
            Task { await ConversationParser.shared.resetState(for: event.sessionKey) }
            refreshCodexProcessMonitoring()
            refreshCodexThreadMetadataMonitoring()
            return

        default:
            if isDone && session.task != .idle {
                SoundService.shared.playNotificationSound(sessionKey: event.sessionKey, isInteractive: session.isInteractive)
            }
        }

        session.resetSleepTimer()
    }

    private func scheduleFileSync(sessionKey: ProviderSessionKey, transcriptPath: String) {
        pendingSyncTasks[sessionKey]?.cancel()
        pendingSyncTasks[sessionKey] = Task {
            await pendingPositionMarks[sessionKey]?.value

            try? await Task.sleep(for: Self.syncDebounce)
            guard !Task.isCancelled else { return }

            let result = await ConversationParser.shared.parseIncremental(
                sessionKey: sessionKey,
                transcriptPath: transcriptPath
            )

            applyParsedSessionEvents(result.events, for: sessionKey)

            if !result.messages.isEmpty {
                sessionStore.recordAssistantMessages(result.messages, for: sessionKey)
            }

            reconcileFileSyncResult(
                result,
                for: sessionKey,
                hasActiveWatcher: fileWatchers[sessionKey] != nil
            )

            pendingSyncTasks.removeValue(forKey: sessionKey)
        }
    }

    private func refreshCodexSessionStartTracking(
        sessionKey: ProviderSessionKey,
        transcriptPath: String?,
        isInteractive: Bool
    ) {
        guard let transcriptPath else { return }

        pendingPositionMarks[sessionKey] = Task {
            await ConversationParser.shared.markCurrentPosition(
                sessionKey: sessionKey,
                transcriptPath: transcriptPath
            )
        }

        if isInteractive {
            startFileWatcher(sessionKey: sessionKey, transcriptPath: transcriptPath)
        }
    }

    private func pendingSessionStartTimeOverride(for event: HookEvent) -> Date? {
        guard sessionStore.session(for: event.sessionKey) == nil else {
            return nil
        }

        return pendingSessionStartTimes.removeValue(forKey: event.sessionKey)
    }

    private func trimPendingSessionStartTimes(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.pendingSessionStartMaxAge)
        pendingSessionStartTimes = pendingSessionStartTimes.filter { _, startTime in
            startTime >= cutoff
        }
    }

    func applyParsedSessionEvents(_ events: [ParsedSessionEvent], for sessionKey: ProviderSessionKey) {
        guard !events.isEmpty,
              let session = sessionStore.session(for: sessionKey) else { return }

        for event in events {
            _ = sessionStore.process(
                HookEvent(
                    provider: session.provider,
                    rawSessionId: session.rawSessionId,
                    transcriptPath: nil,
                    cwd: session.cwd,
                    event: event.event,
                    status: event.status,
                    tool: event.tool,
                    toolInput: event.toolInput,
                    toolUseId: event.toolUseId,
                    userPrompt: nil,
                    permissionMode: nil,
                    interactive: session.isInteractive
                )
            )
        }
    }

    func reconcileFileSyncResult(_ result: ParseResult, for sessionKey: ProviderSessionKey, hasActiveWatcher: Bool) {
        guard let session = sessionStore.session(for: sessionKey) else { return }

        if !result.messages.isEmpty,
           session.isInteractive,
           hasActiveWatcher,
           session.task == .idle || session.task == .sleeping {
            session.updateTask(.working)
            session.updateProcessingState(isProcessing: true)
        }

        if result.interrupted && session.task == .working {
            session.updateTask(.idle)
            session.updateProcessingState(isProcessing: false)
        } else if session.task == .waiting,
                  session.pendingQuestions.isEmpty,
                  Date().timeIntervalSince(session.lastActivity) > Self.waitingClearGuard {
            session.updateTask(.working)
        }
    }

    private func reconcileCodexProcessLiveness() {
        let trackedSessions = sessionStore.sessions.values.filter { $0.isCodexCLIProcessBacked }
        let trackedKeys = Set(trackedSessions.map(\.sessionKey))
        codexProcessMissCounts = codexProcessMissCounts.filter { trackedKeys.contains($0.key) }

        var endedSessions: [SessionData] = []

        for session in trackedSessions {
            guard let processId = session.codexProcessId else { continue }

            if isCodexProcessAlive(processId) {
                codexProcessMissCounts.removeValue(forKey: session.sessionKey)
                continue
            }

            let missCount = (codexProcessMissCounts[session.sessionKey] ?? 0) + 1
            codexProcessMissCounts[session.sessionKey] = missCount

            if missCount >= Self.codexProcessMissLimit {
                endedSessions.append(session)
            }
        }

        for session in endedSessions {
            codexProcessMissCounts.removeValue(forKey: session.sessionKey)
            handleEvent(
                HookEvent(
                    provider: .codex,
                    rawSessionId: session.rawSessionId,
                    transcriptPath: nil,
                    cwd: session.cwd,
                    event: .sessionEnded,
                    status: "ended",
                    interactive: session.isInteractive,
                    codexProcessId: session.codexProcessId,
                    codexOrigin: session.codexOrigin
                )
            )
        }

        refreshCodexProcessMonitoring()
    }

    private func reconcileCodexThreadMetadata() {
        scheduleCodexThreadMetadataRefresh()
    }

    private func endCodexArchivedSessions(_ sessions: [SessionData]) {
        for session in sessions {
            // WHY: Route archive removal through the normal SessionEnd path so
            // watcher/parser/sound cleanup stays identical to a real end event.
            handleEvent(
                HookEvent(
                    provider: .codex,
                    rawSessionId: session.rawSessionId,
                    transcriptPath: nil,
                    cwd: session.cwd,
                    event: .sessionEnded,
                    status: "ended",
                    interactive: session.isInteractive,
                    codexProcessId: session.codexProcessId,
                    codexOrigin: session.codexOrigin
                )
            )
        }
    }

    private func startFileWatcher(sessionKey: ProviderSessionKey, transcriptPath: String) {
        stopFileWatcher(sessionKey: sessionKey)

        let fd = open(transcriptPath, O_EVTONLY)
        guard fd >= 0 else {
            logger.warning("Could not open file for watching: \(transcriptPath)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.scheduleFileSync(sessionKey: sessionKey, transcriptPath: transcriptPath)
            if sessionKey.provider == .codex {
                self.scheduleCodexCompactionSignalRefresh()
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        fileWatchers[sessionKey] = (source: source, fd: fd)
    }

    private func stopFileWatcher(sessionKey: ProviderSessionKey) {
        guard let watcher = fileWatchers.removeValue(forKey: sessionKey) else { return }
        watcher.source.cancel()
    }

    private func startEmotionDecayTimer() {
        emotionDecayTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: EmotionState.decayInterval)
                guard !Task.isCancelled else { return }
                for session in sessionStore.sessions.values {
                    session.emotionState.decayAll()
                }
            }
        }
    }

    private func refreshCodexProcessMonitoring() {
        let shouldMonitor = sessionStore.sessions.values.contains { $0.isCodexCLIProcessBacked }

        if shouldMonitor {
            guard codexProcessMonitorTask == nil else { return }
            codexProcessMonitorTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.codexProcessMonitorInterval)
                    guard !Task.isCancelled else { return }
                    self?.reconcileCodexProcessLiveness()
                }
            }
        } else {
            codexProcessMonitorTask?.cancel()
            codexProcessMonitorTask = nil
            codexProcessMissCounts.removeAll()
        }
    }

    private func refreshCodexThreadMetadataMonitoring() {
        let shouldMonitor = sessionStore.sessions.values.contains { $0.isCodexThreadBacked }

        if shouldMonitor {
            guard codexThreadMetadataMonitorTask == nil else { return }
            codexThreadMetadataMonitorTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.codexThreadMetadataMonitorInterval)
                    guard !Task.isCancelled else { return }
                    self?.reconcileCodexThreadMetadata()
                }
            }
        } else {
            codexThreadMetadataMonitorTask?.cancel()
            codexThreadMetadataMonitorTask = nil
            codexThreadMetadataRefreshTask?.cancel()
            codexThreadMetadataRefreshTask = nil
            cancelCodexCompactionSignalRefresh()
            codexThreadMetadataImmediateRefreshKeys.removeAll()
            onCodexSessionsEnded()
        }
    }

    private func scheduleInitialCodexThreadMetadataRefreshIfNeeded(for event: HookEvent) {
        guard codexThreadMetadataAutoRefreshEnabled,
              event.provider == .codex,
              event.transcriptPath != nil,
              !codexThreadMetadataImmediateRefreshKeys.contains(event.sessionKey) else {
            return
        }

        codexThreadMetadataImmediateRefreshKeys.insert(event.sessionKey)
        scheduleCodexThreadMetadataRefresh()
    }

    private func scheduleCodexThreadMetadataRefresh() {
        guard codexThreadMetadataRefreshTask == nil else { return }

        let requests = sessionStore.codexThreadMetadataRequests()
        guard !requests.isEmpty else {
            refreshCodexThreadMetadataMonitoring()
            return
        }

        let transcriptPaths = requests.map(\.transcriptPath)
        codexThreadMetadataRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.codexThreadMetadataRefreshTask = nil }

            let compactionRequests = self.sessionStore.codexCompactionSignalRequests()
            if !compactionRequests.isEmpty {
                self.lastCodexCompactionSignalRefreshAt = .now
            }
            async let metadataUpdates = self.sessionStore.resolveCodexThreadMetadata(requests)
            async let compactionUpdates = self.sessionStore.resolveCodexCompactionSignals(compactionRequests)
            async let usageRefresh: Void = CodexUsageService.shared.refresh(transcriptPaths: transcriptPaths)
            let updates = await metadataUpdates
            let signals = await compactionUpdates
            _ = await usageRefresh
            guard !Task.isCancelled else { return }

            let archivedSessions = self.sessionStore.applyCodexThreadMetadata(updates)
            self.sessionStore.applyCodexCompactionSignals(signals)
            self.endCodexArchivedSessions(archivedSessions)
            self.refreshCodexThreadMetadataMonitoring()
        }
    }

    private func scheduleCodexCompactionSignalRefresh() {
        guard codexThreadMetadataAutoRefreshEnabled else { return }
        requestCodexCompactionSignalRefresh()
    }

    // WHY: Transcript writes arrive in sub-second bursts while Codex streams.
    // Each compaction refresh spawns a sqlite3 process, so pending refreshes
    // absorb later writes and refreshes are spaced out by a minimum interval
    // instead of re-arming the debounce on every write.
    private func requestCodexCompactionSignalRefresh() {
        guard codexCompactionSignalRefreshTask == nil else { return }
        let sinceLastRefresh = lastCodexCompactionSignalRefreshAt.map { ContinuousClock.now - $0 }
        scheduleCodexCompactionSignalRefresh(after: Self.codexCompactionRefreshDelay(sinceLastRefresh: sinceLastRefresh))
    }

    nonisolated static func codexCompactionRefreshDelay(sinceLastRefresh: Duration?) -> Duration {
        guard let sinceLastRefresh, sinceLastRefresh < codexCompactionSignalMinRefreshInterval else {
            return codexCompactionSignalRefreshDebounce
        }
        return max(codexCompactionSignalRefreshDebounce, codexCompactionSignalMinRefreshInterval - sinceLastRefresh)
    }

    private func scheduleCodexCompactionSignalRefresh(after delay: Duration) {
        codexCompactionSignalRefreshGeneration += 1
        let generation = codexCompactionSignalRefreshGeneration
        codexCompactionSignalRefreshTask?.cancel()
        codexCompactionSignalRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            await self.refreshCodexCompactionSignals(generation: generation)
        }
    }

    private func refreshCodexCompactionSignals(generation: Int) async {
        let requests = sessionStore.codexCompactionSignalRequests()
        guard !requests.isEmpty else {
            clearCodexCompactionSignalRefreshTask(generation: generation)
            refreshCodexThreadMetadataMonitoring()
            return
        }

        lastCodexCompactionSignalRefreshAt = .now
        let signals = await sessionStore.resolveCodexCompactionSignals(requests)
        guard !Task.isCancelled else {
            clearCodexCompactionSignalRefreshTask(generation: generation)
            return
        }

        sessionStore.applyCodexCompactionSignals(signals)
        clearCodexCompactionSignalRefreshTask(generation: generation)
        refreshCodexThreadMetadataMonitoring()
    }

    private func clearCodexCompactionSignalRefreshTask(generation: Int) {
        guard generation == codexCompactionSignalRefreshGeneration else {
            return
        }

        codexCompactionSignalRefreshTask = nil
    }

    private func cancelCodexCompactionSignalRefresh() {
        codexCompactionSignalRefreshGeneration += 1
        codexCompactionSignalRefreshTask?.cancel()
        codexCompactionSignalRefreshTask = nil
    }

    private nonisolated static func defaultCodexProcessAlive(_ processId: Int) -> Bool {
        guard processId > 0, processId <= Int(Int32.max) else { return false }

        errno = 0
        let result = kill(pid_t(processId), 0)
        return result == 0 || errno == EPERM
    }

    func resetTestingHooks() {
        handleClaudeUsageResumeTrigger = { trigger in
            ClaudeUsageService.shared.handleClaudeResumeTrigger(trigger)
        }
        isCodexProcessAlive = Self.defaultCodexProcessAlive
        onCodexSessionsEnded = {
            Task { await CodexUsageService.shared.refreshFromAPI() }
        }
        codexProcessMonitorTask?.cancel()
        codexProcessMonitorTask = nil
        codexThreadMetadataMonitorTask?.cancel()
        codexThreadMetadataMonitorTask = nil
        codexThreadMetadataRefreshTask?.cancel()
        codexThreadMetadataRefreshTask = nil
        cancelCodexCompactionSignalRefresh()
        lastCodexCompactionSignalRefreshAt = nil
        codexThreadMetadataImmediateRefreshKeys.removeAll()
        codexThreadMetadataAutoRefreshEnabled = true
        codexProcessMissCounts.removeAll()
        pendingSessionStartTimes.removeAll()
    }

#if DEBUG
    func reconcileCodexProcessLivenessForTesting() {
        reconcileCodexProcessLiveness()
    }

    func reconcileCodexThreadMetadataForTesting() {
        let archivedSessions = sessionStore.refreshCodexThreadMetadataForTesting()
        sessionStore.refreshCodexCompactionSignalsForTesting()
        endCodexArchivedSessions(archivedSessions)
        refreshCodexThreadMetadataMonitoring()
    }

    func setCodexThreadMetadataAutoRefreshEnabledForTesting(_ enabled: Bool) {
        codexThreadMetadataAutoRefreshEnabled = enabled
    }

    func requestCodexCompactionSignalRefreshForTesting() {
        requestCodexCompactionSignalRefresh()
    }

    func setPendingSessionStartTimeForTesting(_ startTime: Date, sessionKey: ProviderSessionKey) {
        pendingSessionStartTimes[sessionKey] = startTime
    }

    func pendingSessionStartTimeForTesting(sessionKey: ProviderSessionKey) -> Date? {
        pendingSessionStartTimes[sessionKey]
    }
#endif

}
