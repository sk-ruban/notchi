import AppKit
import ApplicationServices
import CoreGraphics
import Carbon.HIToolbox
import os.log

nonisolated private let logger = Logger(subsystem: "com.ruban.notchi", category: "PromptInjection")

nonisolated protocol KeyEventPosting {
    /// Types `text` into the app owning `pid` via synthesized Unicode key events.
    /// If `withReturn` is true, posts a Return key event immediately after typing.
    func postText(_ text: String, toPID pid: pid_t, withReturn: Bool)
}

@MainActor
struct PromptInjectionService {
    static let shared = PromptInjectionService()

    private let poster: KeyEventPosting
    // Background injection into the session's exact tab (Terminal.app/iTerm2):
    // true = delivered, false = scriptable but failed, nil = not scriptable.
    private let scriptInject: @MainActor (String, SessionData) async -> Bool?
    // Fallback target pid for the direct-keystroke path (non-scriptable terminals).
    private let resolveTerminalPID: @MainActor (SessionData) -> pid_t?
    // Whether a pid belongs to a known terminal app — gates the frontmost-app
    // fallback so keystrokes are never posted into an unrelated app.
    private let isTerminalPID: @MainActor (pid_t) -> Bool
    private let accessibilityTrusted: @Sendable () -> Bool
    private let activateProcess: @MainActor (pid_t) -> Bool

    init(
        poster: KeyEventPosting = CGEventKeyPoster(),
        scriptInject: @escaping @MainActor (String, SessionData) async -> Bool? = { await TerminalJumpService.shared.injectViaScript($0, into: $1) },
        resolveTerminalPID: @escaping @MainActor (SessionData) -> pid_t? = { TerminalJumpService.shared.terminalProcessId(for: $0) },
        isTerminalPID: @escaping @MainActor (pid_t) -> Bool = { pid in
            guard let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
            return TerminalFocusDetector.terminalBundleIds.contains(bundleId)
        },
        accessibilityTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        activateProcess: @escaping @MainActor (pid_t) -> Bool = { NSRunningApplication(processIdentifier: $0)?.activate() ?? false }
    ) {
        self.poster = poster
        self.scriptInject = scriptInject
        self.resolveTerminalPID = resolveTerminalPID
        self.isTerminalPID = isTerminalPID
        self.accessibilityTrusted = accessibilityTrusted
        self.activateProcess = activateProcess
    }

    // Not `nonisolated`: `codexOrigin` is a mutable, MainActor-isolated property
    // of `SessionData` (a `@MainActor` class), so reading it requires MainActor
    // context. This is still a pure function — no side effects, no external state
    // beyond the passed-in session — just isolated to the actor its argument lives on.
    static func canInject(into session: SessionData) -> Bool {
        !(session.provider == .codex && session.codexOrigin == .desktop)
    }

    nonisolated static func preparedPrompt(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func inject(_ raw: String, into session: SessionData?, fallbackAppPID: pid_t? = nil) async -> InjectionResult {
        guard let session else { logger.info("inject: no target session"); return .noSession }
        guard Self.canInject(into: session) else {
            logger.info("inject: session not injectable (codex desktop)")
            return .notInjectable
        }
        guard let text = Self.preparedPrompt(raw) else { return .failed }

        // Preferred path: write straight into the session's own tab in the
        // BACKGROUND (Terminal.app / iTerm2) — no focus change, no Accessibility.
        // The user can stay in another app while it runs.
        if let delivered = await scriptInject(text, session) {
            if delivered {
                logger.info("inject: delivered to \(session.provider.rawValue, privacy: .public) session tab via script")
                return .sent
            }
            logger.error("inject: script delivery failed for \(session.provider.rawValue, privacy: .public) session (tab gone or Automation denied)")
            return .failed
        }

        // Fallback (non-scriptable terminals, e.g. VSCode/Warp): type the text into
        // the terminal. Needs Accessibility and is NOT background — it requires
        // the target terminal to be activated so keystrokes are not sent to an
        // arbitrary background window.
        guard accessibilityTrusted() else {
            logger.error("inject: accessibility not trusted; cannot post key events")
            return .needsAccessibility
        }

        // Prefer the session's own terminal; only fall back to the frontmost app
        // if it's actually a terminal — otherwise the keystrokes would land in an
        // unrelated app (e.g. the browser the user dictated from).
        let targetPID: pid_t?
        if let resolved = resolveTerminalPID(session) {
            targetPID = resolved
        } else if let fallbackAppPID, isTerminalPID(fallbackAppPID) {
            targetPID = fallbackAppPID
        } else {
            targetPID = nil
        }
        guard let targetPID else {
            logger.error("inject: no terminal target for \(session.provider.rawValue, privacy: .public) session (claudePid=\(session.claudeProcessId ?? -1, privacy: .public), fallbackPID=\(fallbackAppPID ?? -1, privacy: .public))")
            return .failed
        }

        // Activate the target terminal so the user sees the receiving window
        // and keystrokes are received by the active focus rather than lost or
        // misdirected to a background process.
        _ = activateProcess(targetPID)

        // If dictation started from this exact terminal app (i.e. frontmost when
        // hotkey held), the user was already in this context: send Return to submit.
        // Otherwise, the terminal was in the background: type the text WITHOUT
        // Return so the user can verify the target tab/pane before executing.
        let isInitiatedFromTarget = (fallbackAppPID == targetPID)
        poster.postText(text, toPID: targetPID, withReturn: isInitiatedFromTarget)
        logger.info("inject: typed text to pid \(targetPID, privacy: .public) for \(session.provider.rawValue, privacy: .public) session (fallback, withReturn=\(isInitiatedFromTarget, privacy: .public))")
        return .sent
    }
}

// Not unit-tested: posts real system key events (needs Accessibility).
struct CGEventKeyPoster: KeyEventPosting {
    nonisolated init() {}

    nonisolated func postText(_ text: String, toPID pid: pid_t, withReturn: Bool) {
        let source = CGEventSource(stateID: .combinedSessionState)
        // WHY: type the prompt as Unicode key events instead of a ⌘V paste, so we
        // never overwrite the user's clipboard (string OR rich data).
        typeUnicode(text, source: source, pid: pid)
        if withReturn {
            postKey(CGKeyCode(kVK_Return), source: source, pid: pid)
        }
    }

    nonisolated private func typeUnicode(_ text: String, source: CGEventSource?, pid: pid_t) {
        let chars = Array(text.utf16)
        guard !chars.isEmpty,
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        chars.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        down.postToPid(pid)
        up.postToPid(pid)
    }

    nonisolated private func postKey(_ key: CGKeyCode, source: CGEventSource?, pid: pid_t) {
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.postToPid(pid)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.postToPid(pid)
    }
}
