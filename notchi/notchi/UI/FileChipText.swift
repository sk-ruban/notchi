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
        return try? Regex("\\b[A-Za-z0-9_][A-Za-z0-9_+-]*\\.(?:\(exts))\\b")
    }()

    enum Segment: Equatable {
        case plain(AttributedString)
        case code(String)
        case chip(String)
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
            } else if run.link != nil {
                let basename = (text as NSString).lastPathComponent
                if isFilenameShaped(basename) {
                    result.append(.chip(basename))
                } else {
                    appendPlainScanningFilenames(sub)
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

    static func render(
        markdown: String,
        surface: ChipSurface,
        baseColor: Color,
        fontSize: CGFloat,
        fontScale: CGFloat = 1
    ) -> Text {
        let attributed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)

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
            case .chip(let name):
                if let icon = iconStyle(forFilename: name),
                   let image = sizedIcon(icon.assetName, pointSize: scaledSize - 2) {
                    output = output
                        + SwiftUI.Text(image)
                            .foregroundColor(icon.tint)
                            .baselineOffset(-scaledSize * 0.1)
                        + SwiftUI.Text(verbatim: "\u{202F}")
                        + SwiftUI.Text(styled(name, surface: surface)).font(chipFont)
                } else {
                    output = output + SwiftUI.Text(styled(name, surface: surface)).font(chipFont)
                }
            }
        }
        return output
    }

    private static func styled(_ text: String, surface: ChipSurface) -> AttributedString {
        var styled = AttributedString(text)
        styled.foregroundColor = surface.chipForeground
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
