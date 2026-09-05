import AVFoundation
import os.log

nonisolated private let logger = Logger(subsystem: "com.ruban.notchi", category: "AudioCaptureEngine")

nonisolated protocol AudioCapturing: Sendable {
    func start() throws
    func stop() -> [Float]
}

nonisolated enum AudioCaptureError: Error { case engineStartFailed, converterUnavailable }

// WHY: whisper.cpp expects 16 kHz mono Float32 PCM. The hardware input format
// varies (often 44.1/48 kHz), so tap the input node and convert each buffer.
final class AudioCaptureEngine: AudioCapturing, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    // Set under `lock` in stop(); a tap callback still executing on the audio
    // thread after removeTap checks this and skips appending, so it never writes
    // into a buffer that a subsequent start() has reset. (The final in-flight
    // buffer at key-release is inherently bounded — push-to-talk tail.)
    private var stopped = false
    private static let targetSampleRate = 16_000.0

    func start() throws {
        lock.lock(); samples.removeAll(); stopped = false; lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.converterUnavailable
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.converterUnavailable
        }

        // Defensively remove any dangling tap before installing a new one.
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, inputFormat.sampleRate > 0 else { return }
            let ratio = Self.targetSampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var error: NSError?
            var consumed = false
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = out.floatChannelData?[0] else { return }
            let frames = Int(out.frameLength)
            self.lock.lock()
            if !self.stopped {
                self.samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))
            }
            self.lock.unlock()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            logger.error("Audio engine start failed: \(error.localizedDescription, privacy: .public)")
            throw AudioCaptureError.engineStartFailed
        }
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); defer { lock.unlock() }
        stopped = true
        let captured = samples
        samples = []
        return captured
    }
}
