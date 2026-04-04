import AppKit
import Foundation

enum SpriteSheetSource: Equatable {
    case asset(String)
    case file(URL)
}

enum SpriteOverrideStore {
    private static let supportedExtensions = ["png", "webp", "jpg", "jpeg"]
    private static let imageSetSpriteFilename = "sprite_sheet.png"

    static var directoryURL: URL {
        let appSupportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupportRoot
            .appendingPathComponent("notchi", isDirectory: true)
            .appendingPathComponent("Sprites", isDirectory: true)
    }

    static func ensureDirectoryExists() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        for creature in SpriteCreature.allCases {
            let providerDirectory = directoryURL.appendingPathComponent(creature.rawValue, isDirectory: true)
            try? fileManager.createDirectory(at: providerDirectory, withIntermediateDirectories: true)
        }

        installReadmeIfNeeded()
    }

    static func openDirectoryInFinder() {
        ensureDirectoryExists()
        NSWorkspace.shared.open(directoryURL)
    }

    static func installedOverrideCount() -> Int {
        let allAssetNames = Set(
            SpriteCreature.allCases.flatMap { creature in
                NotchiTask.allCases.flatMap { task in
                    NotchiEmotion.allCases.map { emotion in
                        creature.bundledAssetName(task: task, emotion: emotion)
                    }
                }
            }
        )

        return allAssetNames.reduce(into: 0) { count, assetName in
            if overrideURL(forAssetName: assetName, creature: creature(for: assetName)) != nil {
                count += 1
            }
        }
    }

    static func overrideURL(forAssetName assetName: String, creature: SpriteCreature) -> URL? {
        for relativePath in candidateRelativePaths(forAssetName: assetName, creature: creature) {
            let candidateURL = directoryURL.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return nil
    }

    private static func candidateRelativePaths(forAssetName assetName: String, creature: SpriteCreature) -> [String] {
        let localBaseName = creature.localOverrideBaseName(forAssetName: assetName)
        var candidates: [String] = []

        for fileExtension in supportedExtensions {
            candidates.append("\(assetName).\(fileExtension)")
            candidates.append("\(creature.rawValue)/\(localBaseName).\(fileExtension)")
        }

        candidates.append("\(assetName).imageset/\(imageSetSpriteFilename)")
        candidates.append("\(creature.rawValue)/\(localBaseName).imageset/\(imageSetSpriteFilename)")

        return candidates
    }

    private static func installReadmeIfNeeded() {
        let readmeURL = directoryURL.appendingPathComponent("README.txt")
        guard !FileManager.default.fileExists(atPath: readmeURL.path) else { return }

        let content = """
        Drop custom sprite sheets here to override Notchi's bundled creatures.

        Supported file names:
        1. Flat names matching the bundled asset names, for example:
           - idle_neutral.png
           - codex_working_happy.png
        2. Provider folders with local names, for example:
           - claude/idle_neutral.png
           - codex/working_happy.png

        You can also copy .imageset folders directly if they contain sprite_sheet.png.

        Expected sprite sheet names:
        \(expectedSpriteNamesText())
        """

        try? content.write(to: readmeURL, atomically: true, encoding: .utf8)
    }

    private static func expectedSpriteNamesText() -> String {
        SpriteCreature.allCases
            .map { creature in
                let names = NotchiTask.allCases.flatMap { task in
                    NotchiEmotion.allCases.map { emotion in
                        "  - \(creature.bundledAssetName(task: task, emotion: emotion))"
                    }
                }
                return ([creature.rawValue + ":" ] + names).joined(separator: "\n")
            }
            .joined(separator: "\n")
    }

    private static func creature(for assetName: String) -> SpriteCreature {
        SpriteCreature.allCases.first { assetName.hasPrefix($0.assetPrefix) && !$0.assetPrefix.isEmpty } ?? .claude
    }
}

@MainActor
final class SpriteImageRegistry {
    static let shared = SpriteImageRegistry()

    private struct CachedFileImage {
        let modificationDate: Date?
        let image: NSImage
    }

    private var fileCache: [String: CachedFileImage] = [:]

    func image(for source: SpriteSheetSource) -> NSImage? {
        switch source {
        case .asset(let name):
            return NSImage(named: name)

        case .file(let url):
            let key = url.path
            let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil

            if let cached = fileCache[key], cached.modificationDate == modificationDate {
                return cached.image
            }

            guard let image = NSImage(contentsOf: url) else {
                fileCache.removeValue(forKey: key)
                return nil
            }

            fileCache[key] = CachedFileImage(modificationDate: modificationDate, image: image)
            return image
        }
    }
}
