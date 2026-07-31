import AppKit
import Carbon.HIToolbox
import Foundation

nonisolated struct GlobalShortcut: Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let defaultTogglePanel = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_N),
        modifiers: UInt32(cmdKey | optionKey)
    )

    static let defaultDictationPushToTalk = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(cmdKey | optionKey | shiftKey)
    )

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: "|")
        guard parts.count == 2,
              let keyCode = UInt32(parts[0]),
              let modifiers = UInt32(parts[1]) else {
            return nil
        }

        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let keyCode = UInt32(event.keyCode)
        guard !Self.modifierKeyCodes.contains(keyCode) else { return nil }

        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        guard Self.hasPrimaryModifier(modifiers) else { return nil }

        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var rawValue: String {
        "\(keyCode)|\(modifiers)"
    }

    var displayName: String {
        Self.displayName(modifiers: modifiers, keyCode: keyCode)
    }

    private nonisolated static let modifierKeyCodes: Set<UInt32> = [
        UInt32(kVK_Command),
        UInt32(kVK_RightCommand),
        UInt32(kVK_Option),
        UInt32(kVK_RightOption),
        UInt32(kVK_Control),
        UInt32(kVK_RightControl),
        UInt32(kVK_Shift),
        UInt32(kVK_RightShift),
        UInt32(kVK_Function)
    ]

    nonisolated static func recordingDisplayName(for event: NSEvent) -> String? {
        let keyCode = UInt32(event.keyCode)
        let modifiers = carbonModifiers(from: event.modifierFlags)
        let displayName = displayName(
            modifiers: modifiers,
            keyCode: modifierKeyCodes.contains(keyCode) ? nil : keyCode
        )
        return displayName.isEmpty ? nil : displayName
    }

    // Modifier glyph order follows the macOS HIG: Control, Option, Shift, Command.
    nonisolated static func displayName(modifiers: UInt32, keyCode: UInt32? = nil) -> String {
        var symbols: [String] = []
        if modifiers & UInt32(controlKey) != 0 { symbols.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { symbols.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { symbols.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { symbols.append("⌘") }
        if let keyCode {
            symbols.append(keyDisplayName(for: keyCode))
        }
        return symbols.joined()
    }

    nonisolated static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    private nonisolated static func hasPrimaryModifier(_ modifiers: UInt32) -> Bool {
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    private nonisolated static func keyDisplayName(for keyCode: UInt32) -> String {
        keyDisplayNames[keyCode] ?? "Key \(keyCode)"
    }

    private nonisolated static let keyDisplayNames: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A",
        UInt32(kVK_ANSI_B): "B",
        UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E",
        UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G",
        UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J",
        UInt32(kVK_ANSI_K): "K",
        UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M",
        UInt32(kVK_ANSI_N): "N",
        UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q",
        UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S",
        UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V",
        UInt32(kVK_ANSI_W): "W",
        UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y",
        UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0",
        UInt32(kVK_ANSI_1): "1",
        UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4",
        UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6",
        UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_Period): ".",
        UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_ANSI_Semicolon): ";",
        UInt32(kVK_ANSI_Quote): "'",
        UInt32(kVK_ANSI_LeftBracket): "[",
        UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Backslash): "\\",
        UInt32(kVK_ANSI_Grave): "`",
        UInt32(kVK_ANSI_Minus): "-",
        UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Delete): "Delete",
        UInt32(kVK_Escape): "Esc"
    ]
}
