import XCTest
@testable import notchi

@MainActor
final class SpeechToTextServiceTests: XCTestCase {
    private final class MockCapture: AudioCapturing, @unchecked Sendable {
        var stopCount = 0
        func start() throws {}
        func stop() -> [Float] {
            stopCount += 1
            return [0.1, 0.2, 0.3]
        }
    }

    private struct MockTranscriber: Transcribing {
        let text: String
        func transcribe(samples: [Float], language: String) async throws -> String { text }
    }

    /// Transcriber whose `transcribe()` hangs until `resume` is called, so tests can
    /// deterministically observe the service while it is in `.transcribing`.
    private final class HangingTranscriber: Transcribing, @unchecked Sendable {
        private var continuation: CheckedContinuation<String, Error>?

        func transcribe(samples: [Float], language: String) async throws -> String {
            try await withCheckedThrowingContinuation { self.continuation = $0 }
        }

        func resume(with text: String) {
            continuation?.resume(returning: text)
        }
    }

    private func makeService(
        modelDownloaded: Bool = true,
        micAuthorized: Bool = true,
        transcript: String = "hello world"
    ) -> SpeechToTextService {
        SpeechToTextService(dependencies: .init(
            makeCapture: { MockCapture() },
            makeTranscriber: { _ in MockTranscriber(text: transcript) },
            isModelDownloaded: { modelDownloaded },
            modelURL: { URL(fileURLWithPath: "/tmp/model.bin") },
            language: { "en" },
            microphoneAuthorized: { micAuthorized }
        ))
    }

    func testHappyPathReachesReviewWithTranscript() async {
        let service = makeService(transcript: "run the tests")
        service.startRecording()
        XCTAssertEqual(service.phase, .recording)
        await service.finishRecording()
        XCTAssertEqual(service.phase, .review("run the tests"))
        XCTAssertEqual(service.transcript, "run the tests")
    }

    func testMissingModelBlocksRecording() {
        let service = makeService(modelDownloaded: false)
        service.startRecording()
        XCTAssertEqual(service.phase, .error(.modelMissing))
    }

    func testDeniedMicrophoneBlocksRecording() {
        let service = makeService(micAuthorized: false)
        service.startRecording()
        XCTAssertEqual(service.phase, .error(.microphoneDenied))
    }

    func testEmptyTranscriptionSurfacesError() async {
        let service = makeService(transcript: "")
        service.startRecording()
        await service.finishRecording()
        XCTAssertEqual(service.phase, .error(.transcriptionFailed))
    }

    func testResetReturnsToIdle() async {
        let service = makeService()
        service.startRecording()
        await service.finishRecording()
        service.reset()
        XCTAssertEqual(service.phase, .idle)
        XCTAssertTrue(service.transcript.isEmpty)
    }

    func testStartRecordingWhileAlreadyRecordingIsNoOp() {
        final class CaptureCounter: @unchecked Sendable {
            var count = 0
        }
        let counter = CaptureCounter()
        let service = SpeechToTextService(dependencies: .init(
            makeCapture: {
                counter.count += 1
                return MockCapture()
            },
            makeTranscriber: { _ in MockTranscriber(text: "hello world") },
            isModelDownloaded: { true },
            modelURL: { URL(fileURLWithPath: "/tmp/model.bin") },
            language: { "en" },
            microphoneAuthorized: { true }
        ))

        service.startRecording()
        XCTAssertEqual(service.phase, .recording)
        XCTAssertEqual(counter.count, 1)

        service.startRecording()
        XCTAssertEqual(service.phase, .recording)
        XCTAssertEqual(counter.count, 1, "second startRecording() must not create a second capture")
    }

    func testResetWhileRecordingStopsCapture() {
        let capture = MockCapture()
        let service = SpeechToTextService(dependencies: .init(
            makeCapture: { capture },
            makeTranscriber: { _ in MockTranscriber(text: "hello world") },
            isModelDownloaded: { true },
            modelURL: { URL(fileURLWithPath: "/tmp/model.bin") },
            language: { "en" },
            microphoneAuthorized: { true }
        ))

        service.startRecording()
        XCTAssertEqual(service.phase, .recording)

        service.reset()

        XCTAssertEqual(capture.stopCount, 1, "reset() must stop an in-flight capture")
        XCTAssertEqual(service.phase, .idle)
    }

