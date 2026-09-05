import Foundation

nonisolated struct WhisperModel: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let fileName: String
    let isMultilingual: Bool
    let approxMB: Int
}

nonisolated enum WhisperCatalog {
    // ggml weights hosted at huggingface.co/ggml-org/whisper.cpp
    static let models: [WhisperModel] = [
        WhisperModel(id: "tiny.en", displayName: "Tiny (English)", fileName: "ggml-tiny.en.bin", isMultilingual: false, approxMB: 75),
        WhisperModel(id: "base.en", displayName: "Base (English)", fileName: "ggml-base.en.bin", isMultilingual: false, approxMB: 142),
        WhisperModel(id: "small", displayName: "Small (Multilingual)", fileName: "ggml-small.bin", isMultilingual: true, approxMB: 466),
        WhisperModel(id: "large-v3-turbo", displayName: "Turbo (Multilingual)", fileName: "ggml-large-v3-turbo.bin", isMultilingual: true, approxMB: 1560),
    ]

    static func model(id: String) -> WhisperModel? {
        models.first { $0.id == id }
    }
}
