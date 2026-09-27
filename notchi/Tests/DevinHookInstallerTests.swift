import Foundation
import XCTest
@testable import notchi

final class DevinHookInstallerTests: XCTestCase {
    private static let command = "/tmp/devin/hooks/notchi-devin-hook.sh"
    private static let legacyClaudeCommand = "/Users/me/.claude/hooks/notchi-hook.sh"
    private static let foreignCommand = "/usr/local/bin/audit-hook.sh"
    private static let devinSupportedEvents: Set<String> = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop",
    ]
    private static let ownerOnlyPermissions: Int16 = 0o600

    func testDevinDirectoryExistsReturnsFalseWhenConfigDirectoryIsMissing() {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        XCTAssertFalse(DevinHookInstaller.devinDirectoryExists(directoryURL: tempRoot))
    }

    func testUpsertConfigRegistersExactlyTheEventsDevinSupports() throws {
        let data = DevinHookInstaller.upsertConfig(from: nil, command: Self.command)

        let hooks = try Self.hooks(in: data)
        XCTAssertEqual(Set(hooks.keys), Self.devinSupportedEvents)
        for event in Self.devinSupportedEvents {
            XCTAssertEqual(try Self.commands(in: hooks, event: event), [Self.command], event)
        }
    }

    func testUpsertConfigPreservesOtherSettingsAndForeignHooks() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "model": "swe-1.6",
            "hooks": [
                "PreToolUse": [
                    ["matcher": "exec", "hooks": [["type": "command", "command": Self.foreignCommand]]],
                ],
            ],
        ])

        let updated = try XCTUnwrap(DevinHookInstaller.upsertConfig(from: existing, command: Self.command))

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: updated) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["model"] as? String, "swe-1.6")
        let hooks = try Self.hooks(in: updated)
        XCTAssertEqual(try Self.commands(in: hooks, event: "PreToolUse"), [Self.foreignCommand, Self.command])
    }

    func testUpsertConfigReplacesLegacyClaudeHookEntries() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": Self.legacyClaudeCommand]]],
                ],
                "UserPromptSubmit": [
                    ["hooks": [
                        ["type": "command", "command": Self.foreignCommand],
                        ["type": "command", "command": Self.legacyClaudeCommand],
                    ]],
                ],
            ],
        ])

        let updated = DevinHookInstaller.upsertConfig(from: existing, command: Self.command)

        let hooks = try Self.hooks(in: updated)
        XCTAssertEqual(try Self.commands(in: hooks, event: "Stop"), [Self.command])
        XCTAssertEqual(try Self.commands(in: hooks, event: "UserPromptSubmit"), [Self.foreignCommand, Self.command])
    }

    func testUpsertConfigKeepsHooksWhoseFileNameOnlyContainsANotchiScriptName() throws {
        let wrappers = ["/usr/local/bin/my-notchi-hook.sh", "/opt/hooks/wrap-notchi-devin-hook.sh"]
        let existing = try JSONSerialization.data(withJSONObject: [
            "hooks": ["Stop": [["hooks": wrappers.map { ["type": "command", "command": $0] }]]],
        ])

        let updated = DevinHookInstaller.upsertConfig(from: existing, command: Self.command)
        let removed = DevinHookInstaller.removeManagedHooks(from: updated)

        XCTAssertEqual(try Self.commands(in: Self.hooks(in: updated), event: "Stop"), wrappers + [Self.command])
        XCTAssertEqual(try Self.commands(in: Self.hooks(in: removed), event: "Stop"), wrappers)
    }

    func testUpsertConfigReplacesQuotedLegacyClaudeCommand() throws {
        let quotedLegacy = #""${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/notchi-hook.sh""#
        let existing = try JSONSerialization.data(withJSONObject: [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": quotedLegacy]]]]],
        ])

        let updated = DevinHookInstaller.upsertConfig(from: existing, command: Self.command)

        XCTAssertEqual(try Self.commands(in: Self.hooks(in: updated), event: "Stop"), [Self.command])
    }

    func testIsHookInstalledRecognisesAScriptPathContainingSpaces() {
        let data = DevinHookInstaller.upsertConfig(from: nil, command: "/Users/Jo Doe/.config/devin/hooks/notchi-devin-hook.sh")

        XCTAssertTrue(DevinHookInstaller.isHookInstalled(in: data))
    }

    func testUpsertConfigIsIdempotent() throws {
        let first = try XCTUnwrap(DevinHookInstaller.upsertConfig(from: nil, command: Self.command))
        let second = try XCTUnwrap(DevinHookInstaller.upsertConfig(from: first, command: Self.command))

        XCTAssertEqual(second, first)
    }

    func testUpsertConfigRefusesToReplaceAConfigItCannotParse() {
        let unparseable = Data(#"{ "model": "swe-1.6", // comment"#.utf8)

        XCTAssertNil(DevinHookInstaller.upsertConfig(from: unparseable, command: Self.command))
    }

    func testUpsertConfigTreatsAnEmptyFileAsEmptyConfig() throws {
        let hooks = try Self.hooks(in: DevinHookInstaller.upsertConfig(from: Data(), command: Self.command))

        XCTAssertEqual(Set(hooks.keys), Self.devinSupportedEvents)
    }

    func testIsHookInstalledIsFalseForLegacyClaudeHookOnly() throws {
        let legacyOnly = try JSONSerialization.data(withJSONObject: [
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": Self.legacyClaudeCommand]]]],
            ],
        ])

        XCTAssertFalse(DevinHookInstaller.isHookInstalled(in: legacyOnly))
    }

    func testIsHookInstalledIsFalseWhenAnySupportedEventIsMissing() throws {
        var hooks = try Self.hooks(in: DevinHookInstaller.upsertConfig(from: nil, command: Self.command))
        hooks.removeValue(forKey: "PostToolUse")
        let partial = try JSONSerialization.data(withJSONObject: ["hooks": hooks])

        XCTAssertFalse(DevinHookInstaller.isHookInstalled(in: partial))
    }

    func testIsHookInstalledIsTrueAfterUpsert() {
        let data = DevinHookInstaller.upsertConfig(from: nil, command: Self.command)

        XCTAssertTrue(DevinHookInstaller.isHookInstalled(in: data))
    }

    func testRemoveManagedHooksKeepsForeignHooksAndOtherSettings() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "hooks": [
                "PreToolUse": [
                    ["hooks": [["type": "command", "command": Self.foreignCommand]]],
                ],
            ],
        ])
        let installed = try XCTUnwrap(DevinHookInstaller.upsertConfig(from: existing, command: Self.command))

        let removed = try XCTUnwrap(DevinHookInstaller.removeManagedHooks(from: installed))

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: removed) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        let hooks = try Self.hooks(in: removed)
        XCTAssertEqual(Set(hooks.keys), ["PreToolUse"])
        XCTAssertEqual(try Self.commands(in: hooks, event: "PreToolUse"), [Self.foreignCommand])
    }

    func testRemoveManagedHooksDropsHooksKeyWhenOnlyNotchiHooksRemain() throws {
        let installed = DevinHookInstaller.upsertConfig(from: nil, command: Self.command)

        let removed = try XCTUnwrap(DevinHookInstaller.removeManagedHooks(from: installed))

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: removed) as? [String: Any])
        XCTAssertNil(json["hooks"])
    }

    func testWriteConfigKeepsExistingOwnerOnlyPermissions() throws {
        let url = try Self.makeTemporaryFile(contents: Data("{}".utf8), permissions: Self.ownerOnlyPermissions)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try DevinHookInstaller.writeConfig(Data(#"{"hooks":{}}"#.utf8), to: url)

        XCTAssertEqual(try Self.permissions(at: url), Self.ownerOnlyPermissions)
        XCTAssertEqual(try Data(contentsOf: url), Data(#"{"hooks":{}}"#.utf8))
    }

    func testWriteConfigKeepsASymlinkedConfigLinked() throws {
        let target = try Self.makeTemporaryFile(contents: Data("{}".utf8), permissions: Self.ownerOnlyPermissions)
        let linkDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: linkDirectory)
        }
        let link = linkDirectory.appendingPathComponent("config.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try DevinHookInstaller.writeConfig(Data(#"{"hooks":{}}"#.utf8), to: link)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), Data(#"{"hooks":{}}"#.utf8))
        XCTAssertEqual(try Self.permissions(at: target), Self.ownerOnlyPermissions)
    }

    func testWriteConfigCreatesNewFileAsOwnerOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")

        try DevinHookInstaller.writeConfig(Data("{}".utf8), to: url)

        XCTAssertEqual(try Self.permissions(at: url), Self.ownerOnlyPermissions)
    }

    // MARK: - Helpers

    private static func hooks(in data: Data?) throws -> [String: Any] {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
        return try XCTUnwrap(json["hooks"] as? [String: Any])
    }

    private static func commands(in hooks: [String: Any], event: String) throws -> [String] {
        let groups = try XCTUnwrap(hooks[event] as? [[String: Any]], event)
        return groups
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
    }

    private static func makeTemporaryFile(contents: Data, permissions: Int16) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")
        try contents.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        return url
    }

    private static func permissions(at url: URL) throws -> Int16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).int16Value
    }
}
