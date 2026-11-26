import AppKit
import Observation
import SwiftUI

/// Tracks whether anyone can see the panel, so its looping animations can pause while the
/// display sleeps or the panel window is fully occluded.
@MainActor
@Observable
final class AnimationVisibility {
    static let shared = AnimationVisibility()

    private(set) var isDisplayAsleep = false
    private(set) var isPanelOccluded = false

    var isPaused: Bool { isDisplayAsleep || isPanelOccluded }

    func start(
        observing panel: NSWindow,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        notificationCenter: NotificationCenter = .default
    ) {
        updateOcclusion(of: panel)

        workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isDisplayAsleep = true }
        }
        workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isDisplayAsleep = false }
        }
        notificationCenter.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let panel else { return }
                self?.updateOcclusion(of: panel)
            }
        }
    }

    private func updateOcclusion(of panel: NSWindow) {
        isPanelOccluded = !panel.occlusionState.contains(.visible)
    }
}

private struct AnimationPausedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while looping animations should hold still because nobody can see them.
    var isAnimationPaused: Bool {
        get { self[AnimationPausedKey.self] }
        set { self[AnimationPausedKey.self] = newValue }
    }
}
