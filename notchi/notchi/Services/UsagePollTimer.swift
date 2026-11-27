import Foundation

protocol UsagePollTimer {
    func invalidate()
}

struct LiveUsagePollTimer: UsagePollTimer {
    let timer: Timer

    func invalidate() {
        timer.invalidate()
    }
}
