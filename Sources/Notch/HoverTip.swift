import SwiftUI

/// Tooltip that works inside the notch panel. `.help()` relies on AppKit
/// tooltips, which only appear for the active app, and Zumbo is never the
/// active app (nonactivating panel, LSUIElement). So every icon reports its
/// own label after a short hover, and a single layer at the panel's root
/// draws it - never in place over the icon, which used to hide it (e.g. the
/// grid toggle's "Show as a row" label drawn right on top of the glyph).
///
/// `HoverTip` itself renders nothing: it reports `(text, Anchor<CGRect>)` via
/// `HoverTipPreferenceKey` after the hover holds 350 ms. `hoverTipLayer()`,
/// attached once at each panel root (`ExpandedPanelView`, the small states in
/// `NotchRootView`, `HistoryDetailPanelView`), consumes that and draws one
/// label: below the icon by default, above it if there is no room below,
/// horizontally centered on the icon and clamped 8 pt inside the root's own
/// bounds. Two attachment points nested inside one another would draw the
/// same tooltip twice (preferences keep bubbling past the first consumer), so
/// every attachment point in this file is a leaf with respect to the others -
/// see the call sites.
/// True while any menu (a SwiftUI `Menu`, the menu bar item) is tracking the
/// mouse. AppKit keeps the pointer "inside" the control that opened the menu,
/// so without this a tooltip would sit on top of the open dropdown. Tips hide
/// the moment a menu opens and only return after the pointer leaves and
/// re-enters a control.
@MainActor
final class MenuTracking: ObservableObject {
    static let shared = MenuTracking()
    @Published private(set) var menuOpen = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MenuTracking.shared.menuOpen = true }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MenuTracking.shared.menuOpen = false }
            },
        ]
    }
}

struct HoverTip: ViewModifier {
    let text: String
    @State private var id = UUID()
    @State private var hovering = false
    @State private var visible = false
    @ObservedObject private var menus = MenuTracking.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: menus.menuOpen) { _, open in
                guard open else { return }
                hovering = false
                visible = false
            }
            .onHover { inside in
                hovering = inside
                if inside {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        if hovering, !menus.menuOpen {
                            withAnimation(.easeOut(duration: 0.12)) { visible = true }
                        }
                    }
                } else {
                    withAnimation(.easeIn(duration: 0.08)) { visible = false }
                }
            }
            .anchorPreference(key: HoverTipPreferenceKey.self, value: .bounds) { anchor in
                visible && !menus.menuOpen ? [HoverTipInfo(id: id, text: text, anchor: anchor)] : []
            }
            .accessibilityLabel(text)
    }
}

extension View {
    /// A hover tooltip for icon buttons, see `HoverTip`. Text may be empty
    /// for a disabled button with no label to show; it just never becomes
    /// visible.
    func hoverTip(_ text: String) -> some View {
        modifier(HoverTip(text: text))
    }
}

// MARK: - Preference plumbing

struct HoverTipInfo: Identifiable {
    let id: UUID
    let text: String
    let anchor: Anchor<CGRect>
}

struct HoverTipPreferenceKey: PreferenceKey {
    static let defaultValue: [HoverTipInfo] = []
    static func reduce(value: inout [HoverTipInfo], nextValue: () -> [HoverTipInfo]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - Layout

/// Pure geometry, no SwiftUI state, so it is trivially testable by eye: given
/// the icon's resolved rect and the root's size, where does the label go.
enum HoverTipLayout {
    static let gap: CGFloat = 6
    static let edgeInset: CGFloat = 8
    /// 10 pt medium text plus 4 pt vertical padding top and bottom.
    static let estimatedHeight: CGFloat = 21

    /// The brief says estimate at 6.2 pt/character + 14 rather than measure
    /// with a hidden Text, since every label here is a short, known string.
    static func estimatedWidth(for text: String) -> CGFloat {
        max(24, CGFloat(text.count) * 6.2 + 14)
    }

    /// Center point for the label, below the icon by default, above it only
    /// when below does not fit, horizontally clamped 8 pt inside `rootSize`.
    static func center(for iconRect: CGRect, text: String, in rootSize: CGSize) -> CGPoint {
        let width = estimatedWidth(for: text)
        let halfWidth = width / 2
        let height = estimatedHeight

        let spaceBelow = rootSize.height - iconRect.maxY
        let spaceAbove = iconRect.minY
        let fitsBelow = spaceBelow >= gap + height + edgeInset
        let showBelow = fitsBelow || spaceAbove < gap + height + edgeInset

        let y = showBelow
            ? iconRect.maxY + gap + height / 2
            : iconRect.minY - gap - height / 2

        let minX = edgeInset + halfWidth
        let maxX = max(minX, rootSize.width - edgeInset - halfWidth)
        let x = min(max(iconRect.midX, minX), maxX)
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Rendering

/// The floating label itself: 10 pt medium, white 95%, dark grey pill (white
/// 16%), 1 px white 12% border, 6 pt radius.
private struct HoverTipLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .fixedSize()
    }
}

/// Consumes every `hoverTip` reported inside this subtree and draws it as a
/// floating, non-interactive label positioned by `HoverTipLayout`. Attach
/// once at a panel root; see the file doc comment for why attachment points
/// must not nest.
private struct HoverTipLayerModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(HoverTipPreferenceKey.self) { infos in
            GeometryReader { proxy in
                // Only the innermost hovered control speaks: when a card and an
                // icon inside it both report, the smaller anchor wins.
                let innermost = infos.min { lhs, rhs in
                    let a = proxy[lhs.anchor], b = proxy[rhs.anchor]
                    return a.width * a.height < b.width * b.height
                }
                ForEach(innermost.map { [$0] } ?? []) { info in
                    let iconRect = proxy[info.anchor]
                    let center = HoverTipLayout.center(for: iconRect, text: info.text, in: proxy.size)
                    HoverTipLabel(text: info.text)
                        .position(center)
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

extension View {
    /// See `HoverTipLayerModifier`.
    func hoverTipLayer() -> some View {
        modifier(HoverTipLayerModifier())
    }
}
