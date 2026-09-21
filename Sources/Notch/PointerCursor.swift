import SwiftUI

private struct PointerCursor: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

extension View {
    /// Pointing hand on hover, for anything clickable that is not a system control.
    func pointer() -> some View { modifier(PointerCursor()) }
}
