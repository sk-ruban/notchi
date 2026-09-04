import Foundation

nonisolated struct UserPromptImageAttachment: Equatable, Hashable, Sendable {
    let displayName: String
    let path: String
}

nonisolated struct UserPromptContent: Equatable, Sendable {
    let text: String?
    let imageAttachments: [UserPromptImageAttachment]
    let hasAttachments: Bool
    let hasOtherAttachments: Bool
}

nonisolated enum UserPromptContentParser {
    private static let filesPreamble = "# Files mentioned by the user:"
    private static let requestMarkers = [
        "## My request for Codex:",
        "## My request:",
    ]
    private static let imageExtensions: Set<String> = [
        "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp",
    ]
    private static let inlineImageDescriptor = #/^[ \t]*\[Attached image\s+"([^"]+)"\s+is saved at:\s*([^\]\r\n]+)\][ \t]*$/#
    private struct AttachmentReference {
        let displayName: String
        let path: String
    }

    static func parse(
        _ rawPrompt: String?,
        reportedHasAttachments: Bool = false,
        supportsFilesPreamble: Bool = false
    ) -> UserPromptContent {
        let prompt = rawPrompt?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var lines = prompt.components(separatedBy: .newlines)
        var references: [AttachmentReference] = []
        var foundDescriptor = false

        if supportsFilesPreamble, prompt.hasPrefix(filesPreamble) {
            foundDescriptor = true
            let preamble = parseFilesPreamble(lines)
            lines = preamble.requestLines
            references.append(contentsOf: preamble.references)
        }

        var keptLines: [String] = []
        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            index += 1
            guard let match = line.wholeMatch(of: inlineImageDescriptor) else {
                keptLines.append(line)
                continue
            }

            foundDescriptor = true
            references.append(AttachmentReference(displayName: String(match.1), path: String(match.2)))

            let previousIsBlank = keptLines.last.map(isBlank) ?? true
            let nextIsBlank = index < lines.endIndex && isBlank(lines[index])
            if previousIsBlank && nextIsBlank {
                index += 1
            }
        }

        let text = keptLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var seenPaths: Set<String> = []
        let imageAttachments = references
            .compactMap(imageAttachment)
            .filter { seenPaths.insert($0.path).inserted }
        let hasNonImageReference = references.contains { imageAttachment(for: $0) == nil }

        return UserPromptContent(
            text: text.isEmpty ? nil : text,
            imageAttachments: imageAttachments,
            hasAttachments: reportedHasAttachments || foundDescriptor,
            hasOtherAttachments: hasNonImageReference || (reportedHasAttachments && imageAttachments.isEmpty)
        )
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func parseFilesPreamble(
        _ lines: [String]
    ) -> (requestLines: [String], references: [AttachmentReference]) {
        let requestMarkerIndex = lines.firstIndex {
            requestMarkers.contains($0.trimmingCharacters(in: .whitespaces))
        }
        let preambleEndIndex = requestMarkerIndex ?? lines.endIndex
        let references = lines[lines.index(after: lines.startIndex)..<preambleEndIndex]
            .compactMap(parseFilesPreambleLine)
        let requestLines = requestMarkerIndex.map { Array(lines.dropFirst($0 + 1)) } ?? []

        return (requestLines, references)
    }

    private static func parseFilesPreambleLine(_ rawLine: String) -> AttachmentReference? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("## ") else { return nil }

        let fileDescription = line.dropFirst(3)
        guard let separator = fileDescription.range(of: ": ") else { return nil }

        return AttachmentReference(
            displayName: String(fileDescription[..<separator.lowerBound]),
            path: String(fileDescription[separator.upperBound...])
        )
    }

    private static func imageAttachment(for reference: AttachmentReference) -> UserPromptImageAttachment? {
        let path = reference.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"),
              imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else {
            return nil
        }

        return UserPromptImageAttachment(
            displayName: reference.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            path: path
        )
    }
}
