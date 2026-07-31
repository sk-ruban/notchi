import Foundation
import Observation
import os.log

nonisolated private let logger = Logger(subsystem: "com.ruban.notchi", category: "WhisperModelStore")

@MainActor
@Observable
final class WhisperModelStore {
    static let shared = WhisperModelStore()

    private(set) var downloadProgress: [String: Double] = [:]

    private let fileExists: @Sendable (URL) -> Bool
    private let downloader: @Sendable (URL, URL, @Sendable @escaping (Double) -> Void) async throws -> Void

    init(
        fileExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        downloader: @escaping @Sendable (URL, URL, @Sendable @escaping (Double) -> Void) async throws -> Void = WhisperModelStore.liveDownloader
    ) {
        self.fileExists = fileExists
        self.downloader = downloader
    }

    nonisolated static func modelsDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchi", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    nonisolated static func fileURL(for model: WhisperModel) -> URL {
        modelsDirectory().appendingPathComponent(model.fileName)
    }

    nonisolated static func remoteURL(for model: WhisperModel) -> URL {
        // The ggml Whisper weights are hosted on the ggerganov/whisper.cpp HF
        // repo; ggml-org/whisper.cpp is the source-code mirror and 401s on
        // resolve/, so downloads must target ggerganov.
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(model.fileName)")!
    }

    func isDownloaded(_ model: WhisperModel) -> Bool {
        fileExists(Self.fileURL(for: model))
    }

    func download(_ model: WhisperModel) async throws {
        let destination = Self.fileURL(for: model)
        let modelId = model.id
        do {
            try FileManager.default.createDirectory(at: Self.modelsDirectory(), withIntermediateDirectories: true)
            downloadProgress[modelId] = 0
            try await downloader(Self.remoteURL(for: model), destination) { fraction in
                Task { @MainActor [weak self] in self?.downloadProgress[modelId] = fraction }
            }
            downloadProgress[modelId] = 1.0
            logger.info("Downloaded model \(modelId, privacy: .public)")
        } catch {
            // WHY: clear progress so the settings row falls back to the Download
            // affordance instead of showing a stuck spinner, and log so a failed
            // fetch is never silently invisible.
            downloadProgress[modelId] = nil
            logger.error("Model download failed for \(modelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    nonisolated static let liveDownloader: @Sendable (URL, URL, @Sendable @escaping (Double) -> Void) async throws -> Void = { remote, destination, progress in
        let (tempURL, response) = try await URLSession.shared.download(from: remote)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        progress(1.0)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }
}
