import AppKit
import Darwin
import os.log

nonisolated private let logger = Logger(subsystem: "com.ruban.notchi", category: "TerminalJump")

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
    private let activateApplication: @MainActor (String) -> Bool

    init(
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        processSnapshot: @escaping @MainActor (pid_t) -> ProcessSnapshot? = Self.defaultProcessSnapshot,
        bundleIdentifierForProcess: @escaping @MainActor (pid_t) -> String? = Self.defaultBundleIdentifier,
        activateProcess: @escaping @MainActor (pid_t) -> Bool = Self.defaultActivateProcess,
        activateApplication: @escaping @MainActor (String) -> Bool = Self.defaultActivateApplication
    ) {
        self.openURL = openURL
        self.processSnapshot = processSnapshot
        self.bundleIdentifierForProcess = bundleIdentifierForProcess
        self.activateProcess = activateProcess
        self.activateApplication = activateApplication
    }

    @discardableResult
    func jump(to session: SessionData) -> Bool {
        if let processId = Self.hostBackedProcessId(for: session),
           let hostProcessId = terminalProcessID(hosting: processId) {
            return activateProcess(hostProcessId)
        }

        if let hostBundleIdentifier = session.hostBundleIdentifier {
            return activateApplication(hostBundleIdentifier)
        }

        if let url = Self.codexDesktopThreadURL(for: session) {
            return openURL(url)
        }

        return false
    }

    func hostBundleIdentifier(hosting processId: pid_t) -> String? {
        terminalProcessID(hosting: processId).flatMap(bundleIdentifierForProcess)
    }

    // The pid of the terminal app hosting the session's CLI process — the
    // target for direct key-event injection (CGEvent.postToPid).
    func terminalProcessId(for session: SessionData) -> pid_t? {
        guard let processId = Self.terminalBackedProcessId(for: session),
              let terminalProcessId = terminalProcessID(hosting: processId) else {
            return nil
        }
        return terminalProcessId
    }

    /// Injects `text` (as a submitted line) straight into the terminal tab hosting
    /// `session`, in the BACKGROUND — no focus/activation — via AppleScript keyed
    /// by the CLI process's controlling tty. Returns:
    ///   • true  → delivered
    ///   • false → scriptable terminal but delivery failed (tab gone / Automation denied)
    ///   • nil   → terminal not scriptable or tty unknown; caller should fall back
    func injectViaScript(_ text: String, into session: SessionData) async -> Bool? {
        guard let cliPID = Self.terminalBackedProcessId(for: session),
              let terminalPID = terminalProcessID(hosting: cliPID),
              let bundleId = bundleIdentifierForProcess(terminalPID),
              let tty = Self.controllingTTY(of: cliPID),
              let script = Self.writeTextScript(bundleId: bundleId, tty: tty, text: text) else {
            return nil
        }
        return await Self.runAppleScript(script)
    }

    private nonisolated static func controllingTTY(of pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard result == Int32(size) else { return nil }
        let dev = dev_t(bitPattern: info.e_tdev)
        guard dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    // ponytail: newlines flattened to spaces — dictated speech is single-line and
    // an embedded newline in a terminal write submits early; preserve multiline
    // only if a real need shows up.
    private nonisolated static func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    // Only Terminal.app and iTerm2 can write into a specific tab by tty without
    // focusing it. Every other "terminal" in the supported list (Warp, kitty,
    // VSCode/JetBrains integrated terminals, …) has no such API → nil, caller falls back.
    private nonisolated static func writeTextScript(bundleId: String, tty: String, text: String) -> String? {
        let escaped = escapeForAppleScript(text)
        switch bundleId {
        case "com.apple.Terminal":
            return """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            do script "\(escaped)" in t
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "notfound"
            """
        case "com.googlecode.iterm2":
            return """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                tell s to write text "\(escaped)"
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "notfound"
            """
        default:
            return nil
        }
    }

    // Runs off the main thread via `osascript` so a slow/busy Terminal (or an
    // Automation prompt) never freezes the notch UI. Returns true only when the
    // script printed "ok" (tab found + written).
    private nonisolated static func runAppleScript(_ source: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", source]
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    logger.error("tab-write osascript failed to launch: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: false)
                    return
                }
                process.waitUntilExit()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: process.terminationStatus == 0 && output == "ok")
            }
        }
    }

    static func codexDesktopThreadURL(for session: SessionData) -> URL? {
        guard session.provider == .codex, session.codexOrigin == .desktop else {
            return nil
        }

        return codexDesktopThreadURL(threadId: session.rawSessionId)
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

    private static func hostBackedProcessId(for session: SessionData) -> pid_t? {
        codexProcessId(for: session) ?? claudeCodeProcessId(for: session)
    }

    private static func codexProcessId(for session: SessionData) -> pid_t? {
        guard session.provider == .codex,
              let processId = session.codexProcessId,
              processId > 0 else {
            return nil
        }

        return pid_t(processId)
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

    private static func defaultActivateApplication(_ bundleIdentifier: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return false
        }

        return app.activate()
    }
}
