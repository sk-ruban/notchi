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

    func testSegmentsChipsBareFilenamesWithDottedBasenames() throws {
        let attributed = try AttributedString(
            markdown: "edit vite.config.ts and My.App.swift",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let segments = FileChipText.segments(from: attributed)

        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(segments[1], .chip("vite.config.ts"))
        XCTAssertEqual(segments[3], .chip("My.App.swift"))
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

    func testSegmentsChipsFilenameLinksByBasenameAndKeepsLink() throws {
        let attributed = try AttributedString(
            markdown: "[NotchContentView.swift](/Users/ruban/notchi/NotchContentView.swift) emits logs",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let segments = FileChipText.segments(from: attributed)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(
            segments[0],
            .chip("NotchContentView.swift", link: URL(fileURLWithPath: "/Users/ruban/notchi/NotchContentView.swift"))
        )
    }

    func testSegmentsKeepFileSchemeLinksOnChips() throws {
        let attributed = try AttributedString(
            markdown: "[Foo.swift](file:///Users/ruban/Foo.swift)",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let segments = FileChipText.segments(from: attributed)

        XCTAssertEqual(segments, [.chip("Foo.swift", link: URL(string: "file:///Users/ruban/Foo.swift"))])
    }

    func testSegmentsKeepWebLinksPlainWithLinkIntact() throws {
        let attributed = try AttributedString(
            markdown: "see [notchi.app](https://notchi.app) and [appcast.xml](https://updates.notchi.app/appcast.xml)",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let segments = FileChipText.segments(from: attributed)

        let linkedRuns = segments.compactMap { segment -> URL? in
            guard case .plain(let sub) = segment else { return nil }
            return sub.runs.first?.link
        }
        XCTAssertEqual(linkedRuns, [
            URL(string: "https://notchi.app"),
            URL(string: "https://updates.notchi.app/appcast.xml"),
        ])
        XCTAssertFalse(segments.contains { if case .chip = $0 { return true } else { return false } })
    }

    func testInlineAttributedRendersBoldWithoutLiteralAsterisks() {
        let rendered = FileChipText.inlineAttributed("fix the **P2** issue")
        XCTAssertEqual(String(rendered.characters), "fix the P2 issue")

        let boldRun = rendered.runs.first { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        XCTAssertEqual(boldRun.map { String(rendered.characters[$0.range]) }, "P2")
    }

    func testInlineAttributedPreservesNewlinesAndIgnoresBlockSyntax() {
        let rendered = FileChipText.inlineAttributed("- first line\nsecond line")
        XCTAssertEqual(String(rendered.characters), "- first line\nsecond line")
    }

    // At 13pt, "a " ends near x=11 and "the documentation" near x=121, all on one ~16pt line.
    private static let hoverPrompt = "a [the documentation](https://docs.example.com) b"
    private static let hoverWidth: CGFloat = 400
    private static let hoverFontSize: CGFloat = 13
    private static let docsURL = URL(string: "https://docs.example.com")

    private func hoveredLink(at point: CGPoint) -> URL? {
        FileChipText.link(
            at: point,
            in: FileChipText.inlineAttributed(Self.hoverPrompt),
            width: Self.hoverWidth,
            fontSize: Self.hoverFontSize
        )
    }

    func testLinkAtPointReturnsTheLinkUnderThePoint() {
        XCTAssertEqual(hoveredLink(at: CGPoint(x: 60, y: 8)), Self.docsURL)
    }

    func testLinkAtPointIsNilOverPlainText() {
        XCTAssertNil(hoveredLink(at: CGPoint(x: 3, y: 8)))
    }

    func testLinkAtPointIsNilPastTheEndOfTheLine() {
        XCTAssertNil(hoveredLink(at: CGPoint(x: 300, y: 8)))
    }

    func testLinkAtPointIsNilBelowTheText() {
        XCTAssertNil(hoveredLink(at: CGPoint(x: 60, y: 40)))
    }

    func testSegmentsTurnImageFileLinksIntoImageSegments() throws {
        let attributed = try AttributedString(
            markdown: "see [shot one.png](file:///tmp/my%20shots/one.png) ok",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let segments = FileChipText.segments(from: attributed)

        XCTAssertEqual(segments[1], .image("shot one.png", link: URL(fileURLWithPath: "/tmp/my shots/one.png")))
    }

    private static let longImageName = "CleanShot 2026-11-16 at 3.22.27 PM@2x.png"
    private static let longImageNameTruncated = "CleanShot 2026-11-16 …2.27 PM@2x.png"

    func testImageNameKeepsHeadAndTailAroundAnEllipsis() {
        XCTAssertEqual(FileChipText.middleTruncatedImageName(Self.longImageName), Self.longImageNameTruncated)
    }

    func testShortImageNameIsNotTruncated() {
        XCTAssertEqual(FileChipText.middleTruncatedImageName("shot.png"), "shot.png")
    }

    func testImageNameOneCharacterOverTheHeadAndTailIsKept() {
        // 21 head + 14 tail + 1 = 36 characters still reads in full.
        let name = String(repeating: "a", count: 32) + ".png"
        XCTAssertEqual(FileChipText.middleTruncatedImageName(name), name)
    }

    // 1,000-byte files read as "1 KB" with the file count style.
    private static let imageFileBytes = 1_000

    private func imageFileURL(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(count: Self.imageFileBytes).write(to: url)
        return url
    }

    private func imageLink(_ name: String, to url: URL) -> String {
        "[\(name)](\(url.absoluteString))"
    }

    func testDisplayedImageLinkCarriesTheShortenedNameAndSize() throws {
        let url = try imageFileURL("one.png")
        let displayed = FileChipText.displayAttributed(
            FileChipText.inlineAttributed("see \(imageLink(Self.longImageName, to: url))")
        )

        XCTAssertEqual(String(displayed.characters), "see \(Self.longImageNameTruncated) 1 KB")
    }

    func testCollapsingFourImageLinesKeepsTheFirstThree() throws {
        let markdown = try ["a.png", "b.png", "c.png", "d.png"]
            .map { imageLink($0, to: try imageFileURL($0)) }
            .joined(separator: "\n")
        let displayed = FileChipText.displayAttributed(FileChipText.inlineAttributed(markdown))

        let collapsed = PromptTailTruncation.collapsed(displayed, width: 400, lineLimit: 3) {
            FileChipText.measurementAttributedString(from: $0, fontSize: 13)
        }

        XCTAssertEqual(collapsed.map { String($0.characters) }, "a.png 1 KB\nb.png 1 KB\nc.png 1 KB…")
    }

    func testImageSizeFollowsTheFileWhenItIsOverwritten() throws {
        let url = try imageFileURL("shot.png")
        let attributed = FileChipText.inlineAttributed(imageLink("shot.png", to: url))
        _ = FileChipText.displayAttributed(attributed)
        try Data(count: 2_000).write(to: url)

        XCTAssertEqual(String(FileChipText.displayAttributed(attributed).characters), "shot.png 2 KB")
    }
}
