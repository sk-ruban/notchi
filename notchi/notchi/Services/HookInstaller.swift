import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "HookInstaller")

struct HookInstaller {

    static func installIfNeeded() {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")

        guard FileManager.default.fileExists(atPath: claudeDir.path) else {
            logger.warning("Claude Code not installed (~/.claude not found)")
            return
        }

        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let hookScript = hooksDir.appendingPathComponent("notchi-hook.sh")
        let settings = claudeDir.appendingPathComponent("settings.json")

        do {
            try FileManager.default.createDirectory(
                at: hooksDir,
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("Failed to create hooks directory: \(error.localizedDescription)")
            return
        }

        if let bundled = Bundle.main.url(forResource: "notchi-hook", withExtension: "sh") {
            do {
                try? FileManager.default.removeItem(at: hookScript)
                try FileManager.default.copyItem(at: bundled, to: hookScript)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: hookScript.path
                )
                logger.info("Installed hook script to \(hookScript.path, privacy: .public)")
            } catch {
                logger.error("Failed to install hook script: \(error.localizedDescription)")
                return
            }
        } else {
            logger.error("Hook script not found in bundle")
            return
        }

        updateSettings(at: settings)
    }

    private static func updateSettings(at settingsURL: URL) {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        let command = "~/.claude/hooks/notchi-hook.sh"
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        let hookEvents: [(String, [[String: Any]])] = [
            ("SessionStart", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            ("SessionEnd", withoutMatcher),
        ]

        for (event, config) in hookEvents {
            if var existingEvent = hooks[event] as? [[String: Any]] {
                let hasOurHook = existingEvent.contains { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { h in
                            let cmd = h["command"] as? String ?? ""
                            return cmd.contains("notchi-hook.sh")
                        }
                    }
                    return false
                }
                if !hasOurHook {
                    existingEvent.append(contentsOf: config)
                    hooks[event] = existingEvent
                }
            } else {
                hooks[event] = config
            }
        }

        json["hooks"] = hooks

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            do {
                try data.write(to: settingsURL)
                logger.info("Updated settings.json with Notchi hooks")
            } catch {
                logger.error("Failed to write settings.json: \(error.localizedDescription)")
            }
        }
    }

    static func isInstalled() -> Bool {
        let settings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")

        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        return hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return entryHooks.contains { hook in
                    (hook["command"] as? String)?.contains("notchi-hook.sh") == true
                }
            }
        }
    }

    static func uninstall() {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let hookScript = hooksDir.appendingPathComponent("notchi-hook.sh")
        let settings = claudeDir.appendingPathComponent("settings.json")

        try? FileManager.default.removeItem(at: hookScript)

        guard let data = try? Data(contentsOf: settings),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries.removeAll { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { hook in
                            let cmd = hook["command"] as? String ?? ""
                            return cmd.contains("notchi-hook.sh")
                        }
                    }
                    return false
                }

                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: settings)
        }

        logger.info("Uninstalled Notchi hooks")
    }
}
