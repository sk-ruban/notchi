import SwiftUI

struct ExpandedPanelView: View {
    let state: NotchiState
    let stats: SessionStats

    private var isWorking: Bool {
        state == .working || state == .thinking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider().background(Color.white.opacity(0.08))
            statsSection

            if !stats.recentEvents.isEmpty {
                Divider().background(Color.white.opacity(0.08))
                activitySection
            }

            if stats.sessionStartTime == nil && stats.recentEvents.isEmpty {
                emptyState
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var headerSection: some View {
        HStack(spacing: 8) {
            if isWorking {
                ProcessingSpinner()
            }
            Text(state.displayName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.bottom, 16)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isWorking)
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            statRow(label: "Duration", value: stats.formattedDuration)
            statRow(label: "Events", value: "\(stats.eventCount) tool uses")
        }
        .padding(.vertical, 16)
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Activity")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(TerminalColors.secondaryText)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ZStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(stats.recentEvents.reversed()) { event in
                            ActivityRowView(event: event)
                        }
                    }
                }
                .frame(maxHeight: 200)

                VStack {
                    fadeGradient(direction: .top)
                    Spacer()
                    fadeGradient(direction: .bottom)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No active session")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(TerminalColors.secondaryText)
            Text("Run Claude in terminal")
                .font(.system(size: 12))
                .foregroundColor(TerminalColors.dimmedText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(TerminalColors.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(TerminalColors.primaryText)
        }
    }

    private func fadeGradient(direction: Edge) -> some View {
        LinearGradient(
            colors: [.black, .clear],
            startPoint: direction == .top ? .top : .bottom,
            endPoint: direction == .top ? .bottom : .top
        )
        .frame(height: 16)
    }
}
