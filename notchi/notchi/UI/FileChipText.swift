import AppKit
import SwiftUI

enum ChipSurface {
    case userBubble
    case panel

    var chipForeground: Color {
        switch self {
        case .userBubble: .white
        case .panel: Color.white.opacity(0.92)
        }
    }
}

enum FileChipText {
    struct IconStyle: Equatable {
        let assetName: String
        let tint: Color
    }

    private static let orange = Color(red: 1.0, green: 0.64, blue: 0.35)
    private static let blue = Color(red: 0.41, green: 0.69, blue: 1.0)
    private static let yellow = Color(red: 1.0, green: 0.83, blue: 0.32)
    private static let green = Color(red: 0.37, green: 0.8, blue: 0.44)
    private static let cyan = Color(red: 0.41, green: 0.8, blue: 0.95)

    private static let iconByExtension: [String: IconStyle] = {
        var map: [String: IconStyle] = [:]
        func add(_ exts: [String], _ asset: String, _ tint: Color) {
            for ext in exts { map[ext] = IconStyle(assetName: "fileicon_\(asset)", tint: tint) }
        }
        add(["swift"], "swift", orange)
        add(["ts", "tsx"], "typescript", blue)
        add(["js", "jsx", "mjs", "cjs"], "javascript", yellow)
        add(["sh", "bash", "zsh"], "bash", green)
        add(["py"], "python", blue)
        add(["rs"], "rust", orange)
        add(["go"], "go", cyan)
        return map
    }()

    private static let chippableExtensions: Set<String> = Set(iconByExtension.keys).union([
        "json", "xcstrings", "md", "markdown", "yml", "yaml",
        "html", "htm", "css", "scss", "txt", "log",
    ])

    static func iconStyle(forFilename filename: String) -> IconStyle? {
        let basename = filename.lowercased()
        guard let dot = basename.lastIndex(of: "."), dot != basename.startIndex else {
            return nil
        }
        return iconByExtension[String(basename[basename.index(after: dot)...])]
    }

    static func isFilenameShaped(_ text: String) -> Bool {
        text.wholeMatch(of: /\.?[A-Za-z0-9_][A-Za-z0-9_.+-]*\.[A-Za-z0-9]{1,12}/) != nil
            && !text.hasSuffix(".")
    }

    private static let knownExtensionPattern: Regex<AnyRegexOutput>? = {
        let exts = chippableExtensions.sorted { $0.count > $1.count }.joined(separator: "|")
        return try? Regex("\\b[A-Za-z0-9_][A-Za-z0-9_.+-]*\\.(?:\(exts))\\b")
    }()

    enum Segment: Equatable {
        case plain(AttributedString)
        case code(String)
        case chip(String, link: URL? = nil)
    }

