import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "StateMachine")

@MainActor
@Observable
final class NotchiStateMachine {
    static let shared = NotchiStateMachine()

    let sessionStore = SessionStore.shared

    private var emotionDecayTimer: Task<Void, Never>?
    private var pendingSyncTasks: [String: Task<Void, Never>] = [:]
    private var pendingPositionMarks: [String: Task<Void, Never>] = [:]
    private var fileWatchers: [String: (source: DispatchSourceFileSystemObject, fd: Int32)] = [:]

    private static let syncDebounce: Duration = .milliseconds(100)
    private static let waitingClearGuard: TimeInterval = 2.0

    var currentState: NotchiState {
        sessionStore.effectiveSession?.state ?? .idle
    }

    private init() {
        startEmotionDecayTimer()
    }

    func handleEvent(_ event: HookEvent) {
        let session = sessionStore.process(event)
        let isDone = event.status == "waiting_for_input"
        let usesClaudeConversationFiles = event.provider == .claude

        switch event.event {
        case "UserPromptSubmit":
            if usesClaudeConversationFiles {
                pendingPositionMarks[event.sessionId] = Task {
                    await ConversationParser.shared.markCurrentPosition(
                        sessionId: event.sessionId,
                        cwd: event.cwd
                    )
                }
            }
            if usesClaudeConversationFiles, session.isInteractive {
                startFileWatcher(sessionId: event.sessionId, cwd: event.cwd)
            }

            if session.isInteractive, let prompt = event.userPrompt {
                Task {
                    let result = await EmotionAnalyzer.shared.analyze(prompt, provider: event.provider)
                    session.emotionState.recordEmotion(result.emotion, intensity: result.intensity, prompt: prompt)
                }
            }

        case "PreToolUse":
            if isDone {
                SoundService.shared.playNotificationSound(sessionId: event.sessionId, isInteractive: session.isInteractive)
            }

        case "PermissionRequest":
            SoundService.shared.playNotificationSound(sessionId: event.sessionId, isInteractive: session.isInteractive)

        case "PostToolUse":
            if usesClaudeConversationFiles {
                scheduleFileSync(sessionId: event.sessionId, cwd: event.cwd)
            }

        case "Stop":
            SoundService.shared.playNotificationSound(sessionId: event.sessionId, isInteractive: session.isInteractive)
            if usesClaudeConversationFiles {
                stopFileWatcher(sessionId: event.sessionId)
                scheduleFileSync(sessionId: event.sessionId, cwd: event.cwd)
            }

        case "SessionEnd":
            if usesClaudeConversationFiles {
                stopFileWatcher(sessionId: event.sessionId)
                Task { await ConversationParser.shared.resetState(for: event.sessionId) }
            }
            pendingSyncTasks.removeValue(forKey: event.sessionId)?.cancel()
            pendingPositionMarks.removeValue(forKey: event.sessionId)?.cancel()
            SoundService.shared.clearCooldown(for: event.sessionId)
            if sessionStore.activeSessionCount == 0 {
                logger.info("Global state: idle")
            }
            return

        default:
            if isDone && session.task != .idle {
                SoundService.shared.playNotificationSound(sessionId: event.sessionId, isInteractive: session.isInteractive)
            }
        }

        session.resetSleepTimer()
    }

    private func scheduleFileSync(sessionId: String, cwd: String) {
        pendingSyncTasks[sessionId]?.cancel()
        pendingSyncTasks[sessionId] = Task {
            // Wait for position marking to complete first
            await pendingPositionMarks[sessionId]?.value

            try? await Task.sleep(for: Self.syncDebounce)
            guard !Task.isCancelled else { return }

            let result = await ConversationParser.shared.parseIncremental(
                sessionId: sessionId,
                cwd: cwd
            )

            if !result.messages.isEmpty {
                sessionStore.recordAssistantMessages(result.messages, for: sessionId)
            }

            reconcileFileSyncResult(
                result,
                for: sessionId,
                hasActiveWatcher: fileWatchers[sessionId] != nil
            )

            pendingSyncTasks.removeValue(forKey: sessionId)
        }
    }

    func reconcileFileSyncResult(_ result: ParseResult, for sessionId: String, hasActiveWatcher: Bool) {
        guard let session = sessionStore.sessions[sessionId] else { return }

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
                  Date().timeIntervalSince(session.lastActivity) > Self.waitingClearGuard {
            session.clearPendingQuestions()
            session.updateTask(.working)
        }
    }

    private func startFileWatcher(sessionId: String, cwd: String) {
        stopFileWatcher(sessionId: sessionId)

        let sessionFile = ConversationParser.sessionFilePath(sessionId: sessionId, cwd: cwd)

        let fd = open(sessionFile, O_EVTONLY)
        guard fd >= 0 else {
            logger.warning("Could not open file for watching: \(sessionFile)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.scheduleFileSync(sessionId: sessionId, cwd: cwd)
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        fileWatchers[sessionId] = (source: source, fd: fd)
        logger.debug("Started file watcher for session \(sessionId)")
    }

    private func stopFileWatcher(sessionId: String) {
        guard let watcher = fileWatchers.removeValue(forKey: sessionId) else { return }
        watcher.source.cancel()
        logger.debug("Stopped file watcher for session \(sessionId)")
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

}
