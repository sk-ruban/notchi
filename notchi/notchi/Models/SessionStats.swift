import Foundation

private let promptMaxLength = 100

extension String {
    func truncatedForPrompt() -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > promptMaxLength else { return trimmed }
        let index = trimmed.index(trimmed.startIndex, offsetBy: promptMaxLength)
        return String(trimmed[..<index]) + "..."
    }
}

nonisolated enum ToolStatus: Equatable {
    case running
    case success
    case error
}

nonisolated struct AssistantMessage: Identifiable, Sendable {
    let id: String
    let text: String
    let timestamp: Date
}

nonisolated struct SessionEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let type: String
    let tool: String?
    var status: ToolStatus
    let toolUseId: String?
    let description: String?
}

extension SessionEvent {
    static func deriveDescription(tool: String?, toolInput: [String: Any]?) -> String? {
        guard let tool, let input = toolInput else { return nil }

        switch tool {
        case "Read":
            if let path = input["file_path"] as? String { return String(localized: "Reading \(path)", comment: "Tool activity; the argument is a file path.") }
        case "Write":
            if let path = input["file_path"] as? String { return String(localized: "Writing \(path)", comment: "Tool activity; the argument is a file path.") }
        case "Edit":
            if let path = input["file_path"] as? String { return String(localized: "Editing \(path)", comment: "Tool activity; the argument is a file path.") }
        case "Bash":
            if let command = input["command"] as? String {
                return command
            }
        case "Grep":
            if let pattern = input["pattern"] as? String {
                return String(localized: "Searching: \(pattern)", comment: "Tool activity searching file contents; the argument is the search pattern.")
            }
        case "Glob":
            if let pattern = input["pattern"] as? String {
                return String(localized: "Finding: \(pattern)", comment: "Tool activity finding files by name; the argument is a glob pattern.")
            }
        case "Task":
            if let desc = input["description"] as? String {
                return desc
            }
        default:
            break
        }

        for (_, value) in input {
            if let str = value as? String, !str.isEmpty {
                return str
            }
        }

        return nil
    }
}
