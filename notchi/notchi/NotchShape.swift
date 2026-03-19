import SwiftUI

nonisolated struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    init(
        topCornerRadius: CGFloat = 6,
        bottomCornerRadius: CGFloat = 14
    ) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }
  
    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top-left corner curve (curves inward)
        path.addQuadCurve(
            to: CGPoint(
                x: rect.minX + topCornerRadius,
                y: rect.minY + topCornerRadius
            ),
            control: CGPoint(
                x: rect.minX + topCornerRadius,
                y: rect.minY
            )
        )

        // Left edge down to bottom-left corner
        path.addLine(
            to: CGPoint(
                x: rect.minX + topCornerRadius,
                y: rect.maxY - bottomCornerRadius
            )
        )

        // Bottom-left corner curve
        path.addQuadCurve(
            to: CGPoint(
                x: rect.minX + topCornerRadius + bottomCornerRadius,
                y: rect.maxY
            ),
            control: CGPoint(
                x: rect.minX + topCornerRadius,
                y: rect.maxY
            )
        )

        // Bottom edge
        path.addLine(
            to: CGPoint(
                x: rect.maxX - topCornerRadius - bottomCornerRadius,
                y: rect.maxY
            )
        )

        // Bottom-right corner curve
        path.addQuadCurve(
            to: CGPoint(
                x: rect.maxX - topCornerRadius,
                y: rect.maxY - bottomCornerRadius
            ),
            control: CGPoint(
                x: rect.maxX - topCornerRadius,
                y: rect.maxY
            )
        )

        // Right edge up to top-right corner
        path.addLine(
            to: CGPoint(
                x: rect.maxX - topCornerRadius,
                y: rect.minY + topCornerRadius
            )
        )

        // Top-right corner curve (curves inward)
        path.addQuadCurve(
            to: CGPoint(
                x: rect.maxX,
                y: rect.minY
            ),
            control: CGPoint(
                x: rect.maxX - topCornerRadius,
                y: rect.minY
            )
        )

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))

        return path
    }
}

/// A shape that draws the system notch path widened to fill the rect.
/// The path is split at its center X: the left half shifts left and the right
/// half shifts right by equal amounts, stretching only the flat bottom segment.
// CGPath is immutable; lacks formal Sendable conformance
nonisolated struct SystemNotchShape: Shape, @unchecked Sendable {
    let cgPath: CGPath

    func path(in rect: CGRect) -> Path {
        let bounds = cgPath.boundingBox
        guard bounds.width > 0 && bounds.height > 0 else { return Path() }

        let offsetX = rect.midX - bounds.midX
        let offsetY = rect.minY - bounds.minY
        let halfExtra = (rect.width - bounds.width) / 2
        let splitX = bounds.midX

        var path = Path()

        cgPath.applyWithBlock { ptr in
            let el = ptr.pointee
            let pts = el.points

            func tp(_ p: CGPoint) -> CGPoint {
                let shift = p.x < splitX ? -halfExtra : halfExtra
                return CGPoint(x: p.x + offsetX + shift, y: p.y + offsetY)
            }

            switch el.type {
            case .moveToPoint:
                path.move(to: tp(pts[0]))
            case .addLineToPoint:
                path.addLine(to: tp(pts[0]))
            case .addCurveToPoint:
                path.addCurve(
                    to: tp(pts[2]),
                    control1: tp(pts[0]),
                    control2: tp(pts[1])
                )
            case .addQuadCurveToPoint:
                path.addQuadCurve(
                    to: tp(pts[1]),
                    control: tp(pts[0])
                )
            case .closeSubpath:
                path.closeSubpath()
            @unknown default: break
            }
        }

        return path
    }
}
