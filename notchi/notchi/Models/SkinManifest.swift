import Foundation

struct SkinManifest: Codable, Equatable {
    let name: String
    let version: Int
    let author: String?
    let description: String?
    /// Maps sprite sheet names (e.g. "idle_neutral") to relative filenames within the skin folder.
    let sprites: [String: String]
    /// Relative filename for a custom grass island texture.
    let grass: String?
}
