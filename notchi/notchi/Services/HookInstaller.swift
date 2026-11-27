import Foundation
import os.log

nonisolated private let logger = Logger(subsystem: "com.ruban.notchi", category: "HookInstaller")

struct HookInstaller {
    // One script outside every Claude config dir, so settings copied between accounts keep working.
    nonisolated private static let sharedHookScriptRelativePath = "Library/Application Support/Notchi/hooks/notchi-hook.sh"
    nonisolated private static let claudeAccountDirectoryPrefix = ".claude"
    nonisolated private static let settingsFileName = "settings.json"
    nonisolated private static let hookScriptName = "notchi-hook.sh"
    // Claude settings have always been written with unescaped slashes; changing it would rewrite users' files.
    nonisolated private static let settingsWritingOptions: JSONSerialization.WritingOptions =
        [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    /// Exits quietly when the script is gone (notchi uninstalled, settings synced to another Mac),
    /// and `exec` keeps the script's stdout and exit status for Claude Code.
    nonisolated static let hookCommand =
        #"f="$HOME/\#(sharedHookScriptRelativePath)"; [ -x "$f" ] || exit 0; exec "$f""#

    /// Left at the old per-account path so sessions started with the old hook command keep reporting.
    nonisolated static let legacyScriptShim = """
        #!/bin/bash
        # Notchi moved its hook script; this forwards hooks from sessions started before the move.
        f="$HOME/\(sharedHookScriptRelativePath)"
        [ -x "$f" ] || exit 0
        exec "$f"

        """

    nonisolated static func sharedHookScriptURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(sharedHookScriptRelativePath)
    }

    @discardableResult
    nonisolated static func installIfNeeded() -> Bool {
        let claudeConfig = ClaudeConfigDirectoryResolver.resolve()
        let claudeDir = claudeConfig.directoryURL

        guard isClaudeAvailable(resolution: claudeConfig) else {
            logger.warning("Claude Code not installed (config dir not found at \(claudeDir.path, privacy: .public))")
            return false
        }

        guard installSharedScript() else { return false }

        let accounts = ClaudeAccountStore.accountsToInstall(
            defaultDirectory: claudeDir,
            migrated: migrateOtherAccounts(excluding: claudeDir)
        )
        var installedAny = false
        for account in accounts where FileManager.default.fileExists(atPath: account.path) && addAccountHooks(to: account) {
            installedAny = true
        }
        return installedAny
    }

    nonisolated static func removeSharedScript() {
        try? FileManager.default.removeItem(at: sharedHookScriptURL())
    }

    /// Adds notchi to one more Claude account; the Claude hooks themselves must already be on.
    @discardableResult
    nonisolated static func addHooks(toAccount directory: URL) -> Bool {
        installSharedScript() && addAccountHooks(to: directory)
    }

    nonisolated static func removeHooks(fromAccount directory: URL) {
        try? FileManager.default.removeItem(at: legacyScriptURL(forAccount: directory))
        HookConfigJSON.pruneManagedHooks(
            inConfigAt: directory.appendingPathComponent(settingsFileName),
            fileDescription: "Claude settings.json",
            isManaged: isManagedCommand,
            options: settingsWritingOptions,
            logger: logger
        )
    }

    nonisolated static func isHookInstalled(inAccount directory: URL) -> Bool {
        isHookInstalled(in: try? Data(contentsOf: directory.appendingPathComponent(settingsFileName)))
    }

    /// Points the account's settings at the shared script and leaves the shim at its old script path.
    @discardableResult
    nonisolated static func addAccountHooks(to directory: URL) -> Bool {
        let shim = legacyScriptURL(forAccount: directory)
        do {
            try FileManager.default.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
            try HookFile.writeScriptIfNeeded(Data(legacyScriptShim.utf8), to: shim)
        } catch {
            logger.error("Failed to install hook shim: \(error.localizedDescription)")
            return false
        }
        return updateSettings(at: directory.appendingPathComponent(settingsFileName)) {
            upsertHookSettings(from: $0, command: hookCommand)
        }
    }

    nonisolated private static func installSharedScript() -> Bool {
        HookFile.installBundledScript(named: "notchi-hook", to: sharedHookScriptURL(), agentName: "Claude", logger: logger)
    }

    /// Switches other accounts that run notchi to the shared command, and leaves the shim at their old
    /// script path for their sessions that started before the switch. Returns those accounts.
    @discardableResult
    nonisolated static func migrateOtherAccounts(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        excluding primaryDirectory: URL
    ) -> [URL] {
        otherAccountSettingsURLs(home: home, excluding: primaryDirectory).map { settings in
            let account = settings.deletingLastPathComponent()
            addAccountHooks(to: account)
            return account
        }
    }

    nonisolated static func removeFromOtherAccounts(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        excluding primaryDirectory: URL
    ) {
        for settings in otherAccountSettingsURLs(home: home, excluding: primaryDirectory) {
            removeHooks(fromAccount: settings.deletingLastPathComponent())
        }
    }

    nonisolated private static func legacyScriptURL(forAccount directory: URL) -> URL {
        directory
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent(hookScriptName)
    }

