import AppKit
import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "SoundService")

@MainActor
@Observable
final class SoundService {
    static let shared = SoundService()

    private static let cooldown: TimeInterval = 2.0
    @ObservationIgnored
    private var lastSoundTimes: [ProviderSessionKey: Date] = [:]
    @ObservationIgnored
    private var activeCustomPlayers: [UUID: AVAudioPlayer] = [:]

    private init() {}

    func playNotificationSound(sessionKey: ProviderSessionKey, isInteractive: Bool) {
        guard isInteractive else {
            return
        }

        let selection = AppSettings.notificationSoundSelection
        guard selection != .system(.none) else {
            return
        }

        if TerminalFocusDetector.isTerminalFocused() {
            return
        }

        let now = Date()
        if let lastPlayed = lastSoundTimes[sessionKey],
           now.timeIntervalSince(lastPlayed) < Self.cooldown {
            return
        }

        lastSoundTimes[sessionKey] = now
        playSound(selection)
    }

    func clearCooldown(for sessionKey: ProviderSessionKey) {
        lastSoundTimes.removeValue(forKey: sessionKey)
    }

    func previewSound(_ selection: NotificationSoundSelection) {
        playSound(selection)
    }

    private func playSound(_ selection: NotificationSoundSelection) {
        switch selection {
        case .system(let sound):
            guard let soundName = sound.soundName else { return }
            playSystemSound(named: soundName)
        case .custom(let id):
            guard let customSound = AppSettings.customNotificationSounds.first(where: { $0.id == id }) else {
                logger.warning("Custom sound not found: \(id.uuidString, privacy: .public)")
                return
            }
            let url = AppSettings.customNotificationSoundURL(for: customSound)
            playCustomSound(url: url)
        }
    }

    private func playSystemSound(named soundName: String) {
        guard let nsSound = NSSound(named: NSSound.Name(soundName)) else {
            logger.warning("Sound not found: \(soundName, privacy: .public)")
            return
        }
        nsSound.play()
    }

    private func playCustomSound(url: URL) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            let playbackID = UUID()
            activeCustomPlayers[playbackID] = player
            player.play()

            let nanoseconds = UInt64((max(player.duration, 0.1) + 0.5) * 1_000_000_000)
            Task { [weak self, weak player] in
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard let self,
                      let player,
                      self.activeCustomPlayers[playbackID] === player else {
                    return
                }
                self.activeCustomPlayers[playbackID] = nil
            }
        } catch {
            logger.warning("Failed to play custom sound: \(error.localizedDescription, privacy: .public)")
        }
    }
}
