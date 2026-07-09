import AppKit

enum NotchiTask: String, CaseIterable {
    case idle, working, sleeping, compacting, waiting, waving

    var loopDuration: Double {
        switch self {
        case .compacting: return Double(frameCount) / 6.0
        case .sleeping: return Double(frameCount) / 2.0
        case .idle, .waiting: return Double(frameCount) / 3.0
        case .working: return Double(frameCount) / 4.0
        case .waving: return NotchiState.launchWaveDuration
        }
    }

    var spritePrefix: String { rawValue }

    var bobDuration: Double {
        switch self {
        case .sleeping:   return 4.0
        case .idle, .waiting: return 1.5
        case .working:    return 0.4
        case .compacting: return 0.5
        case .waving:     return 1.5
        }
    }

    var bobAmplitude: CGFloat {
        switch self {
        case .sleeping, .compacting, .waving: return 0
        case .idle:                  return 1.5
        case .waiting:               return 0.5
        case .working:               return 0.5
        }
    }

    var canWalk: Bool {
        switch self {
        case .sleeping, .compacting, .waiting, .waving:
            return false
        case .idle, .working:
            return true
        }
    }

    var mirrorPolicy: SpriteMirrorPolicy.Mode {
        switch self {
        case .idle:
            return .timed(30...60)
        case .waiting:
            return .timed(45...90)
        case .working:
            return .timed(10...15)
        case .compacting:
            return .stateEntry
        case .sleeping, .waving:
            return .never
        }
    }

    var displayName: String {
        switch self {
        case .idle:       return String(localized: "Idle")
        case .working:    return String(localized: "Working...")
        case .sleeping:   return String(localized: "Sleeping")
        case .compacting: return String(localized: "Compacting...")
        case .waiting:    return String(localized: "Waiting...")
        case .waving:     return String(localized: "Waving")
        }
    }

    var walkFrequencyRange: ClosedRange<Double> {
        switch self {
        case .sleeping, .waiting: return 30.0...60.0
        case .idle:               return 8.0...15.0
        case .working:            return 5.0...12.0
        case .compacting:         return 15.0...25.0
        case .waving:             return 30.0...60.0
        }
    }

    var frameCount: Int {
        switch self {
        case .compacting: return 5
        case .waving: return 25
        default: return 6
        }
    }

    var columns: Int {
        switch self {
        case .compacting: return 5
        case .waving: return 25
        default: return 6
        }
    }
}

enum NotchiEmotion: String, CaseIterable {
    case neutral, happy, elated, sad, sob

    var swayAmplitude: Double {
        switch self {
        case .neutral: return 0.5
        case .happy:   return 1.0
        case .elated:  return 1.25
        case .sad:     return 0.25
        case .sob:     return 0.15
        }
    }
}

enum NotchiSpriteFamily: String {
    case claude
    case codex
}

struct SpriteSheetPresentation: Equatable {
    let spriteSheetName: String
    let renderMirrored: Bool
}

extension AgentProvider {
    var spriteFamily: NotchiSpriteFamily {
        switch self {
        case .claude:
            .claude
        case .codex:
            .codex
        }
    }
}

struct NotchiState: Equatable {
    static let launchWaveDuration = 2.6
    private static let expressiveSpriteTargetFPS = 7.0

    var task: NotchiTask
    var emotion: NotchiEmotion = .neutral
    var spriteFamily: NotchiSpriteFamily = .claude
    private static var flippedSpriteSheetAvailability: [String: Bool] = [:]

    /// Resolves the sprite sheet name with fallback chain: exact emotion -> nearby base emotion -> neutral -> idle.
    var spriteSheetName: String {
        if let availableName = availableSpriteSheetName(for: task, emotion: emotion) {
            return availableName
        }

        if task != .idle, let idleName = availableSpriteSheetName(for: .idle, emotion: emotion) {
            return idleName
        }

        return spriteSheetName(for: .idle, emotion: .neutral)
    }

