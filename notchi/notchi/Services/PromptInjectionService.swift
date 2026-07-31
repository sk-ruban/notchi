import AppKit
import ApplicationServices
import CoreGraphics
import Carbon.HIToolbox
import os.log

nonisolated private let logger = Logger(subsystem: "com.ruban.notchi", category: "PromptInjection")

nonisolated protocol Pasteboarding {
    func string() -> String?
    func setString(_ value: String)
}

nonisolated protocol KeyEventPosting {
    func postPasteAndReturn(toPID pid: pid_t)
}

@MainActor
struct PromptInjectionService {
    static let shared = PromptInjectionService()

    private let pasteboard: Pasteboarding
    private let poster: KeyEventPosting
    // Background injection into the session's exact tab (Terminal.app/iTerm2):
    // true = delivered, false = scriptable but failed, nil = not scriptable.
    private let scriptInject: @MainActor (String, SessionData) async -> Bool?
    // Fallback target pid for the CGEvent paste path (non-scriptable terminals).
    private let resolveTerminalPID: @MainActor (SessionData) -> pid_t?
    // Whether a pid belongs to a known terminal app — gates the frontmost-app
    // fallback so ⌘V+Return is never posted into an unrelated app.
    private let isTerminalPID: @MainActor (pid_t) -> Bool
    private let accessibilityTrusted: @Sendable () -> Bool
    private let restoreDelay: TimeInterval

    init(
        pasteboard: Pasteboarding = NSPasteboardAdapter(),
        poster: KeyEventPosting = CGEventKeyPoster(),
        scriptInject: @escaping @MainActor (String, SessionData) async -> Bool? = { await TerminalJumpService.shared.injectViaScript($0, into: $1) },
        resolveTerminalPID: @escaping @MainActor (SessionData) -> pid_t? = { TerminalJumpService.shared.terminalProcessId(for: $0) },
        isTerminalPID: @escaping @MainActor (pid_t) -> Bool = { pid in
            guard let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
            return TerminalFocusDetector.terminalBundleIds.contains(bundleId)
        },
        accessibilityTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        restoreDelay: TimeInterval = 0.6
    ) {
        self.pasteboard = pasteboard
        self.poster = poster
        self.scriptInject = scriptInject
        self.resolveTerminalPID = resolveTerminalPID
        self.isTerminalPID = isTerminalPID
        self.accessibilityTrusted = accessibilityTrusted
        self.restoreDelay = restoreDelay
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
        // BACKGROUND (Terminal.app / iTerm2) — no focus change, no clipboard, no
        // Accessibility. The user can stay in another app while it runs.
        if let delivered = await scriptInject(text, session) {
            if delivered {
                logger.info("inject: delivered to \(session.provider.rawValue, privacy: .public) session tab via script")
                return .sent
            }
            logger.error("inject: script delivery failed for \(session.provider.rawValue, privacy: .public) session (tab gone or Automation denied)")
            return .failed
        }

        // Fallback (non-scriptable terminals, e.g. VSCode/Warp): synthesize
        // ⌘V+Return to the terminal's focused tab. Needs Accessibility and is NOT
        // background — it lands wherever that terminal is focused.
        guard accessibilityTrusted() else {
            logger.error("inject: accessibility not trusted; cannot post paste events")
            return .needsAccessibility
        }
        // Prefer the session's own terminal; only fall back to the frontmost app
        // if it's actually a terminal — otherwise ⌘V+Return would land in an
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

        let saved = pasteboard.string()
        pasteboard.setString(text)
        poster.postPasteAndReturn(toPID: targetPID)
        restorePasteboard(saved: saved, injected: text)
        logger.info("inject: posted paste to pid \(targetPID, privacy: .public) for \(session.provider.rawValue, privacy: .public) session (fallback)")
        return .sent
    }

    private func restorePasteboard(saved: String?, injected: String) {
        // Restore to whatever was there before — including empty, so the dictated
        // text isn't left lingering on the clipboard when it started out empty.
        let restored = saved ?? ""
        // Only restore if OUR injected text is still on the clipboard; the user
        // may have copied something new during the delay — don't clobber it.
        let restoreIfUnchanged: @MainActor (Pasteboarding) -> Void = { board in
            if board.string() == injected { board.setString(restored) }
        }
        if restoreDelay <= 0 {
            restoreIfUnchanged(pasteboard)
        } else {
            // WHY: restore only after the target has surely consumed the paste;
            // reverting too soon would clobber the pasteboard before ⌘V is read.
            let delay = restoreDelay, board = pasteboard
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                restoreIfUnchanged(board)
            }
        }
    }
}

struct NSPasteboardAdapter: Pasteboarding {
    nonisolated init() {}
    nonisolated func string() -> String? { NSPasteboard.general.string(forType: .string) }
    nonisolated func setString(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

// Not unit-tested: posts real system key events (needs Accessibility).
struct CGEventKeyPoster: KeyEventPosting {
    nonisolated init() {}

    nonisolated func postPasteAndReturn(toPID pid: pid_t) {
        let source = CGEventSource(stateID: .combinedSessionState)
        postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand, source: source, pid: pid)
        postKey(CGKeyCode(kVK_Return), flags: [], source: source, pid: pid)
    }

    nonisolated private func postKey(_ key: CGKeyCode, flags: CGEventFlags, source: CGEventSource?, pid: pid_t) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        down?.flags = flags
        down?.postToPid(pid)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        up?.flags = flags
        up?.postToPid(pid)
    }
}
