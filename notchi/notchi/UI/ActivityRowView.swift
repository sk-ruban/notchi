import Combine
import SwiftUI

struct ActivityRowView: View {
    let event: SessionEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                bullet
                toolName
                if event.status != .running {
                    statusLabel
                }
            }

            if let description = event.description {
                Text(description)
                    .font(.system(size: 12).italic())
                    .foregroundColor(TerminalColors.dimmedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 13)
            }
        }
        .padding(.vertical, 4)
    }

    private var bullet: some View {
        Circle()
            .fill(bulletColor)
            .frame(width: 5, height: 5)
    }

    private var bulletColor: Color {
        switch event.status {
        case .running: return TerminalColors.amber
        case .success: return TerminalColors.green
        case .error: return TerminalColors.red
        }
    }

    private var toolName: some View {
        Text(event.tool ?? event.type)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(TerminalColors.primaryText)
    }

    private var statusLabel: some View {
        let isSuccess = event.status == .success
        return Text(isSuccess ? "Completed" : "Failed")
            .font(.system(size: 12))
            .foregroundColor(isSuccess ? TerminalColors.secondaryText : TerminalColors.red)
    }
}

struct QuestionPromptView: View {
    let questions: [PendingQuestion]
    @State private var currentIndex = 0

    private var clampedIndex: Int {
        min(currentIndex, questions.count - 1)
    }

    private var current: PendingQuestion {
        questions[clampedIndex]
    }

    private var hasMultipleQuestions: Bool {
        questions.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            questionHeader
            questionText
            optionsList
            answerHint
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TerminalColors.subtleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(TerminalColors.claudeOrange.opacity(0.3), lineWidth: 1)
        )
        .padding(.vertical, 4)
        .onChange(of: questions.count) {
            currentIndex = 0
        }
    }

    private var questionHeader: some View {
        HStack {
            if let header = current.header {
                Text(header)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(TerminalColors.claudeOrange)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }

            if hasMultipleQuestions {
                Text("(\(clampedIndex + 1)/\(questions.count))")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundColor(TerminalColors.secondaryText)
            }

            Spacer()

            if hasMultipleQuestions {
                paginationControls
            }
        }
    }

    private var paginationControls: some View {
        HStack(spacing: 2) {
            Button(action: { currentIndex = max(0, currentIndex - 1) }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(currentIndex > 0 ? TerminalColors.primaryText : TerminalColors.dimmedText)
            }
            .buttonStyle(.plain)
            .disabled(currentIndex == 0)

            Button(action: { currentIndex = min(questions.count - 1, currentIndex + 1) }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(currentIndex < questions.count - 1 ? TerminalColors.primaryText : TerminalColors.dimmedText)
            }
            .buttonStyle(.plain)
            .disabled(currentIndex == questions.count - 1)
        }
    }

    private var questionText: some View {
        Text(current.question)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(TerminalColors.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var optionsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(current.options.enumerated()), id: \.offset) { index, option in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(index + 1).")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundColor(TerminalColors.claudeOrange)
                        .frame(width: 16, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(TerminalColors.primaryText)
                        if let desc = option.description {
                            Text(desc)
                                .font(.system(size: 10))
                                .foregroundColor(TerminalColors.dimmedText)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private var answerHint: some View {
        Text("Answer in terminal")
            .font(.system(size: 10).italic())
            .foregroundColor(TerminalColors.dimmedText)
    }
}

struct WorkingIndicatorView: View {
    let state: NotchiState
    let workingVerb: String
    @State private var dotCount = 1
    @State private var symbolPhase = 0

    private let dotsTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    private let symbolTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    private var dots: String {
        String(repeating: ".", count: dotCount)
    }

    private var displaySymbol: String {
        WorkingIndicatorPresentation.symbol(for: state.task, phase: symbolPhase)
    }

    private var displayText: String {
        WorkingIndicatorPresentation.text(for: state.task, workingVerb: workingVerb, dots: dots)
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(displaySymbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(TerminalColors.claudeOrange)
                .frame(width: 14, alignment: .center)
            Text(displayText)
                .font(.system(size: 12, weight: .medium).italic())
                .foregroundColor(TerminalColors.claudeOrange)
        }
        .padding(.leading, -1)
        .onReceive(dotsTimer) { _ in
            dotCount = (dotCount % 3) + 1
        }
        .onReceive(symbolTimer) { _ in
            guard state.task != .waiting else { return }
            symbolPhase = (symbolPhase + 1) % WorkingIndicatorPresentation.animatedSymbols.count
        }
    }
}

enum WorkingIndicatorPresentation {
    static let animatedSymbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    static let waitingSymbol = "✳"

    static func symbol(for task: NotchiTask, phase: Int) -> String {
        if task == .waiting {
            return waitingSymbol
        }
        return animatedSymbols[phase % animatedSymbols.count]
    }

    static func text(for task: NotchiTask, workingVerb: String, dots: String) -> String {
        switch task {
        case .compacting:
            return "Compacting\(dots)"
        case .waiting:
            return "Waiting\(dots)"
        default:
            return "\(workingVerb)\(dots)"
        }
    }
}
