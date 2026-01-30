import SwiftUI

struct ToolArgumentsView: View {
    let arguments: [String: Any]

    private var sortedKeys: [String] {
        arguments.keys.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(sortedKeys, id: \.self) { key in
                HStack(alignment: .top, spacing: 8) {
                    Text(key)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(TerminalColors.secondaryText)
                        .frame(minWidth: 60, alignment: .leading)

                    Text(formatValue(arguments[key]))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(TerminalColors.primaryText)
                        .lineLimit(3)
                }
            }
        }
        .padding(8)
        .background(TerminalColors.subtleBackground)
        .cornerRadius(6)
    }

    private func formatValue(_ value: Any?) -> String {
        guard let value else { return "null" }

        switch value {
        case let string as String:
            let truncated = string.count > 200 ? String(string.prefix(200)) + "…" : string
            return truncated
        case let number as NSNumber:
            return number.stringValue
        case let bool as Bool:
            return bool ? "true" : "false"
        case let array as [Any]:
            return "[\(array.count) items]"
        case let dict as [String: Any]:
            return "{\(dict.count) keys}"
        default:
            return String(describing: value)
        }
    }
}
