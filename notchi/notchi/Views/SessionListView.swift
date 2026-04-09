import SwiftUI

struct SessionListView: View {
    let sessions: [SessionData]
    let titleForSession: (SessionData) -> String
    let selectedSessionId: String?
    let onSelectSession: (String) -> Void
    let onDeleteSession: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sessions")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(TerminalColors.secondaryText)
                .padding(.top, 8)
                .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(sessions) { session in
                        SessionRowView(
                            session: session,
                            title: titleForSession(session),
                            isSelected: session.id == selectedSessionId,
                            onTap: { onSelectSession(session.id) },
                            onDelete: { onDeleteSession(session.id) }
                        )
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }
}
