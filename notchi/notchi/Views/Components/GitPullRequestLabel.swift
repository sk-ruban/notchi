import SwiftUI

struct GitPullRequestLabel: View {
    let pullRequest: GitPullRequest

    var body: some View {
        Button {
            HapticService.shared.playNavigationTap()
            if let url = URL(string: pullRequest.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 3) {
                Image("GitPullRequest")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 10)
                Text(verbatim: "#\(pullRequest.number)")
                    .panelFont(size: 11, weight: .medium)
            }
            .foregroundColor(TerminalColors.pullRequest)
        }
        .buttonStyle(.plain)
    }
}
