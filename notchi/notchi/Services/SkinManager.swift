import AppKit
import Foundation

struct DiscoveredSkin: Identifiable, Equatable {
    let id: String
    let name: String
    let manifest: SkinManifest?
    let folderURL: URL?

    var isDefault: Bool { folderURL == nil }
}

@MainActor
@Observable
final class SkinManager {
    static let shared = SkinManager()

    private static let installedBundledSkinsKey = "installedBundledSkinsVersion"

    private static let skinsBaseDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".notchi")
            .appendingPathComponent("skins")
    }()

    private(set) var availableSkins: [DiscoveredSkin] = [DiscoveredSkin(
        id: "Default",
        name: "Default",
        manifest: nil,
        folderURL: nil
    )]

    var selectedSkinName: String = AppSettings.selectedSkinName {
        didSet {
            if !availableSkins.contains(where: { $0.id == selectedSkinName }) {
                selectedSkinName = "Default"
            }
            AppSettings.selectedSkinName = selectedSkinName
        }
    }

    private init() {}

    func refresh() {
        try? FileManager.default.createDirectory(
            at: Self.skinsBaseDirectory,
            withIntermediateDirectories: true
        )

        installBundledSkinsIfNeeded()

        var skins: [DiscoveredSkin] = [DiscoveredSkin(
            id: "Default",
            name: "Default",
            manifest: nil,
            folderURL: nil
        )]

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: Self.skinsBaseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            availableSkins = skins
            return
        }

        for folderURL in contents {
            guard let resourceValues = try? folderURL.resourceValues(forKeys: [.isDirectoryKey]),
                  resourceValues.isDirectory == true else { continue }

            let manifestURL = folderURL.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(SkinManifest.self, from: data) else {
                continue
            }

            let skin = DiscoveredSkin(
                id: folderURL.lastPathComponent,
                name: manifest.name,
                manifest: manifest,
                folderURL: folderURL
            )
            skins.append(skin)
        }

        availableSkins = skins

        if !skins.contains(where: { $0.id == selectedSkinName }) {
            selectedSkinName = "Default"
        }
    }

    func image(forSpriteSheet name: String, emotion: NotchiEmotion) -> SkinImage {
        if let skin = activeSkin {
            // 1. Custom skin exact match
            if let fileImage = resolveCustomSprite(name, in: skin) {
                return fileImage
            }

            // 2. Custom skin sob -> sad fallback
            if emotion == .sob {
                let sadName = name.replacingOccurrences(of: "_sob$", with: "_sad", options: .regularExpression)
                if sadName != name, let fileImage = resolveCustomSprite(sadName, in: skin) {
                    return fileImage
                }
            }

            // 3. Custom skin -> neutral fallback
            if emotion != .neutral {
                let neutralName = name.components(separatedBy: "_").dropLast().joined(separator: "_") + "_neutral"
                if neutralName != name, let fileImage = resolveCustomSprite(neutralName, in: skin) {
                    return fileImage
                }
            }
        }

        // 4. Bundled asset catalog chain
        if NSImage(named: name) != nil { return .assetCatalog(name) }
        if emotion == .sob {
            let sadName = name.replacingOccurrences(of: "_sob$", with: "_sad", options: .regularExpression)
            if sadName != name, NSImage(named: sadName) != nil { return .assetCatalog(sadName) }
        }
        let taskPrefix = name.components(separatedBy: "_").dropLast().joined(separator: "_")
        return .assetCatalog("\(taskPrefix)_neutral")
    }

    func hasImage(forSpriteSheet name: String) -> Bool {
        if let skin = activeSkin, resolveCustomSprite(name, in: skin) != nil {
            return true
        }
        return NSImage(named: name) != nil
    }

    func grassImage() -> SkinImage {
        guard let skin = activeSkin,
              let grassFile = skin.manifest?.grass,
              let folderURL = skin.folderURL else {
            return .assetCatalog("GrassIsland")
        }
        let url = folderURL.appendingPathComponent(grassFile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .assetCatalog("GrassIsland")
        }
        return .fileBacked(url)
    }

    var skinsDirectoryURL: URL { Self.skinsBaseDirectory }

    private func installBundledSkinsIfNeeded() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let installedVersion = UserDefaults.standard.string(forKey: Self.installedBundledSkinsKey)

        guard installedVersion != currentVersion else { return }

        guard let zipURL = Bundle.main.url(forResource: "rainbow-skin", withExtension: "zip") else {
            return
        }

        do {
            try FileManager.default.createDirectory(at: Self.skinsBaseDirectory, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", zipURL.path, "-d", Self.skinsBaseDirectory.path]
            try process.run()
            process.waitUntilExit()
        } catch {
            print("Failed to install bundled skin: \(error)")
        }

        UserDefaults.standard.set(currentVersion, forKey: Self.installedBundledSkinsKey)
    }

    private var activeSkin: DiscoveredSkin? {
        availableSkins.first(where: { $0.id == selectedSkinName && !$0.isDefault })
    }

    private func resolveCustomSprite(_ name: String, in skin: DiscoveredSkin) -> SkinImage? {
        guard let manifest = skin.manifest,
              let filename = manifest.sprites[name],
              let folderURL = skin.folderURL else {
            return nil
        }
        let url = folderURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return .fileBacked(url)
    }
}