    /// Settings of other Claude config dirs (`~/.claude-personal` etc.) that already run notchi's hook,
    /// typically copied from the main account. Only these are touched; adding accounts is opt-in.
    nonisolated static func otherAccountSettingsURLs(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        excluding primaryDirectory: URL
    ) -> [URL] {
        let fileManager = FileManager.default
        let primaryPath = primaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let names = (try? fileManager.contentsOfDirectory(atPath: home.path)) ?? []

        return names
            .filter { $0.hasPrefix(claudeAccountDirectoryPrefix) }
            .map { home.appendingPathComponent($0, isDirectory: true) }
            .filter { url in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            .filter { $0.standardizedFileURL.resolvingSymlinksInPath().path != primaryPath }
            .map { $0.appendingPathComponent(settingsFileName) }
            .filter { isHookInstalled(in: try? Data(contentsOf: $0)) }
            .sorted { $0.path < $1.path }
    }

    /// Nil when existing settings can't be parsed, so a hand-edited file is never replaced wholesale.
    nonisolated static func upsertHookSettings(from existingData: Data?, command: String) -> Data? {
        guard var json = HookConfigJSON.editableObject(from: existingData) else { return nil }

        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry]
        ]

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        let hookEvents: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            ("PermissionRequest", withMatcher),
            ("PreCompact", preCompactConfig),
            ("Stop", withoutMatcher),
            ("SubagentStop", withoutMatcher),
            ("SessionEnd", withoutMatcher),
        ]

        for (event, config) in hookEvents {
            if var existingEvent = hooks[event] as? [[String: Any]] {
                var foundExistingHook = false

                for index in existingEvent.indices {
                    guard var entryHooks = existingEvent[index]["hooks"] as? [[String: Any]] else { continue }

                    var didUpdateEntry = false
                    for hookIndex in entryHooks.indices {
                        let cmd = entryHooks[hookIndex]["command"] as? String ?? ""
                        guard isManagedCommand(cmd) else { continue }

                        foundExistingHook = true
                        didUpdateEntry = true

                        if cmd != command {
                            entryHooks[hookIndex]["command"] = command
                        }
                    }

                    if didUpdateEntry {
                        existingEvent[index]["hooks"] = entryHooks
                    }
                }

                if !foundExistingHook {
                    existingEvent.append(contentsOf: config)
                }

                hooks[event] = existingEvent
            } else {
                hooks[event] = config
            }
        }

        json["hooks"] = hooks

        return HookConfigJSON.serialize(json, options: settingsWritingOptions)
    }

    /// False when `transform` declines (nil) or the write fails.
    nonisolated private static func updateSettings(at settingsURL: URL, transform: (Data?) -> Data?) -> Bool {
        let existingData = try? Data(contentsOf: settingsURL)

        guard let data = transform(existingData) else {
            logger.error("Left \(settingsURL.path, privacy: .public) unchanged: it could not be updated with notchi's hooks")
            return false
        }
        guard data != existingData else { return true }

        do {
            try writeSettings(data, to: settingsURL)
            return true
        } catch {
            logger.error("Failed to write settings.json: \(error.localizedDescription)")
            return false
        }
    }

    /// Writes atomically through symlinks (dotfiles), keeping the file's permissions.
    nonisolated static func writeSettings(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        try HookFile.writeConfig(data, to: url, fileManager: fileManager)
    }

    nonisolated static func isHookInstalled(in settingsData: Data?) -> Bool {
        HookConfigJSON.containsManagedHook(in: settingsData, isManaged: isManagedCommand)
    }

    /// True while any Claude account runs notchi.
    nonisolated static func isInstalled() -> Bool {
        let accounts = [ClaudeConfigDirectoryResolver.resolve().directoryURL]
            + ClaudeAccountStore.accountDirectoriesWithNotchi()
        return accounts.contains { isHookInstalled(inAccount: $0) }
    }

    /// Claude Code counts as installed when its default config dir exists or an account runs notchi.
    nonisolated static func isClaudeAvailable(
        resolution: ClaudeConfigDirectoryResolution = ClaudeConfigDirectoryResolver.resolve()
    ) -> Bool {
        claudeConfigDirectoryExists(resolution: resolution)
            || ClaudeAccountStore.accountDirectoriesWithNotchi().contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    nonisolated static func claudeConfigDirectoryExists(
        resolution: ClaudeConfigDirectoryResolution = ClaudeConfigDirectoryResolver.resolve(),
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(atPath: resolution.directoryURL.path)
    }

    nonisolated static func uninstall() {
        let claudeConfig = ClaudeConfigDirectoryResolver.resolve()

        removeSharedScript()
        removeHooks(fromAccount: claudeConfig.directoryURL)
        removeFromOtherAccounts(excluding: claudeConfig.directoryURL)
        for account in ClaudeAccountStore.accountDirectoriesWithNotchi() {
            removeHooks(fromAccount: account)
        }
        ClaudeAccountStore.forgetAccountsWithNotchi()
    }

    nonisolated static func removeManagedHookSettings(from existingData: Data?) -> Data? {
        HookConfigJSON.removeManagedHooks(from: existingData, isManaged: isManagedCommand, options: settingsWritingOptions)
    }

    nonisolated private static func isManagedCommand(_ command: String) -> Bool {
        command.contains(hookScriptName)
    }
}
