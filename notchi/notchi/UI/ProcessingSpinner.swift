import Combine
import SwiftUI

struct ProcessingSpinner: View {
    @State private var phase = 0

    private let symbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private let timer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(symbols[phase % symbols.count])
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(TerminalColors.claudeOrange)
            .frame(width: 12, alignment: .center)
            .onReceive(timer) { _ in
                phase = (phase + 1) % symbols.count
            }
    }
}
