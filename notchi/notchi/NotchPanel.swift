import AppKit

/// A borderless, transparent panel positioned at the MacBook notch area
final class NotchPanel: NSPanel {
    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .mainMenu + 3
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle
        ]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        ignoresMouseEvents = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
