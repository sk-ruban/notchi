import AppKit
import Carbon.HIToolbox
import XCTest
@testable import notchi

@MainActor
final class GlobalShortcutServiceTests: XCTestCase {
    func testDefaultTogglePanelShortcutUsesCommandOptionN() {
        XCTAssertEqual(GlobalShortcut.defaultTogglePanel.keyCode, UInt32(kVK_ANSI_N))
        XCTAssertEqual(GlobalShortcut.defaultTogglePanel.modifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(GlobalShortcut.defaultTogglePanel.displayName, "⌥⌘N")
    }

    func testShortcutRawValueRoundTrips() throws {
        let shortcut = GlobalShortcut(keyCode: UInt32(kVK_ANSI_Period), modifiers: UInt32(cmdKey | shiftKey))
        let decoded = try XCTUnwrap(GlobalShortcut(rawValue: shortcut.rawValue))

        XCTAssertEqual(decoded, shortcut)
        XCTAssertEqual(decoded.displayName, "⇧⌘.")
    }

    func testSpecialKeysShowTheirMacOSGlyphs() {
        let expectedNames: [(keyCode: Int, name: String)] = [
            (kVK_Return, "⌥⌘↩"), (kVK_Tab, "⌥⌘⇥"), (kVK_Delete, "⌥⌘⌫"), (kVK_Escape, "⌥⌘⎋"),
        ]

        for (keyCode, name) in expectedNames {
            let shortcut = GlobalShortcut(keyCode: UInt32(keyCode), modifiers: UInt32(cmdKey | optionKey))

            XCTAssertEqual(shortcut.displayName, name)
        }
    }

    func testShortcutTranscribesKeyEventWithPrimaryModifier() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "p",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_P)
        ))

        let shortcut = try XCTUnwrap(GlobalShortcut(event: event))

        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_P))
        XCTAssertEqual(shortcut.modifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(shortcut.displayName, "⌥⌘P")
    }

    func testShortcutRecordingPreviewShowsHeldModifiers() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [.command, .option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: UInt16(kVK_Option)
        ))

        XCTAssertEqual(GlobalShortcut.recordingDisplayName(for: event), "⌥⌘")
    }

    func testShortcutRecordingPreviewShowsFullChord() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_N)
        ))

        XCTAssertEqual(GlobalShortcut.recordingDisplayName(for: event), "⌥⇧⌘N")
    }

    func testShortcutRejectsBareKeyEvent() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_N)
        ))

        XCTAssertNil(GlobalShortcut(event: event))
    }

    func testTogglePanelHotKeyIDMatchesOnlyNotchiShortcut() {
        XCTAssertTrue(
            GlobalShortcutService.isTogglePanelHotKey(
                signature: GlobalShortcutService.togglePanelHotKeyID.signature,
                id: GlobalShortcutService.togglePanelHotKeyID.id
            )
        )
        XCTAssertFalse(
            GlobalShortcutService.isTogglePanelHotKey(
                signature: GlobalShortcutService.togglePanelHotKeyID.signature,
                id: GlobalShortcutService.togglePanelHotKeyID.id + 1
            )
        )
    }
}
