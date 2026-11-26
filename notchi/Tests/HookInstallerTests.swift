import Foundation
import XCTest
@testable import notchi

final class HookInstallerTests: XCTestCase {
    func testUpsertHookSettingsAddsConfiguredHookCommand() throws {
        let data = HookInstaller.upsertHookSettings(from: nil, command: HookInstaller.hookCommand)

        XCTAssertTrue(HookInstaller.isHookInstalled(in: data))

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let sessionStartHooks = try XCTUnwrap(sessionStart.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(sessionStartHooks.first?["command"] as? String, HookInstaller.hookCommand)
    }

    func testUpsertHookSettingsPreservesExistingEntriesAndAvoidsDuplicates() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "hooks": [
                "SessionStart": [
                    [
                        "hooks": [
                            ["type": "command", "command": HookInstaller.hookCommand],
                        ],
                    ],
                    [
                        "hooks": [
                            ["type": "command", "command": "echo other"],
                        ],
                    ],
                ],
            ],
        ])

        let updated = try XCTUnwrap(HookInstaller.upsertHookSettings(from: existing, command: HookInstaller.hookCommand))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])

        XCTAssertEqual(sessionStart.count, 2)
        XCTAssertTrue(HookInstaller.isHookInstalled(in: updated))
    }

    func testUpsertHookSettingsMigratesLegacyNotchiHookCommand() throws {
        let legacyCommand = "~/.claude/hooks/notchi-hook.sh"
        let existing = try JSONSerialization.data(withJSONObject: [
            "hooks": [
                "SessionStart": [
                    [
                        "hooks": [
                            ["type": "command", "command": legacyCommand],
                        ],
                    ],
                ],
            ],
        ])

        let updated = try XCTUnwrap(HookInstaller.upsertHookSettings(from: existing, command: HookInstaller.hookCommand))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let sessionStartHooks = try XCTUnwrap(sessionStart.first?["hooks"] as? [[String: Any]])

        XCTAssertEqual(sessionStart.count, 1)
        XCTAssertEqual(sessionStartHooks.count, 1)
        XCTAssertEqual(sessionStartHooks.first?["command"] as? String, HookInstaller.hookCommand)
    }

    func testUpsertHookSettingsIsIdempotentSoReinstallSkipsRewrite() throws {
        let first = try XCTUnwrap(HookInstaller.upsertHookSettings(from: nil, command: HookInstaller.hookCommand))
        let second = try XCTUnwrap(HookInstaller.upsertHookSettings(from: first, command: HookInstaller.hookCommand))

        XCTAssertEqual(first, second)
    }

    func testRemoveManagedHookSettingsKeepsSiblingHookInSameEntry() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "*",
                        "hooks": [
                            ["type": "command", "command": HookInstaller.hookCommand],
                            ["type": "command", "command": "echo other"],
                        ],
                    ],
                ],
            ],
        ])

        let updated = try XCTUnwrap(HookInstaller.removeManagedHookSettings(from: existing))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let entryHooks = try XCTUnwrap(preToolUse.first?["hooks"] as? [[String: Any]])

        XCTAssertEqual(preToolUse.count, 1)
        XCTAssertEqual(entryHooks.count, 1)
        XCTAssertEqual(entryHooks.first?["command"] as? String, "echo other")
        XCTAssertFalse(HookInstaller.isHookInstalled(in: updated))
    }

    func testRemoveManagedHookSettingsRemovesNotchiEntryButKeepsUnrelatedEntry() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "hooks": [
                "SessionStart": [
                    [
                        "hooks": [
                            ["type": "command", "command": HookInstaller.hookCommand],
                        ],
                    ],
                    [
                        "hooks": [
                            ["type": "command", "command": "echo other"],
                        ],
                    ],
                ],
            ],
        ])

        let updated = try XCTUnwrap(HookInstaller.removeManagedHookSettings(from: existing))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let remainingHooks = try XCTUnwrap(sessionStart.first?["hooks"] as? [[String: Any]])

        XCTAssertEqual(sessionStart.count, 1)
        XCTAssertEqual(remainingHooks.first?["command"] as? String, "echo other")
    }

    func testRemoveManagedHookSettingsDropsHooksKeyWhenOnlyNotchiHooksExist() throws {
        let existing = try XCTUnwrap(HookInstaller.upsertHookSettings(from: nil, command: HookInstaller.hookCommand))

        let updated = try XCTUnwrap(HookInstaller.removeManagedHookSettings(from: existing))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: updated) as? [String: Any])

        XCTAssertNil(json["hooks"])
        XCTAssertFalse(HookInstaller.isHookInstalled(in: updated))
    }

    func testRemoveManagedHookSettingsReturnsNilWhenNoHooksPresent() throws {
        let existing = try JSONSerialization.data(withJSONObject: ["someOtherKey": "value"])

        XCTAssertNil(HookInstaller.removeManagedHookSettings(from: existing))
    }

    // MARK: - Shared hook script

    private static let legacyAccountRelativeCommand = #""${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/notchi-hook.sh""#
    private static let scriptOutput = "notchi hook ran"

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("HookInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    private func installSharedScript(in home: URL, body: String) throws {
        let script = HookInstaller.sharedHookScriptURL(home: home)
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/bash\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    /// Runs a hook command the way Claude Code does, through `/bin/sh -c`, with stdin attached.
    private func runHookCommand(_ command: String, home: URL) throws -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(#"{"hook_event_name":"Stop"}"#.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (output.trimmingCharacters(in: .whitespacesAndNewlines), process.terminationStatus)
    }

    func testHookCommandRunsTheSharedScript() throws {
        let home = try makeHome()
        try installSharedScript(in: home, body: "cat >/dev/null; echo '\(Self.scriptOutput)'")

        XCTAssertEqual(try runHookCommand(HookInstaller.hookCommand, home: home).output, Self.scriptOutput)
    }

    func testHookCommandExitsQuietlyWhenTheSharedScriptIsMissing() throws {
        let home = try makeHome()

        let result = try runHookCommand(HookInstaller.hookCommand, home: home)

        XCTAssertEqual(result.output + "|\(result.status)", "|0")
    }

    func testHookCommandPassesThroughTheScriptsExitStatus() throws {
        let blockingExitStatus: Int32 = 2
        let home = try makeHome()
        try installSharedScript(in: home, body: "exit \(blockingExitStatus)")

        XCTAssertEqual(try runHookCommand(HookInstaller.hookCommand, home: home).status, blockingExitStatus)
    }

    func testLegacyScriptHandsOffToTheSharedScript() throws {
        let home = try makeHome()
        try installSharedScript(in: home, body: "cat >/dev/null; echo '\(Self.scriptOutput)'")
        let legacy = home.appendingPathComponent("legacy-notchi-hook.sh")
        try HookFile.writeScriptIfNeeded(Data(HookInstaller.legacyScriptShim.utf8), to: legacy)

        XCTAssertEqual(try runHookCommand("'\(legacy.path)'", home: home).output, Self.scriptOutput)
    }

    // MARK: - Other Claude accounts

    private func settings(withCommand command: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "theme": "dark",
            "hooks": ["Stop": [["hooks": [["type": "command", "command": command]]]]],
        ])
    }

    private func stopCommands(in data: Data) throws -> [String] {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stop = try XCTUnwrap((json["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        return stop.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    func testOnlyOtherClaudeAccountsThatRunNotchiAreMigrated() throws {
        let home = try makeHome()
        let fileManager = FileManager.default
        func account(_ name: String, command: String?) throws -> URL {
            let directory = home.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if let command {
                try settings(withCommand: command).write(to: directory.appendingPathComponent("settings.json"))
            }
            return directory
        }
        let primary = try account(".claude", command: Self.legacyAccountRelativeCommand)
        let personal = try account(".claude-personal", command: Self.legacyAccountRelativeCommand)
        _ = try account(".claude-scratch", command: "echo other")
        _ = try account(".claude-empty", command: nil)
        _ = try account(".config", command: Self.legacyAccountRelativeCommand)
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude.json"))

        let found = HookInstaller.otherAccountSettingsURLs(home: home, excluding: primary)

        XCTAssertEqual(found.map(\.path), [personal.appendingPathComponent("settings.json").path])
    }

    private func personalAccount(in home: URL) throws -> URL {
        let account = home.appendingPathComponent(".claude-personal", isDirectory: true)
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        try settings(withCommand: Self.legacyAccountRelativeCommand).write(to: account.appendingPathComponent("settings.json"))
        return account
    }

    func testMigratedAccountsOldScriptPathHandsOffToTheSharedScript() throws {
        let home = try makeHome()
        let personal = try personalAccount(in: home)
        try installSharedScript(in: home, body: "cat >/dev/null; echo '\(Self.scriptOutput)'")

        HookInstaller.migrateOtherAccounts(home: home, excluding: home.appendingPathComponent(".claude"))

        // What a session started before the migration still runs.
        let oldCommandInPersonal = #"CLAUDE_CONFIG_DIR='\#(personal.path)'; "${CLAUDE_CONFIG_DIR}/hooks/notchi-hook.sh""#
        XCTAssertEqual(try runHookCommand(oldCommandInPersonal, home: home).output, Self.scriptOutput)
    }

    func testMigratingOtherAccountsSwitchesTheirSettingsToTheSharedCommand() throws {
        let home = try makeHome()
        let personal = try personalAccount(in: home)

        HookInstaller.migrateOtherAccounts(home: home, excluding: home.appendingPathComponent(".claude"))

        let migrated = try Data(contentsOf: personal.appendingPathComponent("settings.json"))
        XCTAssertEqual(try stopCommands(in: migrated), [HookInstaller.hookCommand])
    }

    func testRemovingFromOtherAccountsDeletesTheirOldPathScript() throws {
        let home = try makeHome()
        let personal = try personalAccount(in: home)
        HookInstaller.migrateOtherAccounts(home: home, excluding: home.appendingPathComponent(".claude"))

        HookInstaller.removeFromOtherAccounts(home: home, excluding: home.appendingPathComponent(".claude"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: personal.appendingPathComponent("hooks/notchi-hook.sh").path))
    }

    func testRemovingFromOtherAccountsPrunesTheirHooks() throws {
        let home = try makeHome()
        let personal = try personalAccount(in: home)
        HookInstaller.migrateOtherAccounts(home: home, excluding: home.appendingPathComponent(".claude"))

        HookInstaller.removeFromOtherAccounts(home: home, excluding: home.appendingPathComponent(".claude"))

        XCTAssertFalse(HookInstaller.isHookInstalled(in: try Data(contentsOf: personal.appendingPathComponent("settings.json"))))
    }

    func testAddingAccountHooksSetsTheSharedCommand() throws {
        let home = try makeHome()
        let work = home.appendingPathComponent(".claude-work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        XCTAssertTrue(HookInstaller.addAccountHooks(to: work))

        XCTAssertEqual(
            try stopCommands(in: Data(contentsOf: work.appendingPathComponent("settings.json"))),
            [HookInstaller.hookCommand]
        )
    }

    func testAddingAccountHooksLeavesTheShimAtItsOldScriptPath() throws {
        let home = try makeHome()
        let work = home.appendingPathComponent(".claude-work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        HookInstaller.addAccountHooks(to: work)

        XCTAssertEqual(
            try String(contentsOf: work.appendingPathComponent("hooks/notchi-hook.sh"), encoding: .utf8),
            HookInstaller.legacyScriptShim
        )
    }

    func testRemovingAccountHooksLeavesItsOtherSettings() throws {
        let home = try makeHome()
        let personal = try personalAccount(in: home)
        HookInstaller.addAccountHooks(to: personal)

        HookInstaller.removeHooks(fromAccount: personal)

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: personal.appendingPathComponent("settings.json"))) as? [String: Any]
        )
        XCTAssertEqual(json["theme"] as? String, "dark")
    }

    func testRemovingAccountHooksTakesNotchiOutOfItsSettings() throws {
        let home = try makeHome()
        let personal = try personalAccount(in: home)
        HookInstaller.addAccountHooks(to: personal)

        HookInstaller.removeHooks(fromAccount: personal)

        XCTAssertFalse(HookInstaller.isHookInstalled(inAccount: personal))
    }

    func testSymlinkedClaudeAccountDirectoryIsMigrated() throws {
        let home = try makeHome()
        let dotfilesAccount = home.appendingPathComponent("dotfiles/claude-personal", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfilesAccount, withIntermediateDirectories: true)
        try settings(withCommand: Self.legacyAccountRelativeCommand)
            .write(to: dotfilesAccount.appendingPathComponent("settings.json"))
        let linked = home.appendingPathComponent(".claude-personal")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: dotfilesAccount)

        let found = HookInstaller.otherAccountSettingsURLs(home: home, excluding: home.appendingPathComponent(".claude"))

        XCTAssertEqual(found.map(\.path), [linked.appendingPathComponent("settings.json").path])
    }

    func testSettingsWriteKeepsFilePermissions() throws {
        let privateFilePermissions = 0o600
        let home = try makeHome()
        let url = home.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: privateFilePermissions], ofItemAtPath: url.path)

        try HookInstaller.writeSettings(Data("{\"a\":1}".utf8), to: url)

        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, privateFilePermissions)
    }

    func testSettingsWriteThroughASymlinkUpdatesTheTarget() throws {
        let home = try makeHome()
        let target = home.appendingPathComponent("dotfiles-settings.json")
        let link = home.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try HookInstaller.writeSettings(Data("{\"a\":1}".utf8), to: link)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "{\"a\":1}")
    }

    func testUnreadableSettingsAreNotReplacedWithOnlyNotchiHooks() {
        let settingsWithComment = Data("""
            {
              // the user's own note
              "theme": "dark"
            }
            """.utf8)

        XCTAssertNil(HookInstaller.upsertHookSettings(from: settingsWithComment, command: HookInstaller.hookCommand))
    }

    func testSerializedSettingsDoNotEscapeSlashes() throws {
        let data = try XCTUnwrap(HookInstaller.upsertHookSettings(from: nil, command: HookInstaller.hookCommand))

        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(#"\/"#))
    }
}
