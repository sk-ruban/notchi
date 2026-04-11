import SwiftUI

/// Drives the collapsed-header sprite walk by offsetting it from its home position.
///
/// The sprite stays inside the existing notch clip shape, so it naturally disappears
/// at one edge and reappears from the other as it crosses the header.
@MainActor
@Observable
final class WalkAnimator {
    private(set) var xOffset: CGFloat = 0
    private(set) var isWalking = false

    private var walkTimer: Timer?
    private var animationTimer: Timer?
    private var hasWrapped = false
    private var walkingRight = true

    private var leftHomeOffset: CGFloat = -200
    private var rightExitOffset: CGFloat = 60
    private var leftExitOffset: CGFloat = -260
    private let walkSpeed: CGFloat = 40

    func configure(notchWidth: CGFloat, sideWidth: CGFloat) {
        leftHomeOffset = -(notchWidth + 22)
        rightExitOffset = sideWidth + 32
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
        let targetOffset = walkingRight ? leftHomeOffset : 0

        animationTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if self.walkingRight {
                    self.xOffset += step

                    if !self.hasWrapped && self.xOffset > self.rightExitOffset {
                        self.xOffset = self.leftExitOffset
                        self.hasWrapped = true
                    }

                    if self.hasWrapped && self.xOffset >= targetOffset {
                        self.finishWalk(at: targetOffset, nextDirection: false, state: state)
                    }
                } else {
                    self.xOffset -= step

                    if !self.hasWrapped && self.xOffset < self.leftExitOffset {
                        self.xOffset = self.rightExitOffset
                        self.hasWrapped = true
                    }

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
