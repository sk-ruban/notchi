import SwiftUI

struct ActivityRowView: View {
    let event: SessionEvent
    @State private var isExpanded = false

    private var hasExpandableContent: Bool {
        event.toolInput != nil && !(event.toolInput?.isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard hasExpandableContent else { return }
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    statusDot
                    toolName
                    Spacer()
                    if hasExpandableContent {
                        chevron
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, let input = event.toolInput {
                ToolArgumentsView(arguments: input)
                    .padding(.top, 8)
                    .padding(.leading, 18)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .modifier(PulsingModifier(isActive: event.status == .running))
    }

    private var statusColor: Color {
        switch event.status {
        case .running: return .white
        case .success: return TerminalColors.green
        case .error: return TerminalColors.red
        }
    }

    private var toolName: some View {
        Text(event.tool ?? event.type)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(TerminalColors.primaryText)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(TerminalColors.secondaryText)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
    }
}

private struct PulsingModifier: ViewModifier {
    let isActive: Bool
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? (isPulsing ? 0.4 : 1.0) : 1.0)
            .onAppear {
                guard isActive else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
            .onChange(of: isActive) { _, newValue in
                if newValue {
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                        isPulsing = true
                    }
                } else {
                    isPulsing = false
                }
            }
    }
}
