import AppKit
import SwiftUI

enum SkinImage: Equatable {
    case assetCatalog(String)
    case fileBacked(URL)

    var swiftUIImage: Image {
        switch self {
        case .assetCatalog(let name):
            return Image(name)
        case .fileBacked(let url):
            let nsImage = NSImage(contentsOf: url) ?? NSImage()
            return Image(nsImage: nsImage)
        }
    }

    var isAvailable: Bool {
        switch self {
        case .assetCatalog(let name):
            return NSImage(named: name) != nil
        case .fileBacked(let url):
            return FileManager.default.fileExists(atPath: url.path)
        }
    }
}
