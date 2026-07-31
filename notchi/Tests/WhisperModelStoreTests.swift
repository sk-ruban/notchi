import XCTest
@testable import notchi

final class WhisperModelStoreTests: XCTestCase {
    func testCatalogHasExpectedSizesAndDefaultIsPresent() {
        let ids = Set(WhisperCatalog.models.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["tiny.en", "base.en", "small", "large-v3-turbo"]))
        XCTAssertNotNil(WhisperCatalog.model(id: "base.en"))
        XCTAssertNil(WhisperCatalog.model(id: "not-real"))
    }

    func testEnglishOnlyModelsAreNotMultilingual() {
        XCTAssertEqual(WhisperCatalog.model(id: "base.en")?.isMultilingual, false)
        XCTAssertEqual(WhisperCatalog.model(id: "small")?.isMultilingual, true)
    }

    func testFileURLIsUnderApplicationSupportNotchiModels() {
        let model = WhisperCatalog.model(id: "base.en")!
        let url = WhisperModelStore.fileURL(for: model)
        XCTAssertEqual(url.lastPathComponent, "ggml-base.en.bin")
        XCTAssertTrue(url.deletingLastPathComponent().path.hasSuffix("Notchi/Models"))
    }

    func testRemoteURLTargetsGgerganovRepo() {
        let model = WhisperCatalog.model(id: "small")!
        XCTAssertEqual(
            WhisperModelStore.remoteURL(for: model).absoluteString,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
        )
    }

    @MainActor
    func testIsDownloadedReflectsInjectedFileExistence() {
        let present = WhisperCatalog.model(id: "base.en")!
        let absent = WhisperCatalog.model(id: "small")!
        let store = WhisperModelStore(
            fileExists: { $0.lastPathComponent == "ggml-base.en.bin" },
            downloader: { _, _, _ in }
        )
        XCTAssertTrue(store.isDownloaded(present))
        XCTAssertFalse(store.isDownloaded(absent))
    }

    @MainActor
    func testDownloadReportsProgressAndCompletes() async throws {
        let model = WhisperCatalog.model(id: "tiny.en")!
        let store = WhisperModelStore(
            fileExists: { _ in false },
            downloader: { _, _, progress in
                progress(0.5)
                progress(1.0)
            }
        )
        try await store.download(model)
        XCTAssertEqual(store.downloadProgress[model.id], 1.0)
    }
}
