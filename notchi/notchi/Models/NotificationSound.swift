import Foundation

enum NotificationSound: String, CaseIterable, Codable {
    case none
    case pop
    case ping
    case tink
    case glass
    case blow
    case bottle
    case frog
    case funk
    case hero
    case morse
    case purr
    case sosumi
    case submarine
    case basso

    var soundName: String? {
        switch self {
        case .none: return nil
        case .pop: return "Pop"
        case .ping: return "Ping"
        case .tink: return "Tink"
        case .glass: return "Glass"
        case .blow: return "Blow"
        case .bottle: return "Bottle"
        case .frog: return "Frog"
        case .funk: return "Funk"
        case .hero: return "Hero"
        case .morse: return "Morse"
        case .purr: return "Purr"
        case .sosumi: return "Sosumi"
        case .submarine: return "Submarine"
        case .basso: return "Basso"
        }
    }

    var displayName: String {
        switch self {
        case .none: return String(localized: "None")
        case .pop: return "Pop"
        case .ping: return "Ping"
        case .tink: return "Tink"
        case .glass: return "Glass"
        case .blow: return "Blow"
        case .bottle: return "Bottle"
        case .frog: return "Frog"
        case .funk: return "Funk"
        case .hero: return "Hero"
        case .morse: return "Morse"
        case .purr: return "Purr"
        case .sosumi: return "Sosumi"
        case .submarine: return "Submarine"
        case .basso: return "Basso"
        }
    }

    static var displayOrder: [NotificationSound] {
        [.none] + allCases
            .filter { $0 != .none }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

struct CustomNotificationSound: Codable, Identifiable, Hashable {
    let id: UUID
    var displayName: String
    let fileName: String
    let createdAt: Date
}

enum NotificationSoundSelection: Codable, Hashable {
    case system(NotificationSound)
    case custom(UUID)

    private enum CodingKeys: String, CodingKey {
        case type
        case sound
        case id
    }

    private enum SelectionType: String, Codable {
        case system
        case custom
    }

    static let defaultValue: NotificationSoundSelection = .system(.purr)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(SelectionType.self, forKey: .type)

        switch type {
        case .system:
            self = .system(try container.decode(NotificationSound.self, forKey: .sound))
        case .custom:
            self = .custom(try container.decode(UUID.self, forKey: .id))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .system(let sound):
            try container.encode(SelectionType.system, forKey: .type)
            try container.encode(sound, forKey: .sound)
        case .custom(let id):
            try container.encode(SelectionType.custom, forKey: .type)
            try container.encode(id, forKey: .id)
        }
    }

    func displayName(customSounds: [CustomNotificationSound]) -> String {
        switch self {
        case .system(let sound):
            sound.displayName
        case .custom(let id):
            customSounds.first { $0.id == id }?.displayName ?? "Custom Sound"
        }
    }

    func fallbackIfDeletingCustomSound(id deletedID: UUID) -> NotificationSoundSelection {
        self == .custom(deletedID) ? .defaultValue : self
    }
}
