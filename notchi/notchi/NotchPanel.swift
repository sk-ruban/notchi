import AppKit

/// A borderless, transparent panel positioned at the MacBook notch area
final class NotchPanel: NSPanel {
    init(frame: CGRect, hasNotch: Bool = true) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true

        if hasNotch {
            level = .mainMenu + 3
            collectionBehavior = [
                .fullScreenAuxiliary,
                .stationary,
                .canJoinAllSpaces,
                .ignoresCycle
            ]
        } else {
            level = .statusBar
            collectionBehavior = [
                .fullScreenAuxiliary,
                .canJoinAllSpaces,
                .ignoresCycle
            ]
        }

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false

        // Hit testing is handled by NotchHitTestView (the content view wrapper)
        // which selectively passes through events based on notch/panel rect
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            NotificationCenter.default.post(name: .notchiShouldCollapse, object: nil)
        }
    }
}
