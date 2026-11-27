import SwiftUI

struct GitBranchLabel: View {
    let branch: String

    @State private var showsCopyConfirmation = false
    @State private var copyConfirmationTask: Task<Void, Never>?

    var body: some View {
        Button {
            HapticService.shared.playToggle()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(branch, forType: .string)
            copyConfirmationTask?.cancel()
            withAnimation(.easeInOut(duration: 0.15)) {
                showsCopyConfirmation = true
            }
            copyConfirmationTask = Task {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    showsCopyConfirmation = false
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image("GitBranch")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 10)
                Text(showsCopyConfirmation ? String(localized: "Copied!") : branch)
                    .panelFont(size: 11, weight: .medium)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .foregroundColor(TerminalColors.gitBranch)
        }
        .buttonStyle(.plain)
    }
}
