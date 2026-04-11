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
}
