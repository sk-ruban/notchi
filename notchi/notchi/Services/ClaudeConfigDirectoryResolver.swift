import Foundation

enum ClaudeConfigDirectorySource: String {
    case environment = "env"
    case shell = "shell"
    case fallback = "default"
}

struct ClaudeConfigDirectoryResolution: Sendable {
    let path: String
    let source: ClaudeConfigDirectorySource
    let shouldCache: Bool

    nonisolated var directoryURL: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    nonisolated var settingsURL: URL {
        directoryURL.appendingPathComponent("settings.json")
    }

    nonisolated var projectsDirectoryURL: URL {
        directoryURL.appendingPathComponent("projects", isDirectory: true)
    }

    nonisolated var claudeBinaryPath: String {
        directoryURL.appendingPathComponent("bin/claude").path
    }
}

enum ClaudeConfigDirectoryResolver {
    typealias TestHooks = ShellProbeTestHooks

    nonisolated private static let commandTimeout: TimeInterval = 2
    nonisolated private static let stateQueue = DispatchQueue(
        label: "com.ruban.notchi.claudeConfigResolver.state"
    )
    nonisolated(unsafe) private static var state = State()

    nonisolated static var testHooks: TestHooks {
        get {
            stateQueue.sync { state.testHooks }
        }
        set {
            stateQueue.sync { state.testHooks = newValue }
        }
    }

    /// The resolved directory without running the shell probe, for callers on the main thread:
    /// the cached result, else `CLAUDE_CONFIG_DIR` from notchi's own environment, else `~/.claude`.
    nonisolated static func resolveWithoutProbing() -> URL {
        let snapshot = currentState()
        if let cachedResolution = snapshot.cachedResolution {
            return cachedResolution.directoryURL
        }
        if let path = normalize(path: snapshot.testHooks.environment()["CLAUDE_CONFIG_DIR"]) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    nonisolated static func resolve() -> ClaudeConfigDirectoryResolution {
        let snapshot = currentState()
        if let cachedResolution = snapshot.cachedResolution {
            return cachedResolution
        }

        let hooks = snapshot.testHooks
        let environment = hooks.environment()
        let resolved: ClaudeConfigDirectoryResolution

        if let path = normalize(path: environment["CLAUDE_CONFIG_DIR"]) {
            resolved = ClaudeConfigDirectoryResolution(path: path, source: .environment, shouldCache: true)
        } else {
            switch resolveViaShell(environment: environment, testHooks: hooks) {
            case .resolved(let path):
                resolved = ClaudeConfigDirectoryResolution(path: path, source: .shell, shouldCache: true)
            case .unset:
                let fallback = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude", isDirectory: true)
                    .path
                resolved = ClaudeConfigDirectoryResolution(path: fallback, source: .fallback, shouldCache: true)
            case .probeFailed:
                let fallback = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude", isDirectory: true)
                    .path
                resolved = ClaudeConfigDirectoryResolution(path: fallback, source: .fallback, shouldCache: false)
            }
        }

        if resolved.shouldCache {
            updateState { $0.cachedResolution = resolved }
        }
        return resolved
    }

    nonisolated static func resetTestingHooks() {
        updateState {
            $0.testHooks = TestHooks.live(commandTimeout: commandTimeout)
            $0.cachedResolution = nil
        }
    }

    nonisolated private enum ShellResolution {
        case resolved(String)
        case unset
        case probeFailed
    }

    nonisolated private enum ShellProbeResult {
        case resolved(String)
        case unset
        case failed
    }

    nonisolated private struct State {
        var cachedResolution: ClaudeConfigDirectoryResolution?
        var testHooks = TestHooks.live(commandTimeout: commandTimeout)
    }

    nonisolated private static func currentState() -> State {
        stateQueue.sync { state }
    }

    nonisolated private static func updateState(_ body: (inout State) -> Void) {
        stateQueue.sync {
            body(&state)
        }
    }

    nonisolated private static func resolveViaShell(
        environment: [String: String],
        testHooks: TestHooks
    ) -> ShellResolution {
        let probeCommand = "printf '%s' \"$CLAUDE_CONFIG_DIR\""
        var sawSuccessfulProbe = false
        var sawFailedProbe = false

        for shellPath in shellCandidates(from: environment) {
            guard testHooks.isExecutableFile(shellPath) else { continue }

            switch runShellProbe(
                executablePath: shellPath,
                arguments: ["-lc", probeCommand],
                testHooks: testHooks
            ) {
            case .resolved(let path):
                return .resolved(path)
            case .unset:
                sawSuccessfulProbe = true
            case .failed:
                sawFailedProbe = true
            }

            switch runShellProbe(
                executablePath: shellPath,
                arguments: ["-ic", probeCommand],
                testHooks: testHooks
            ) {
            case .resolved(let path):
                return .resolved(path)
            case .unset:
                sawSuccessfulProbe = true
            case .failed:
                sawFailedProbe = true
            }
        }

        if sawFailedProbe {
            return .probeFailed
        }

        return sawSuccessfulProbe ? .unset : .probeFailed
    }

    nonisolated private static func runShellProbe(
        executablePath: String,
        arguments: [String],
        testHooks: TestHooks
    ) -> ShellProbeResult {
        guard let output = testHooks.runProcess(executablePath, arguments, nil) else {
            return .failed
        }

        guard let path = normalize(path: extractAbsolutePath(from: output)) else {
            return .unset
        }

        return .resolved(path)
    }

    nonisolated private static func normalize(path rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }

        return URL(fileURLWithPath: expanded, isDirectory: true)
            .standardizedFileURL
            .path
    }
}
