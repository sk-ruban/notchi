import AppKit

enum NotchiTask: String, CaseIterable {
    case idle, working, sleeping, compacting, waiting

    var animationFPS: Double {
        switch self {
        case .compacting: return 6.0
        case .sleeping: return 2.0
        case .idle, .waiting: return 3.0
        case .working: return 4.0
        }
    }

    var spritePrefix: String { rawValue }

    var bobDuration: Double {
        switch self {
        case .sleeping:   return 4.0
        case .idle, .waiting: return 1.5
        case .working:    return 0.4
        case .compacting: return 0.5
        }
    }

    var bobAmplitude: CGFloat {
        switch self {
        case .sleeping, .compacting: return 0
        case .idle:                  return 1.5
        case .waiting:               return 0.5
        case .working:               return 0.5
        }
    }

    var canWalk: Bool {
        switch self {
        case .sleeping, .compacting, .waiting:
            return false
        case .idle, .working:
            return true
        }
    }

    var displayName: String {
        switch self {
        case .idle:       return "Idle"
        case .working:    return "Working..."
        case .sleeping:   return "Sleeping"
        case .compacting: return "Compacting..."
        case .waiting:    return "Waiting..."
        }
    }

    var walkFrequencyRange: ClosedRange<Double> {
        switch self {
        case .sleeping, .waiting: return 30.0...60.0
        case .idle:               return 8.0...15.0
        case .working:            return 5.0...12.0
        case .compacting:         return 15.0...25.0
        }
    }

    var frameCount: Int {
        switch self {
        case .compacting: return 5
        default: return 6
        }
    }

    var columns: Int {
        switch self {
        case .compacting: return 5
        default: return 6
        }
    }
}

enum NotchiEmotion: String, CaseIterable {
    case neutral, happy, sad, sob

    var swayAmplitude: Double {
        switch self {
        case .neutral: return 0.5
        case .happy:   return 1.0
        case .sad:     return 0.25
        case .sob:     return 0.15
        }
    }
}

enum SpriteCreature: String, CaseIterable {
    case claude
    case codex

    var assetPrefix: String {
        switch self {
        case .claude:
            return ""
        case .codex:
            return "codex_"
        }
    }

    func spriteSheetSource(task: NotchiTask, emotion: NotchiEmotion) -> SpriteSheetSource {
        for assetName in candidateAssetNames(task: task, emotion: emotion) {
            if let customURL = SpriteOverrideStore.overrideURL(forAssetName: assetName, creature: self) {
                return .file(customURL)
            }

            if NSImage(named: assetName) != nil {
                return .asset(assetName)
            }
        }

        return .asset("\(task.spritePrefix)_neutral")
    }

    func bundledAssetName(task: NotchiTask, emotion: NotchiEmotion) -> String {
        "\(assetPrefix)\(task.spritePrefix)_\(emotion.rawValue)"
    }

    func localOverrideBaseName(forAssetName assetName: String) -> String {
        guard !assetPrefix.isEmpty, assetName.hasPrefix(assetPrefix) else { return assetName }
        return String(assetName.dropFirst(assetPrefix.count))
    }

    private func candidateAssetNames(task: NotchiTask, emotion: NotchiEmotion) -> [String] {
        var names = [bundledAssetName(task: task, emotion: emotion)]
        if emotion == .sob {
            names.append(bundledAssetName(task: task, emotion: .sad))
        }
        names.append(bundledAssetName(task: task, emotion: .neutral))
        names.append("\(task.spritePrefix)_neutral")

        var deduplicated: [String] = []
        for name in names where !deduplicated.contains(name) {
            deduplicated.append(name)
        }
        return deduplicated
    }
}

struct NotchiState: Equatable {
    var task: NotchiTask
    var emotion: NotchiEmotion = .neutral
    var creature: SpriteCreature = .claude

    var spriteSheetSource: SpriteSheetSource {
        creature.spriteSheetSource(task: task, emotion: emotion)
    }
    var animationFPS: Double { task.animationFPS }
    var bobDuration: Double { task.bobDuration }
    var bobAmplitude: CGFloat {
        switch emotion {
        case .sob: return 0
        case .sad: return task.bobAmplitude * 0.5
        default:   return task.bobAmplitude
        }
    }
    var swayAmplitude: Double { emotion.swayAmplitude }
    var canWalk: Bool { emotion == .sob ? false : task.canWalk }
    var displayName: String { task.displayName }
    var walkFrequencyRange: ClosedRange<Double> { task.walkFrequencyRange }
    var frameCount: Int { task.frameCount }
    var columns: Int { task.columns }

    static let idle = NotchiState(task: .idle, creature: .claude)
    static let working = NotchiState(task: .working, creature: .claude)
    static let sleeping = NotchiState(task: .sleeping, creature: .claude)
    static let compacting = NotchiState(task: .compacting, creature: .claude)
    static let waiting = NotchiState(task: .waiting, creature: .claude)
}
