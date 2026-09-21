import SwiftUI

/// The one shape the whole app morphs. Written for Zumbo, not copied from any
/// GPL notch project.
///
/// Geometry, in a rect whose top edge sits exactly on the screen edge:
/// - bottom corners are convex, radius `bottomRadius`
/// - top corners are inverted: concave quarter circles that flare outward into
///   the menu bar, so the black reads as hanging off the screen edge instead of
///   floating in front of it
///
/// The rect passed in includes the flares, so the straight "body" of the shape
/// is `width - 2 * topRadius` wide.
struct NotchShape: Shape {

    /// Radius of the two inverted (concave) top corners.
    var topRadius: CGFloat

    /// Radius of the two convex bottom corners.
    var bottomRadius: CGFloat

    init(topRadius: CGFloat = 10, bottomRadius: CGFloat = 12) {
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }

        // Clamp to half the current width and half the current height, so the
        // corners shrink with the shape instead of collapsing to square at
        // small sizes.
        let top = max(0, min(topRadius, rect.width / 2, rect.height / 2))
        let bottom = max(0, min(bottomRadius, (rect.width - 2 * top) / 2, rect.height / 2))

        let bodyMinX = rect.minX + top
        let bodyMaxX = rect.maxX - top

        // Outer top-left, on the screen edge.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Inverted top-left corner: quarter circle centered outside the body,
        // sweeping from straight up to the right, which carves a concave flare.
        if top > 0 {
            path.addArc(
                center: CGPoint(x: rect.minX, y: rect.minY + top),
                radius: top,
                startAngle: .degrees(-90),
                endAngle: .degrees(0),
                clockwise: false
            )
        }

        // Left edge down to the bottom-left corner.
        path.addLine(to: CGPoint(x: bodyMinX, y: rect.maxY - bottom))

        // Convex bottom-left corner.
        if bottom > 0 {
            path.addArc(
                center: CGPoint(x: bodyMinX + bottom, y: rect.maxY - bottom),
                radius: bottom,
                startAngle: .degrees(180),
                endAngle: .degrees(90),
                clockwise: true
            )
        }

        // Bottom edge.
        path.addLine(to: CGPoint(x: bodyMaxX - bottom, y: rect.maxY))

        // Convex bottom-right corner.
        if bottom > 0 {
            path.addArc(
                center: CGPoint(x: bodyMaxX - bottom, y: rect.maxY - bottom),
                radius: bottom,
                startAngle: .degrees(90),
                endAngle: .degrees(0),
                clockwise: true
            )
        }

        // Right edge back up.
        path.addLine(to: CGPoint(x: bodyMaxX, y: rect.minY + top))

        // Inverted top-right corner.
        if top > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX, y: rect.minY + top),
                radius: top,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
        }

        // Close along the screen edge.
        path.closeSubpath()
        return path
    }
}

#Preview("Notch shape") {
    VStack(spacing: 0) {
        NotchShape(topRadius: 12, bottomRadius: 16)
            .fill(.black)
            .frame(width: 320, height: 84)
        Spacer()
    }
    .frame(width: 520, height: 200)
    .background(Color.teal)
}
