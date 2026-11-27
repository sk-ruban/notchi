import Foundation

enum ExpandedPanelScale: String, CaseIterable, Identifiable {
    case automatic
    case standard
    case large

    static let automaticLargeMinimumHeight: CGFloat = 1100

    var id: String { rawValue }

    func resolved(visibleScreenHeight: CGFloat) -> ExpandedPanelScale {
        guard self == .automatic else { return self }
        return visibleScreenHeight >= Self.automaticLargeMinimumHeight ? .large : .standard
    }

    var multiplier: CGFloat {
        switch self {
        case .automatic, .standard: 1
        case .large: 1.25
        }
    }

    var displayName: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .standard: String(localized: "Standard")
        case .large: String(localized: "Large")
        }
    }
}
