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

    static let nonNotchWidth: CGFloat = 224
    static let fallbackMenuBarHeight: CGFloat = 24

    static func nonNotchSize(menuBarHeight: CGFloat) -> CGSize {
        CGSize(
            width: nonNotchWidth,
            height: menuBarHeight > 0 ? menuBarHeight : fallbackMenuBarHeight
        )
    }

    /// Calculates the notch dimensions for this screen
    var notchSize: CGSize {
        let menuBarHeight = frame.maxY - visibleFrame.maxY
        guard hasNotch else {
            return Self.nonNotchSize(menuBarHeight: menuBarHeight)
        }

        let fullWidth = frame.width
        let leftPadding = auxiliaryTopLeftArea?.width ?? 0
        let rightPadding = auxiliaryTopRightArea?.width ?? 0
        let notchWidth = fullWidth - leftPadding - rightPadding + 4
        let notchHeight = max(safeAreaInsets.top, menuBarHeight)

        return CGSize(width: notchWidth, height: notchHeight)
    }

    /// Extracts the exact notch shape from the system's bezel path in local notch coordinates.
    /// Returns nil if bezelPath is unavailable or the screen has no notch.
    var notchPath: CGPath? {
        guard hasNotch,
              responds(to: Selector(("bezelPath"))),
              let bezierPath = value(forKey: "bezelPath") as? NSBezierPath else {
            return nil
        }

        let screenTop = frame.height
        let screenCenterX = frame.width / 2

        // Walk the bezel path to find the notch sub-path.
        // The notch is the portion of the path that dips below the top edge of the screen.
        var points = [NSPoint](repeating: .zero, count: 3)
        var notchElements: [(type: NSBezierPath.ElementType, points: [NSPoint])] = []
        var inNotch = false
        var currentPoint: NSPoint = .zero

        let notchLeftEdge = auxiliaryTopLeftArea?.maxX ?? 0
        let notchRightEdge = auxiliaryTopRightArea?.minX ?? frame.width

        for i in 0..<bezierPath.elementCount {
            let element = bezierPath.element(at: i, associatedPoints: &points)
            let endPoint: NSPoint
            switch element {
            case .moveTo, .lineTo:
                endPoint = points[0]
            case .curveTo, .cubicCurveTo:
                endPoint = points[2]
            case .quadraticCurveTo:
                endPoint = points[1]
            case .closePath:
                continue
            @unknown default:
                continue
            }

            // Detect entering the notch: a curve/line that moves below the top edge
            if !inNotch && endPoint.y < screenTop - 1 {
                if endPoint.x >= notchLeftEdge - 20 && endPoint.x <= notchRightEdge + 20 {
                    inNotch = true
                    // Insert the previous current point as the curve's proper start
                    notchElements.append((.moveTo, [currentPoint]))
                    notchElements.append((element, Array(points.prefix(3))))
                    currentPoint = endPoint
                    continue
                }
            }

            if inNotch {
                notchElements.append((element, Array(points.prefix(3))))
                if endPoint.y >= screenTop - 1 {
                    inNotch = false
                    break
                }
            }

            currentPoint = endPoint
        }

        guard !notchElements.isEmpty else { return nil }

        // Build the notch CGPath, translating from screen coords to a local coordinate
        // system where (0,0) is the top-left of the notch and Y increases downward.
        let notchLeft = auxiliaryTopLeftArea?.maxX ?? (screenCenterX - notchSize.width / 2)

        func tx(_ p: NSPoint) -> CGPoint {
            CGPoint(x: p.x - notchLeft, y: screenTop - p.y)
        }

        let cgPath = CGMutablePath()

        for (element, pts) in notchElements {
            switch element {
            case .moveTo:
                cgPath.move(to: tx(pts[0]))
            case .lineTo:
                cgPath.addLine(to: tx(pts[0]))
            case .curveTo, .cubicCurveTo:
                cgPath.addCurve(to: tx(pts[2]), control1: tx(pts[0]), control2: tx(pts[1]))
            case .quadraticCurveTo:
                cgPath.addQuadCurve(to: tx(pts[1]), control: tx(pts[0]))
            default:
                break
            }
        }

        // Close the path along the top edge
        cgPath.closeSubpath()

        // Validate: extracted path should roughly match expected notch dimensions
        let pathBounds = cgPath.boundingBox
        guard pathBounds.width > notchSize.width * 0.5,
              pathBounds.height > notchSize.height * 0.5,
              pathBounds.width < notchSize.width * 2,
              pathBounds.height < notchSize.height * 2 else {
            return nil
        }

        return cgPath
    }
}
