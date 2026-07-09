import SwiftUI

struct UsageBarView: View {
    let usage: QuotaPeriod?
    let isUsingExtraUsage: Bool
    let isLoading: Bool
    let error: String?
    let statusMessage: String?
    let isStale: Bool
    let recoveryAction: ClaudeUsageRecoveryAction
    let label: String
    var resetLabelPrefix: String?
    var compact: Bool = false
    var isEnabled: Bool = AppSettings.isUsageEnabled
    var onConnect: (() -> Void)?
    var onRetry: (() -> Void)?
    var onOpenDetail: (() -> Void)?

    @State private var isPulsing = false

    init(
        usage: QuotaPeriod?,
        isUsingExtraUsage: Bool = false,
        isLoading: Bool,
        error: String?,
        statusMessage: String?,
        isStale: Bool,
        recoveryAction: ClaudeUsageRecoveryAction,
        label: String = "Claude Usage",
        resetLabelPrefix: String? = nil,
        compact: Bool = false,
        isEnabled: Bool = AppSettings.isUsageEnabled,
        onConnect: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil,
        onOpenDetail: (() -> Void)? = nil
    ) {
        self.usage = usage
        self.isUsingExtraUsage = isUsingExtraUsage
        self.isLoading = isLoading
        self.error = error
        self.statusMessage = statusMessage
        self.isStale = isStale
        self.recoveryAction = recoveryAction
        self.label = label
        self.resetLabelPrefix = resetLabelPrefix
        self.compact = compact
        self.isEnabled = isEnabled
        self.onConnect = onConnect
        self.onRetry = onRetry
        self.onOpenDetail = onOpenDetail
    }

    var shouldShowRecoveryButton: Bool {
        switch recoveryAction {
        case .retry, .reconnect:
            return true
        case .waitForClaudeCode, .none:
            return false
        }
    }

    var recoveryActionLabel: String {
        switch recoveryAction {
        case .retry:
            return String(localized: "Retry")
        case .reconnect:
            return String(localized: "Reconnect")
        case .waitForClaudeCode:
            return String(localized: "Open Claude Code")
        case .none:
            return ""
        }
    }

    func performRecoveryAction() {
        switch recoveryAction {
        case .retry:
            onRetry?()
        case .reconnect, .waitForClaudeCode:
            onConnect?()
        case .none:
            break
        }
    }

    private var effectivePercentage: Int {
        guard let usage, !usage.isExpired else { return 0 }
        return usage.usagePercentage
    }

    var barFillPercentage: Int {
        min(max(effectivePercentage, 0), 100)
    }

    private var usageColor: Color {
        guard usage != nil else { return TerminalColors.dimmedText }
        if isStale { return TerminalColors.dimmedText }
        switch effectivePercentage {
        case ..<50: return TerminalColors.green
        case ..<80: return TerminalColors.amber
        default: return TerminalColors.red
        }
    }

    var shouldShowExtraUsageIndicator: Bool {
        usage != nil && isUsingExtraUsage && !isStale
    }

    var shouldShowConnectPlaceholder: Bool {
        !isEnabled
            && usage == nil
            && !isLoading
            && error == nil
            && statusMessage == nil
            && !isStale
            && recoveryAction == .none
    }

    func resetLabelText(for resetTime: String) -> String {
        if let resetLabelPrefix {
            return String(localized: "\(resetLabelPrefix) resets in \(resetTime)")
        }
        return String(localized: "Resets in \(resetTime)")
    }

    var body: some View {
        if shouldShowConnectPlaceholder {
            Button(action: { onConnect?() }) {
                HStack(spacing: 4) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 10))
                    Text("Tap to show Claude usage")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(TerminalColors.dimmedText)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.top, 3)
            .padding(.leading, 2)
            .padding(.bottom, -7)
        } else {
            connectedView
        }
    }

    private var connectedView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let error, usage == nil {
                    Text(error)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(TerminalColors.red.opacity(0.8))
                } else if let usage, let resetTime = usage.formattedResetTime {
                    HStack(alignment: .center, spacing: 4) {
                        Text(resetLabelText(for: resetTime))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(TerminalColors.secondaryText)
                            .lineLimit(1)
                        if let statusMessage {
                            Text("• \(statusMessage)")
                                .font(.system(size: 10))
                                .foregroundColor(Color.white.opacity(0.35))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                } else if let statusMessage, usage != nil {
                    Text(statusMessage)
                        .font(.system(size: 10))
                        .foregroundColor(TerminalColors.dimmedText)
                } else {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(TerminalColors.secondaryText)
                }
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    HStack(alignment: .center, spacing: 6) {
                        if shouldShowExtraUsageIndicator {
                            Text("Extra Usage")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(TerminalColors.red.opacity(0.85))
                                .lineLimit(1)
                        }
                        if onOpenDetail != nil {
                            Image(systemName: "chart.bar.xaxis")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(TerminalColors.secondaryText)
                        }
                        if usage != nil {
                            Text("\(effectivePercentage)%")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(usageColor)
                        }
                        if shouldShowRecoveryButton {
                            recoveryButton
                        }
                    }
                    .padding(.bottom, 1)
                }
            }

            progressBar
        }
        .padding(.top, compact ? 0 : 5)
        .contentShape(Rectangle())
        .onTapGesture { onOpenDetail?() }
    }

    private var recoveryButton: some View {
        Button(action: performRecoveryAction) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isStale ? TerminalColors.secondaryText : TerminalColors.red.opacity(0.8))
                .opacity(isPulsing ? 0.8 : 1.0)
                .offset(y: -1)
                .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: isPulsing)
        }
        .buttonStyle(RecoveryButtonStyle())
        .help(recoveryActionLabel)
        .accessibilityLabel(recoveryActionLabel)
        .onAppear { isPulsing = true }
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(TerminalColors.subtleBackground)

                if usage != nil {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(usageColor)
                        .frame(width: geometry.size.width * Double(barFillPercentage) / 100)
                }
            }
        }
        .frame(height: 4)
    }

}

private struct RecoveryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.8 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.45), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                }
            }
    }
}
