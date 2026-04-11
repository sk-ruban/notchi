import CoreGraphics

enum SpriteHandoffVisuals {
    private static let interactionOpacityThreshold = 0.5
    private static let sourcePhaseEnd: CGFloat = 0.35
    private static let destinationPhaseStart: CGFloat = sourcePhaseEnd
    private static let destinationPhaseDuration: CGFloat = 0.35

    private static func clampedUnitProgress(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }

    private static func sourceProgress(for progress: CGFloat) -> CGFloat {
        clampedUnitProgress(progress / sourcePhaseEnd)
    }

    private static func destinationProgress(for progress: CGFloat) -> CGFloat {
        clampedUnitProgress((progress - destinationPhaseStart) / destinationPhaseDuration)
    }

    static func blur(for progress: CGFloat, isSource: Bool) -> CGFloat {
        isSource ? sourceBlur(for: progress) : destinationBlur(for: progress)
    }

    static func opacity(for progress: CGFloat, isSource: Bool) -> Double {
        isSource ? sourceOpacity(for: progress) : destinationOpacity(for: progress)
    }

    static func sourceBlur(for progress: CGFloat) -> CGFloat {
        let normalized = sourceProgress(for: progress)
        return normalized * 5
    }

    static func destinationBlur(for progress: CGFloat) -> CGFloat {
        let normalized = destinationProgress(for: progress)
        return (1 - normalized) * 5
    }

    static func sourceOpacity(for progress: CGFloat) -> Double {
        let normalized = sourceProgress(for: progress)
        return Double(1 - normalized)
    }

    static func destinationOpacity(for progress: CGFloat) -> Double {
        let normalized = destinationProgress(for: progress)
        return Double(normalized)
    }

    static func isInteractive(for progress: CGFloat, isCollapsing: Bool) -> Bool {
        let opacity = opacity(for: progress, isSource: isCollapsing)
        return opacity >= interactionOpacityThreshold
    }
}
