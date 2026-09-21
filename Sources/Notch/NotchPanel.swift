import AppKit

/// The single window Zumbo ever shows over the menu bar.
///
/// Window level: the assistive-tech high level (1500). The menu bar is 25 and a
/// fullscreen app's window can sit above that, so statusBar + 1 is not enough to
/// paint over fullscreen content. `.fullScreenAuxiliary` plus `.canJoinAllSpaces`
/// put the panel on every Space, fullscreen ones included, and the level has to
/// be re-applied on every order-front because AppKit can reset it.
///
/// This is above `NSWindow.Level.modalPanel` (8) and `.screenSaver` (1000),
/// which means it can sit on top of a system TCC consent alert (Input
/// Monitoring, Accessibility) too - those alerts do not register as an
/// "activated app" for `NSWorkspace`, so the panel never learns to get out
/// of their way on its own. Never lower this level to work around that:
/// `OnboardingCoordinator` compacts the panel to the small row instead
/// (docs/ARCHITECTURE.md "Permission steps and the three-state mark")
/// whenever a permission step might have one up, so the alert is always
/// clickable without the panel itself losing its place above everything
/// else.
final class NotchPanel: NSPanel {

    init() {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        level = Self.overlayLevel

        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        collectionBehavior = Self.overlayCollectionBehavior

        // Idle default. The controller flips this per state.
        ignoresMouseEvents = true
    }

    static let overlayLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))

    static let overlayCollectionBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

    /// Re-applies everything macOS is known to reset, then orders in front.
    /// `orderFrontRegardless` rather than `orderFront`, because Zumbo is never
    /// the active app.
    func bringFront() {
        level = Self.overlayLevel
        collectionBehavior = Self.overlayCollectionBehavior
        orderFrontRegardless()
    }

    /// Only the expanded state may take key status, and only because it has a
    /// search field. `.nonactivatingPanel` means the panel can receive keys
    /// without activating Zumbo, so the app the user was typing in stays
    /// frontmost and stays the paste target. Hover, recording and done never
    /// take keys.
    var isKeyCapable = false

    override var canBecomeKey: Bool { isKeyCapable }

    /// Never main. Zumbo is LSUIElement and has no main window.
    override var canBecomeMain: Bool { false }

    /// Set by the controller: true while the expanded panel's only scrollable
    /// content is vertical, i.e. the History grid layout or the Settings page.
    /// The axis swap below exists for the horizontal card row and must not
    /// run while this is set.
    var usesVerticalScroll = false

    /// Set by the horizontal filter-pill row while the pointer is over it,
    /// so a wheel or two-finger vertical swipe over the pills scrolls them
    /// sideways even while the rest of the panel scrolls vertically (grid
    /// layout, Settings). Cleared when the panel retracts.
    static var pointerOverHorizontalScroller = false

    /// The expanded panel's horizontal card row is its only scrollable content
    /// that runs sideways. A plain mouse wheel or a two-finger vertical swipe
    /// produces vertical deltas that a horizontal ScrollView ignores, so
    /// vertical-only scroll events are rewritten as horizontal ones before
    /// dispatch. Events that already carry a horizontal component pass
    /// through untouched. Bypassed entirely when `usesVerticalScroll` is set.
    override func sendEvent(_ event: NSEvent) {
        // Panel-wide rule: a click anywhere that is not a text field ends
        // editing in whichever field had focus, so typing never lands in a
        // search box or title the person clicked away from.
        if event.type == .leftMouseDown, firstResponder is NSTextView, let content = contentView {
            let hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
            var view = hit
            var clickedText = false
            while let current = view {
                if current is NSTextView || current is NSTextField { clickedText = true; break }
                view = current.superview
            }
            if !clickedText { makeFirstResponder(nil) }
        }
        guard !usesVerticalScroll || Self.pointerOverHorizontalScroller,
              event.type == .scrollWheel, isKeyCapable,
              event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
              let cg = event.cgEvent?.copy() else {
            super.sendEvent(event)
            return
        }
        let pairs: [(CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2),
            (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2),
            (.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2),
        ]
        for (vertical, horizontal) in pairs {
            let value = cg.getDoubleValueField(vertical)
            cg.setDoubleValueField(horizontal, value: value)
            cg.setDoubleValueField(vertical, value: 0)
        }
        if let swapped = NSEvent(cgEvent: cg) {
            super.sendEvent(swapped)
        } else {
            super.sendEvent(event)
        }
    }
}
