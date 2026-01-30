import SwiftUI

struct ExpandedPanelView: View {
    let state: NotchiState
    let stats: SessionStats

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(state.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.bottom, 16)

            Divider()
                .background(Color.white.opacity(0.08))

            // Stats section
            VStack(alignment: .leading, spacing: 12) {
                statRow(label: "Duration", value: stats.formattedDuration)
                statRow(label: "Events", value: "\(stats.eventCount) tool uses")
            }
            .padding(.vertical, 16)

            if !stats.recentEvents.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.08))

                // Recent events section
                VStack(alignment: .leading, spacing: 0) {
                    Text("Recent Activity")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.top, 16)
                        .padding(.bottom, 12)

                    ForEach(stats.recentEvents) { event in
                        eventRow(event)
                            .padding(.vertical, 8)
                    }
                }
            }

            // Empty state when no session
            if stats.sessionStartTime == nil && stats.recentEvents.isEmpty {
                VStack(spacing: 8) {
                    Text("No active session")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                    Text("Run Claude in terminal")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.3))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.5))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
        }
    }

    private func eventRow(_ event: SessionEvent) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(event.success == false ? Color.red : Color.green)
                .frame(width: 8, height: 8)

            Text(event.tool ?? event.type)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.85))

            Spacer()

            Text(event.success == false ? "Failed" : "Completed")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
        }
    }
}
