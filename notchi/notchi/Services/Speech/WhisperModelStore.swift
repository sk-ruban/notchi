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
        fileExists: @escaping @Sendable (URL) -> Bool = WhisperModelStore.defaultFileExists,
        downloader: @escaping @Sendable (URL, URL, @Sendable @escaping (Double) -> Void) async throws -> Void = WhisperModelStore.liveDownloader
    ) {
        self.fileExists = fileExists
        self.downloader = downloader
    }

    nonisolated static func defaultFileExists(at url: URL) -> Bool {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        return size > 0
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
        let delegate = DownloadProgressDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let tempURL: URL = try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            let task = session.downloadTask(with: remote)
            task.resume()
        }
        progress(1.0)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<URL, Error>?

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: URLError(.badServerResponse))
            return
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: temp)
            continuation?.resume(returning: temp)
        } catch {
            continuation?.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: error)
    }
}
