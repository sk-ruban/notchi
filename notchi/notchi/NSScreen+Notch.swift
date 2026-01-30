import AppKit

extension NSScreen {
    /// Returns the built-in MacBook display, falling back to the main screen
    static var builtInOrMain: NSScreen {
        screens.first { $0.isBuiltIn } ?? main!
    }

    /// Whether this screen is the built-in display (MacBook's internal screen)
    var isBuiltIn: Bool {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return false
        }
        return CGDisplayIsBuiltin(screenNumber) != 0
    }

    /// Whether this screen has a notch (safeAreaInsets.top > 0)
    var hasNotch: Bool {
        safeAreaInsets.top > 0
    }

    /// Calculates the notch dimensions for this screen
    var notchSize: CGSize {
        guard hasNotch else {
            return CGSize(width: 224, height: 38)
        }

        let fullWidth = frame.width
        let leftPadding = auxiliaryTopLeftArea?.width ?? 0
        let rightPadding = auxiliaryTopRightArea?.width ?? 0
        let notchWidth = fullWidth - leftPadding - rightPadding + 4
        let notchHeight = safeAreaInsets.top

        return CGSize(width: notchWidth, height: notchHeight)
    }

    /// Calculates the window frame centered at the notch position
    var notchWindowFrame: CGRect {
        let size = notchSize
        let originX = frame.origin.x + (frame.width - size.width) / 2
        let originY = frame.maxY - size.height
        return CGRect(x: originX, y: originY, width: size.width, height: size.height)
    }
}
