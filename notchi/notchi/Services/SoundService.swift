import AppKit
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "SoundService")

@MainActor
@Observable
final class SoundService {
    static let shared = SoundService()

    private init() {}

    func playNotificationSound() {
        let sound = AppSettings.notificationSound
        guard let soundName = sound.soundName else {
            logger.debug("Notification sound disabled")
            return
        }

        if TerminalFocusDetector.isTerminalFocused() {
            logger.debug("Terminal focused, skipping notification sound")
            return
        }

        playSound(named: soundName)
    }

    func playStartupSound() {
        guard !AppSettings.isMuted else { return }
        if TerminalFocusDetector.isTerminalFocused() { return }

        guard let url = Bundle.main.url(forResource: "startup", withExtension: "wav"),
              let sound = NSSound(contentsOf: url, byReference: true) else {
            logger.warning("Startup sound not found in bundle")
            return
        }
        sound.play()
        logger.debug("Playing startup sound")
    }

    func previewSound(_ sound: NotificationSound) {
        guard let soundName = sound.soundName else { return }
        playSound(named: soundName)
    }

    private func playSound(named soundName: String) {
        guard let nsSound = NSSound(named: NSSound.Name(soundName)) else {
            logger.warning("Sound not found: \(soundName, privacy: .public)")
            return
        }
        nsSound.play()
        logger.debug("Playing sound: \(soundName, privacy: .public)")
    }
}
