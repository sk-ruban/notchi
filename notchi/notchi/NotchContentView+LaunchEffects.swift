import SwiftUI

extension NotchContentView {
    enum LaunchWaveTiming {
        static let startDelay = 1.0
        static let preparationDuration = 0.45
        static let spriteScale: CGFloat = 1.2
        static let horizontalOffset: CGFloat = 5
    }

    struct LaunchWave: Equatable {
        let state: NotchiState
        let startedAt: Date
    }

    @MainActor private static var hasPlayedLaunchGlow = false
    @MainActor private static var hasPlayedLaunchWave = false

    var launchWavePreparationAnimation: Animation {
        .easeInOut(duration: LaunchWaveTiming.preparationDuration)
    }

    func startLaunchGlow() {
        guard !Self.hasPlayedLaunchGlow else { return }
        Self.hasPlayedLaunchGlow = true

        guard !accessibilityReduceMotion else { return }

        let duration = LaunchIridescentGlowTiming.duration(reduceMotion: accessibilityReduceMotion)
        launchGlowProgress = 0
        launchGlowVisible = true

        Task {
            // Commit the hidden 0 state before animating so the glow blooms from nothing.
            await Task.yield()
            withAnimation(.linear(duration: duration)) {
                launchGlowProgress = 1
            }

            try? await Task.sleep(for: .seconds(duration))
            launchGlowVisible = false
        }
    }

    func startLaunchWave() async {
        guard !Self.hasPlayedLaunchWave else { return }

        let provider = AppSettings.lastUsedAgentProvider
        launchSpriteFamily = provider.spriteFamily

        isLaunchWavePreparing = true

        try? await Task.sleep(for: .seconds(LaunchWaveTiming.startDelay))

        guard !Task.isCancelled, !Self.hasPlayedLaunchWave else {
            isLaunchWavePreparing = false
            return
        }

        Self.hasPlayedLaunchWave = true
        isLaunchWavePreparing = false
        launchWave = LaunchWave(
            state: NotchiState(task: .waving, spriteFamily: provider.spriteFamily),
            startedAt: Date()
        )

        try? await Task.sleep(for: .seconds(NotchiState.launchWaveDuration))

        guard !Task.isCancelled else {
            launchWave = nil
            return
        }

        withAnimation(launchWavePreparationAnimation) {
            launchWave = nil
        }
    }
}
