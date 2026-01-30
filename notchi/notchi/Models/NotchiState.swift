enum NotchiState: String, CaseIterable {
    case idle, thinking, working, happy, alert, sleeping

    var sfSymbolName: String {
        switch self {
        case .idle:     return "face.smiling"
        case .thinking: return "ellipsis.circle"
        case .working:  return "hammer"
        case .happy:    return "face.smiling.fill"
        case .alert:    return "exclamationmark.triangle"
        case .sleeping: return "moon.zzz"
        }
    }

    var bobDuration: Double {
        switch self {
        case .sleeping: return 4.0
        case .idle:     return 1.5
        case .thinking: return 0.8
        case .working:  return 0.4
        case .happy:    return 0.6
        case .alert:    return 0.3
        }
    }
}
