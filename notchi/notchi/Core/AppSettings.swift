import Foundation

struct AppSettings {
    private static let notificationSoundKey = "notificationSound"
    private static let isMutedKey = "isMuted"
    private static let previousSoundKey = "previousNotificationSound"
    private static let isUsageEnabledKey = "isUsageEnabled"
    private static let claudeUsageRecoverySnapshotKey = "claudeUsageRecoverySnapshot"
    private static let remoteTCPEnabledKey = "remoteTCPEnabled"
    private static let remoteTCPPortKey = "remoteTCPPort"

    static let defaultTCPPort: UInt16 = 9876

    static var isUsageEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: isUsageEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: isUsageEnabledKey) }
    }

    static var claudeUsageRecoverySnapshot: ClaudeUsageRecoverySnapshot? {
        get {
            guard let data = UserDefaults.standard.data(forKey: claudeUsageRecoverySnapshotKey) else {
                return nil
            }
            return try? JSONDecoder().decode(ClaudeUsageRecoverySnapshot.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: claudeUsageRecoverySnapshotKey)
            } else {
                UserDefaults.standard.removeObject(forKey: claudeUsageRecoverySnapshotKey)
            }
        }
    }

    static var anthropicApiKey: String? {
        get { KeychainManager.getAnthropicApiKey() }
        set { KeychainManager.setAnthropicApiKey(newValue) }
    }

    static var isRemoteTCPEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: remoteTCPEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: remoteTCPEnabledKey) }
    }

    static var remoteTCPPort: UInt16 {
        get {
            let val = UserDefaults.standard.integer(forKey: remoteTCPPortKey)
            return (val > 0 && val <= Int(UInt16.max)) ? UInt16(val) : defaultTCPPort
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: remoteTCPPortKey) }
    }

    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: notificationSoundKey),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .purr
            }
            return sound
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: notificationSoundKey)
        }
    }

    static var isMuted: Bool {
        get { UserDefaults.standard.bool(forKey: isMutedKey) }
        set { UserDefaults.standard.set(newValue, forKey: isMutedKey) }
    }

    static func toggleMute() {
        if isMuted {
            notificationSound = previousSound ?? .purr
            isMuted = false
        } else {
            previousSound = notificationSound
            notificationSound = .none
            isMuted = true
        }
    }

    private static var previousSound: NotificationSound? {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: previousSoundKey) else {
                return nil
            }
            return NotificationSound(rawValue: rawValue)
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue, forKey: previousSoundKey)
        }
    }
}
