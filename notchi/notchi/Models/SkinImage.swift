import AppKit
import SwiftUI

enum SkinImage: Equatable {
    case assetCatalog(String)
    case fileBacked(URL, cachedImage: NSImage?)

    static func fileBacked(url: URL) -> SkinImage {
        let cached = SkinManager.shared.cachedImage(for: url)
        return .fileBacked(url, cachedImage: cached)
    }

    var swiftUIImage: Image {
        switch self {
        case .assetCatalog(let name):
            return Image(name)
        case .fileBacked(let url, let cached):
            let nsImage = cached ?? NSImage(contentsOf: url) ?? NSImage()
            return Image(nsImage: nsImage)
        }
    }

    var isAvailable: Bool {
        switch self {
        case .assetCatalog(let name):
            return NSImage(named: name) != nil
        case .fileBacked(let url, _):
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    static func == (lhs: SkinImage, rhs: SkinImage) -> Bool {
        switch (lhs, rhs) {
        case (.assetCatalog(let a), .assetCatalog(let b)):
            return a == b
        case (.fileBacked(let a, _), .fileBacked(let b, _)):
            return a == b
        default:
            return false
        }
    }
}
