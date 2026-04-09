import SwiftUI

struct GrowthIndicatorView: View {
    let service: TokenGrowthService
    var compact: Bool = false

    private var stage: GrowthStage { service.currentStage }
    private var progress: Double { service.progressToNextStage }
    private var totalFormatted: String { TokenGrowthService.formatTokens(service.weeklyTokens) }

    private var stageColor: Color {
        switch stage {
        case .egg:       return TerminalColors.dimmedText
        case .larva:     return TerminalColors.green
        case .pupa:      return TerminalColors.amber
        case .butterfly: return TerminalColors.claudeOrange
        case .radiant:   return Color(red: 0.85, green: 0.65, blue: 1.0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 4) {
                    Text(stage.emoji)
                        .font(.system(size: 10))
                    if service.justLeveledUp {
                        Text("Level Up! \(stage.displayName)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(stageColor)
                    } else {
                        Text(stage.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(TerminalColors.secondaryText)
                    }
                }

                Spacer()

                Text(totalFormatted + " tokens")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(stageColor)
            }

            progressBar
        }
        .padding(.top, compact ? 0 : 5)
    }

    private var progressBar: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(TerminalColors.subtleBackground)
                .frame(height: 4)

            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: 0.4, green: 0.78, blue: 1.0))
                    .frame(width: geometry.size.width * progress, height: 4)
                    .animation(.easeInOut(duration: 0.4), value: progress)
            }
            .frame(height: 4)
        }
    }
}
