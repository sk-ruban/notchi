import Foundation
import os.log
import whisper

nonisolated private let logger = Logger(subsystem: "com.ruban.notchi", category: "WhisperTranscriber")

nonisolated protocol Transcribing: Sendable {
    func transcribe(samples: [Float], language: String) async throws -> String
}

nonisolated enum WhisperTranscriberError: Error { case modelLoadFailed, inferenceFailed }

actor WhisperTranscriber: Transcribing {
    private var context: OpaquePointer?
    private let modelURL: URL

    // whisper.cpp needs a minimum amount of audio; feeding a near-empty buffer
    // segfaults inside whisper_encode_internal. Require ~0.25s at 16 kHz.
    private static let minimumSampleCount = 4000

    init(modelURL: URL) {
        self.modelURL = modelURL
    }

    deinit {
        if let context { whisper_free(context) }
    }

    private func loadedContext() throws -> OpaquePointer {
        if let context { return context }
        var params = whisper_context_default_params()
        // WHY: the Metal/GPU encode path null-derefs (EXC_BAD_ACCESS in
        // whisper_encode_internal) in this embedded static-xcframework build.
        // CPU inference is reliable and near-real-time for base.en on Apple
        // Silicon; revisit GPU once the Metal-context crash is understood.
        params.use_gpu = false
        let loaded = modelURL.path.withCString { whisper_init_from_file_with_params($0, params) }
        guard let loaded else {
            logger.error("whisper model load failed at \(self.modelURL.lastPathComponent, privacy: .public)")
            throw WhisperTranscriberError.modelLoadFailed
        }
        context = loaded
        return loaded
    }

    func transcribe(samples: [Float], language: String) async throws -> String {
        guard samples.count >= Self.minimumSampleCount else {
            logger.info("Skipping transcription: \(samples.count, privacy: .public) samples below minimum \(Self.minimumSampleCount, privacy: .public)")
            return ""
        }

        let ctx = try loadedContext()
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.no_context = true
        params.single_segment = false

        let result: Int32 = language.withCString { langPtr in
            params.language = (language == "auto") ? nil : langPtr
            return samples.withUnsafeBufferPointer { buffer in
                whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
            }
        }
        guard result == 0 else {
            logger.error("whisper_full failed with code \(result, privacy: .public)")
            throw WhisperTranscriberError.inferenceFailed
        }

        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            if let segment = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: segment)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
