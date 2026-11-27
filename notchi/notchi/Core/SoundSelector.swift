import Foundation

@MainActor
@Observable
final class SoundSelector {
    var isPickerExpanded = false

    // The isolated-deinit back-deploy shim aborts on macOS 15; this deinit only releases stored properties.
    nonisolated deinit {}

    func rowCount(customSoundCount: Int) -> Int {
        1 + customSoundCount + NotificationSound.displayOrder.count
    }
}