    static func inlineAttributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }

    private static func localFileLink(_ link: URL) -> URL? {
        if link.isFileURL { return link }
        guard link.scheme == nil, link.path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: link.path)
    }

    static func segments(from attributed: AttributedString) -> [Segment] {
        var result: [Segment] = []

        func appendPlainScanningFilenames(_ sub: AttributedString) {
            guard let pattern = knownExtensionPattern else {
                result.append(.plain(sub))
                return
            }
            let text = String(sub.characters)
            var cursor = text.startIndex
            for match in text.matches(of: pattern) {
                if match.range.lowerBound > cursor {
                    result.append(.plain(slice(sub, in: text, from: cursor, to: match.range.lowerBound)))
                }
                result.append(.chip(String(text[match.range])))
                cursor = match.range.upperBound
            }
            if cursor < text.endIndex {
                result.append(.plain(slice(sub, in: text, from: cursor, to: text.endIndex)))
            }
        }

        for run in attributed.runs {
            let sub = AttributedString(attributed[run.range])
            let text = String(sub.characters)
            let isCode = run.inlinePresentationIntent?.contains(.code) == true

            if isCode {
                result.append(isFilenameShaped(text) ? .chip(text) : .code(text))
            } else if let link = run.link {
                let basename = (text as NSString).lastPathComponent
                if let fileLink = localFileLink(link), isFilenameShaped(basename) {
                    result.append(.chip(basename, link: fileLink))
                } else {
                    result.append(.plain(sub))
                }
            } else {
                appendPlainScanningFilenames(sub)
            }
        }
        return result
    }

    private static func slice(
        _ sub: AttributedString, in text: String,
        from: String.Index, to: String.Index
    ) -> AttributedString {
        let lower = sub.characters.index(sub.startIndex, offsetBy: text.distance(from: text.startIndex, to: from))
        let upper = sub.characters.index(sub.startIndex, offsetBy: text.distance(from: text.startIndex, to: to))
        return AttributedString(sub[lower..<upper])
    }

    /// Rewrites local file links to their basename so the string's characters match what is drawn,
    /// which lets callers slice it (e.g. for truncation) before rendering.
    static func displayAttributed(_ attributed: AttributedString) -> AttributedString {
        var result = AttributedString()
        for run in attributed.runs {
            var piece = AttributedString(attributed[run.range])
            if let link = run.link, run.inlinePresentationIntent?.contains(.code) != true {
                let text = String(piece.characters)
                let basename = (text as NSString).lastPathComponent
                if localFileLink(link) != nil, isFilenameShaped(basename), basename != text {
                    piece = AttributedString(basename, attributes: run.attributes)
                }
            }
            result.append(piece)
        }
        return result
    }

    /// Mirrors the fonts `render` uses so TextKit can lay the text out the way SwiftUI will.
    static func measurementAttributedString(
        from attributed: AttributedString,
        fontSize: CGFloat,
        fontScale: CGFloat = 1
    ) -> NSAttributedString {
        let scaledSize = fontSize * fontScale
        let baseFont = NSFont.systemFont(ofSize: scaledSize)
        let boldFont = NSFont.boldSystemFont(ofSize: scaledSize)
        let chipFont = NSFont.monospacedSystemFont(ofSize: scaledSize - 1, weight: .medium)
        let iconAdvance = (scaledSize - 2) + ("\u{202F}" as NSString).size(withAttributes: [.font: baseFont]).width

        let output = NSMutableAttributedString()
        for segment in segments(from: attributed) {
            switch segment {
            case .plain(let sub):
                for run in sub.runs {
                    let isBold = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                    output.append(NSAttributedString(
                        string: String(sub[run.range].characters),
                        attributes: [.font: isBold ? boldFont : baseFont]
                    ))
                }
            case .code(let code):
                output.append(NSAttributedString(string: code, attributes: [.font: chipFont]))
            case .chip(let name, _):
                let chip = NSMutableAttributedString(string: name, attributes: [.font: chipFont])
                if iconStyle(forFilename: name) != nil, !name.isEmpty {
                    chip.addAttribute(.kern, value: iconAdvance, range: NSRange(location: 0, length: 1))
                }
                output.append(chip)
            }
        }
        return output
    }

    static func render(
        markdown: String,
        surface: ChipSurface,
        baseColor: Color,
        fontSize: CGFloat,
        fontScale: CGFloat = 1
    ) -> Text {
        render(
            attributed: inlineAttributed(markdown),
            surface: surface,
            baseColor: baseColor,
            fontSize: fontSize,
            fontScale: fontScale
        )
    }

    static func render(
        attributed: AttributedString,
        surface: ChipSurface,
        baseColor: Color,
        fontSize: CGFloat,
        fontScale: CGFloat = 1
    ) -> Text {
        let scaledSize = fontSize * fontScale
        let chipFont = Font.system(size: scaledSize - 1, design: .monospaced).weight(.medium)

        var output = Text(verbatim: "")
        for segment in segments(from: attributed) {
            switch segment {
            case .plain(var sub):
                sub.foregroundColor = nil
                output = output + SwiftUI.Text(sub).foregroundColor(baseColor)
            case .code(let code):
                output = output + SwiftUI.Text(styled(code, surface: surface)).font(chipFont)
            case .chip(let name, let link):
                if let icon = iconStyle(forFilename: name),
                   let image = sizedIcon(icon.assetName, pointSize: scaledSize - 2) {
                    output = output
                        + SwiftUI.Text(image)
                            .foregroundColor(icon.tint)
                            .baselineOffset(-scaledSize * 0.1)
                        + SwiftUI.Text(verbatim: "\u{202F}")
                }
                output = output + SwiftUI.Text(styled(name, surface: surface, link: link)).font(chipFont)
            }
        }
        return output
    }

    private static func styled(_ text: String, surface: ChipSurface, link: URL? = nil) -> AttributedString {
        var styled = AttributedString(text)
        styled.foregroundColor = surface.chipForeground
        styled.link = link
        return styled
    }

    private static var sizedIconCache: [String: Image] = [:]

    private static func sizedIcon(_ assetName: String, pointSize: CGFloat) -> Image? {
        let key = "\(assetName)@\(pointSize)"
        if let cached = sizedIconCache[key] { return cached }
        guard let resized = NSImage(named: assetName)?.copy() as? NSImage else { return nil }
        resized.size = NSSize(width: pointSize, height: pointSize)
        let image = Image(nsImage: resized)
        sizedIconCache[key] = image
        return image
    }
}
