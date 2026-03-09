import SwiftUI

/// Drives pac-man style walk for the header sprite using x-offset from home.
///
/// The sprite lives inside the NotchShape clipShape, so it naturally
/// disappears when it walks past the edges of the black area.
///
/// Cycle:
/// 1. At RIGHT home (offset 0). Walk right → clipped at right edge → teleport to left exit → walk right → arrive LEFT home
/// 2. Pause
/// 3. At LEFT home. Walk left → clipped at left edge → teleport to right exit → walk left → arrive RIGHT home
/// 4. Pause, repeat
@MainActor
@Observable
final class WalkAnimator {
    /// X offset in points added to the sprite's home position
    private(set) var xOffset: CGFloat = 0

    /// Whether the sprite is actively mid-walk
    private(set) var isWalking: Bool = false

    private var walkTimer: Timer?
    private var animationTimer: Timer?
    private var hasWrapped: Bool = false
    private var walkingRight: Bool = true

    // Offsets relative to right home (0)
    private var leftHomeOffset: CGFloat = -200  // left side of notch
    private var rightExitOffset: CGFloat = 60   // off right edge of black area
    private var leftExitOffset: CGFloat = -260  // off left edge of black area

    private var walkSpeed: CGFloat = 40 // points per second

    func configure(notchWidth: CGFloat, sideWidth: CGFloat) {
        // Left home: mirror of right home, same distance from left edge
        leftHomeOffset = -(notchWidth + 22)

        // Right exit: far enough right to be fully clipped
        // Sprite is sideWidth/2 - 1 from the right edge, plus buffer
        rightExitOffset = sideWidth + 32

        // Left exit: far enough left to be fully clipped
        // Sprite is notchWidth + 23 from the left edge, plus buffer
        leftExitOffset = leftHomeOffset - 50
    }

    func start(state: NotchiState) {
        stop()
        guard state.canWalk else { return }

        let delay = Double.random(in: state.walkFrequencyRange)
        walkTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.beginWalk(state: state)
            }
        }
    }

    func stop() {
        walkTimer?.invalidate()
        walkTimer = nil
        animationTimer?.invalidate()
        animationTimer = nil
        isWalking = false
        hasWrapped = false
    }

    func returnHome() {
        stop()
        xOffset = 0
        walkingRight = true
    }

    private func beginWalk(state: NotchiState) {
        isWalking = true
        hasWrapped = false

        let stepInterval: TimeInterval = 1.0 / 30.0
        let step = walkSpeed * CGFloat(stepInterval)

        let targetOffset = walkingRight ? leftHomeOffset : CGFloat(0)

        animationTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if self.walkingRight {
                    self.xOffset += step

                    // Walked off the right edge → teleport to left exit
                    if !self.hasWrapped && self.xOffset > self.rightExitOffset {
                        self.xOffset = self.leftExitOffset
                        self.hasWrapped = true
                    }

                    // After wrap, arrived at left home
                    if self.hasWrapped && self.xOffset >= targetOffset {
                        self.finishWalk(at: targetOffset, nextDirection: false, state: state)
                    }
                } else {
                    self.xOffset -= step

                    // Walked off the left edge → teleport to right exit
                    if !self.hasWrapped && self.xOffset < self.leftExitOffset {
                        self.xOffset = self.rightExitOffset
                        self.hasWrapped = true
                    }

                    // After wrap, arrived at right home
                    if self.hasWrapped && self.xOffset <= targetOffset {
                        self.finishWalk(at: targetOffset, nextDirection: true, state: state)
                    }
                }
            }
        }
    }

    private func finishWalk(at offset: CGFloat, nextDirection: Bool, state: NotchiState) {
        xOffset = offset
        animationTimer?.invalidate()
        animationTimer = nil
        isWalking = false
        hasWrapped = false
        walkingRight = nextDirection
        start(state: state)
    }
}