    private func availableSpriteSheetName(for task: NotchiTask, emotion: NotchiEmotion) -> String? {
        let name = spriteSheetName(for: task, emotion: emotion)
        if NSImage(named: name) != nil { return name }
        if emotion == .elated {
            let happyName = spriteSheetName(for: task, emotion: .happy)
            if NSImage(named: happyName) != nil { return happyName }
        }
        if emotion == .sob {
            let sadName = spriteSheetName(for: task, emotion: .sad)
            if NSImage(named: sadName) != nil { return sadName }
        }

        let neutralName = spriteSheetName(for: task, emotion: .neutral)
        return NSImage(named: neutralName) != nil ? neutralName : nil
    }

    private func spriteSheetName(for task: NotchiTask, emotion: NotchiEmotion) -> String {
        "\(spriteFamily.rawValue)_\(task.spritePrefix)_\(emotion.rawValue)"
    }

    var animationFPS: Double {
        Double(frameCount) / loopDuration
    }

    private var loopDuration: Double {
        if task == .waving {
            return Self.launchWaveDuration
        }

        if let targetFPS {
            return Double(frameCount) / targetFPS
        }

        return task.loopDuration
    }

    private var targetFPS: Double? {
        if task == .compacting {
            return 6.0
        }

        switch (spriteFamily, task, emotion) {
        case (.claude, .idle, .elated),
             (.claude, .idle, .happy),
             (.codex, .idle, .elated),
             (.codex, .idle, .happy),
             (.codex, .working, .happy):
            return Self.expressiveSpriteTargetFPS
        default:
            return nil
        }
    }

    var bobDuration: Double { task.bobDuration }
    var motionFrameInterval: Double {
        (task == .working || emotion == .sob) ? 1.0 / 30.0 : 1.0 / 15.0
    }
    var bobAmplitude: CGFloat {
        switch emotion {
        case .sob: return 0
        case .sad: return task.bobAmplitude * 0.5
        case .elated: return task.bobAmplitude * 1.2
        default:   return task.bobAmplitude
        }
    }
    var swayAmplitude: Double { emotion.swayAmplitude }
    var canWalk: Bool { emotion == .sob ? false : task.canWalk }
    var mirrorPolicy: SpriteMirrorPolicy.Mode { task.mirrorPolicy }
    var displayName: String { task.displayName }
    var walkFrequencyRange: ClosedRange<Double> { task.walkFrequencyRange }
    var frameCount: Int { inferredFrameCount ?? task.frameCount }
    var columns: Int { inferredFrameCount ?? task.columns }

    @MainActor
    func spriteSheetPresentation(isMirrored: Bool) -> SpriteSheetPresentation {
        let name = spriteSheetName
        guard isMirrored else {
            return SpriteSheetPresentation(spriteSheetName: name, renderMirrored: false)
        }

        if task == .working {
            let flippedName = "\(name)_flipped"
            if Self.hasSpriteSheet(named: flippedName) {
                return SpriteSheetPresentation(spriteSheetName: flippedName, renderMirrored: false)
            }
        }

        return SpriteSheetPresentation(spriteSheetName: name, renderMirrored: true)
    }

    @MainActor
    private static func hasSpriteSheet(named name: String) -> Bool {
        if let cached = flippedSpriteSheetAvailability[name] {
            return cached
        }

        let exists = NSImage(named: name) != nil
        flippedSpriteSheetAvailability[name] = exists
        return exists
    }

    private var inferredFrameCount: Int? {
        guard let image = NSImage(named: spriteSheetName), image.size.height > 0 else {
            return nil
        }

        let frameCount = Int((image.size.width / image.size.height).rounded())
        return frameCount > 0 ? frameCount : nil
    }

    static let idle = NotchiState(task: .idle)
    static let working = NotchiState(task: .working)
    static let sleeping = NotchiState(task: .sleeping)
    static let compacting = NotchiState(task: .compacting)
    static let waiting = NotchiState(task: .waiting)
    static let waving = NotchiState(task: .waving)
}
