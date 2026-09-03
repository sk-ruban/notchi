import XCTest
@testable import notchi

final class FileChipTextTests: XCTestCase {
    func testIconStyleResolvesProgrammingExtensions() {
        XCTAssertEqual(FileChipText.iconStyle(forFilename: "NotchContentView.swift")?.assetName, "fileicon_swift")
        XCTAssertEqual(FileChipText.iconStyle(forFilename: "index.tsx")?.assetName, "fileicon_typescript")
        XCTAssertEqual(FileChipText.iconStyle(forFilename: "main.py")?.assetName, "fileicon_python")
        XCTAssertEqual(FileChipText.iconStyle(forFilename: "test.sh")?.assetName, "fileicon_bash")
    }

    func testIconStyleOmitsIconForNonProgrammingFiles() {
        XCTAssertNil(FileChipText.iconStyle(forFilename: "release-notes.md"))
        XCTAssertNil(FileChipText.iconStyle(forFilename: "Localizable.xcstrings"))
        XCTAssertNil(FileChipText.iconStyle(forFilename: "app-update.yml"))
        XCTAssertNil(FileChipText.iconStyle(forFilename: "CLAUDE.md"))
        XCTAssertNil(FileChipText.iconStyle(forFilename: "archive.xyz"))
        XCTAssertNil(FileChipText.iconStyle(forFilename: "noextension"))
    }

    func testFilenameShapedAcceptsFilenamesOnly() {
        XCTAssertTrue(FileChipText.isFilenameShaped("AppSettings.swift"))
        XCTAssertTrue(FileChipText.isFilenameShaped("app-update.yml"))
        XCTAssertFalse(FileChipText.isFilenameShaped(".public"))
        XCTAssertFalse(FileChipText.isFilenameShaped("startPolling()"))
        XCTAssertFalse(FileChipText.isFilenameShaped("git add file.sh"))
        XCTAssertFalse(FileChipText.isFilenameShaped("trailing."))
    }

    func testSegmentsChipsInlineCodeFilenamesAndKeepsPlainCode() throws {
        let attributed = try AttributedString(
            markdown: "see `NotchContentView.swift` uses `.public` logs",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let segments = FileChipText.segments(from: attributed)

        XCTAssertTrue(segments.contains(.chip("NotchContentView.swift")))
        XCTAssertTrue(segments.contains(.code(".public")))
    }

    func testSegmentsChipsBareFilenamesWithKnownExtensions() throws {
        let attributed = try AttributedString(
            markdown: "fix NotchPanelManager.swift please",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let segments = FileChipText.segments(from: attributed)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[1], .chip("NotchPanelManager.swift"))
    }

    func testSegmentsIgnoresBareTokensWithUnknownExtensions() throws {
        let attributed = try AttributedString(
            markdown: "bump to v1.2.5 today",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let segments = FileChipText.segments(from: attributed)

        XCTAssertEqual(segments.count, 1)
        guard case .plain = segments[0] else {
            return XCTFail("expected the whole line to stay plain, got \(segments)")
        }
    }

    func testSegmentsChipsFilenameLinksByBasename() throws {
        let attributed = try AttributedString(
            markdown: "[NotchContentView.swift](/Users/ruban/notchi/NotchContentView.swift) emits logs",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let segments = FileChipText.segments(from: attributed)

        XCTAssertTrue(segments.contains(.chip("NotchContentView.swift")))
    }
}
