import SwiftUI

// Shared layout tokens keep the settings panel spacing consistent across rows and pickers.
@MainActor
enum SettingsLayout {
    static var scale: CGFloat = 1

    static var panelHorizontalPadding: CGFloat { 14 * scale }
    static var topPadding: CGFloat { 5 * scale }
    static var sectionSpacing: CGFloat { 8 * scale }
    static var rowVerticalPadding: CGFloat { 4 * scale }
    static var fieldHorizontalPadding: CGFloat { 8 * scale }
    static var fieldVerticalPadding: CGFloat { 5 * scale }
    static var quitButtonVerticalPadding: CGFloat { 8 * scale }
    static var quitButtonHorizontalPadding: CGFloat { 4 * scale }
    static var pickerInset: CGFloat { 6 * scale }
    static var pickerOptionHorizontalPadding: CGFloat { 10 * scale }
    static var pickerOptionVerticalPadding: CGFloat { 5 * scale }
    static var pickerRowSpacing: CGFloat { basePickerRowSpacing * scale }

    static let basePickerRowHeight: CGFloat = 28
    static let basePickerRowSpacing: CGFloat = 4
    static let pickerMaxVisibleRows = 6

    static func pickerViewportHeight(rowCount: Int, scale: CGFloat) -> CGFloat? {
        guard rowCount > pickerMaxVisibleRows else { return nil }
        return (CGFloat(pickerMaxVisibleRows) * basePickerRowHeight
            + CGFloat(pickerMaxVisibleRows - 1) * basePickerRowSpacing) * scale
    }

    static func pickerViewportHeight(rowCount: Int) -> CGFloat? {
        pickerViewportHeight(rowCount: rowCount, scale: scale)
    }
}
