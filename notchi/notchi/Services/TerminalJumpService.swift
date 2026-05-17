import AppKit
import Darwin

@MainActor
struct TerminalJumpService {
    struct ProcessSnapshot {
        let parentProcessId: pid_t
    }

    static let shared = TerminalJumpService()

    private let openURL: (URL) -> Bool
    private let processSnapshot: @MainActor (pid_t) -> ProcessSnapshot?
    private let bundleIdentifierForProcess: @MainActor (pid_t) -> String?
    private let activateProcess: @MainActor (pid_t) -> Bool

    init(
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        processSnapshot: @escaping @MainActor (pid_t) -> ProcessSnapshot? = Self.defaultProcessSnapshot,
        bundleIdentifierForProcess: @escaping @MainActor (pid_t) -> String? = Self.defaultBundleIdentifier,
        activateProcess: @escaping @MainActor (pid_t) -> Bool = Self.defaultActivateProcess
    ) {
        self.openURL = openURL
        self.processSnapshot = processSnapshot
        self.bundleIdentifierForProcess = bundleIdentifierForProcess
        self.activateProcess = activateProcess
    }

    @discardableResult
    func jump(to session: SessionData) -> Bool {
        if let url = Self.codexDesktopThreadURL(for: session) {
            return openURL(url)
        }

        if let processId = Self.terminalBackedProcessId(for: session),
           let terminalProcessId = terminalProcessID(hosting: processId) {
            return activateProcess(terminalProcessId)
        }

        return false
    }

    static func codexDesktopThreadURL(for session: SessionData) -> URL? {
        guard session.provider == .codex, session.codexOrigin == .desktop else {
            return nil
        }

        return codexDesktopThreadURL(threadId: session.rawSessionId)
    }

    static func codexCLIProcessId(for session: SessionData) -> pid_t? {
        guard session.provider == .codex,
              session.codexOrigin == .cli,
              let processId = session.codexProcessId,
              processId > 0 else {
            return nil
        }

        return pid_t(processId)
    }

    static func claudeCodeProcessId(for session: SessionData) -> pid_t? {
        guard session.provider == .claude,
              let processId = session.claudeProcessId,
              processId > 0 else {
            return nil
        }

        return pid_t(processId)
    }

    nonisolated static func codexDesktopThreadURL(threadId: String) -> URL? {
        let trimmedThreadId = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedThreadId.isEmpty,
              let encodedThreadId = trimmedThreadId.addingPercentEncoding(withAllowedCharacters: threadIDAllowedCharacters) else {
            return nil
        }

        return URL(string: "codex://threads/\(encodedThreadId)")
    }

    private func terminalProcessID(hosting processId: pid_t) -> pid_t? {
        var currentProcessId = processId
        var visitedProcessIds = Set<pid_t>()

        for _ in 0..<Self.maxProcessAncestryDepth {
            guard currentProcessId > 1, !visitedProcessIds.contains(currentProcessId) else {
                return nil
            }

            visitedProcessIds.insert(currentProcessId)

            guard let snapshot = processSnapshot(currentProcessId) else {
                return nil
            }

            if let bundleIdentifier = bundleIdentifierForProcess(currentProcessId),
               TerminalFocusDetector.terminalBundleIds.contains(bundleIdentifier) {
                return currentProcessId
            }

            guard snapshot.parentProcessId > 0 else {
                return nil
            }

            currentProcessId = snapshot.parentProcessId
        }

        return nil
    }

    private static func terminalBackedProcessId(for session: SessionData) -> pid_t? {
        codexCLIProcessId(for: session) ?? claudeCodeProcessId(for: session)
    }

    private nonisolated static let threadIDAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return allowed
    }()

    private nonisolated static let maxProcessAncestryDepth = 12

    private nonisolated static func defaultProcessSnapshot(for processId: pid_t) -> ProcessSnapshot? {
        guard processId > 1 else { return nil }

        var info = proc_bsdshortinfo()
        let size = MemoryLayout<proc_bsdshortinfo>.size
        let result = proc_pidinfo(Int32(processId), Int32(PROC_PIDT_SHORTBSDINFO), 0, &info, Int32(size))
        guard result == Int32(size), info.pbsi_ppid > 0 else {
            return nil
        }

        return ProcessSnapshot(parentProcessId: pid_t(info.pbsi_ppid))
    }

    private static func defaultBundleIdentifier(for processId: pid_t) -> String? {
        NSRunningApplication(processIdentifier: processId)?.bundleIdentifier
    }

    private static func defaultActivateProcess(_ processId: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: processId) else {
            return false
        }

        return app.activate()
    }
}