    func testStartRecordingWhileTranscribingIsNoOp() async {
        final class CaptureCounter: @unchecked Sendable {
            var count = 0
        }
        let counter = CaptureCounter()
        let transcriber = HangingTranscriber()
        let service = SpeechToTextService(dependencies: .init(
            makeCapture: {
                counter.count += 1
                return MockCapture()
            },
            makeTranscriber: { _ in transcriber },
            isModelDownloaded: { true },
            modelURL: { URL(fileURLWithPath: "/tmp/model.bin") },
            language: { "en" },
            microphoneAuthorized: { true }
        ))

        service.startRecording()
        XCTAssertEqual(service.phase, .recording)
        XCTAssertEqual(counter.count, 1)

        let finishTask = Task { await service.finishRecording() }
        while service.phase != .transcribing {
            await Task.yield()
        }

        service.startRecording()
        XCTAssertEqual(service.phase, .transcribing, "startRecording() must no-op while transcribing")
        XCTAssertEqual(counter.count, 1, "startRecording() during transcribing must not create a second capture")

        transcriber.resume(with: "done")
        await finishTask.value
    }

    func testAppendedCombinesExistingAndNewWithSpace() {
        XCTAssertEqual(SpeechToTextService.appended("", "hello"), "hello")
        XCTAssertEqual(SpeechToTextService.appended("hello", ""), "hello")
        XCTAssertEqual(SpeechToTextService.appended("hello", "world"), "hello world")
        XCTAssertEqual(SpeechToTextService.appended("", ""), "")
    }

    func testSendInjectsReviewTextIntoActiveSession() async {
        let service = makeService(transcript: "run tests")
        service.startRecording()
        await service.finishRecording()
        let session = SessionData(sessionId: "c", provider: .claude, cwd: "/tmp")

        var injected: String?
        let result = await service.send(
            using: { text, _ in injected = text; return .sent },
            targetSession: session
        )

        XCTAssertEqual(result, .sent)
        XCTAssertEqual(injected, "run tests")
        XCTAssertEqual(service.phase, .idle)
    }

    func testSendWithoutSessionSetsNoSessionError() async {
        let service = makeService()
        service.startRecording()
        await service.finishRecording()
        let result = await service.send(using: { _, _ in .noSession }, targetSession: nil)
        XCTAssertEqual(result, .noSession)
        XCTAssertEqual(service.phase, .error(.noActiveSession))
    }

    func testSendInjectionFailureReturnsToReviewForRetry() async {
        let service = makeService(transcript: "run tests")
        service.startRecording()
        await service.finishRecording()
        let session = SessionData(sessionId: "c", provider: .claude, cwd: "/tmp")

        let result = await service.send(using: { _, _ in .failed }, targetSession: session)

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(service.phase, .review("run tests"))
        XCTAssertEqual(service.transcript, "run tests")
    }

    func testResetDuringTranscribingIsNotClobberedByLateResult() async {
        let transcriber = HangingTranscriber()
        let service = SpeechToTextService(dependencies: .init(
            makeCapture: { MockCapture() },
            makeTranscriber: { _ in transcriber },
            isModelDownloaded: { true },
            modelURL: { URL(fileURLWithPath: "/tmp/model.bin") },
            language: { "en" },
            microphoneAuthorized: { true }
        ))

        service.startRecording()
        let finishTask = Task { await service.finishRecording() }
        while service.phase != .transcribing { await Task.yield() }

        service.reset()   // user dismissed while transcription was in flight
        XCTAssertEqual(service.phase, .idle)

        transcriber.resume(with: "late result")
        await finishTask.value

        XCTAssertEqual(service.phase, .idle, "a late transcription result must not resurrect the dismissed box")
        XCTAssertTrue(service.transcript.isEmpty)
    }

    func testTranscriberIsReusedAcrossDictationsForSameModel() async {
        final class BuildCounter: @unchecked Sendable { var count = 0 }
        let counter = BuildCounter()
        let service = SpeechToTextService(dependencies: .init(
            makeCapture: { MockCapture() },
            makeTranscriber: { _ in counter.count += 1; return MockTranscriber(text: "hi") },
            isModelDownloaded: { true },
            modelURL: { URL(fileURLWithPath: "/tmp/model.bin") },
            language: { "en" },
            microphoneAuthorized: { true }
        ))

        service.startRecording(); await service.finishRecording()
        service.reset()
        service.startRecording(); await service.finishRecording()

        XCTAssertEqual(counter.count, 1, "the model transcriber must be built once and reused, not reloaded per dictation")
    }
}
