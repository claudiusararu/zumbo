import AppKit
import Foundation
import SwiftUI

// MARK: - Screen

/// Hardware notch measurement. The safeAreaInsets + auxiliaryTop*Area approach
/// is the same one OpenDictation uses (MIT, see NOTICES.md).
extension NSScreen {

    /// Exact size of the hardware notch, or `.zero` on a notchless display.
    var hardwareNotchSize: CGSize {
        guard safeAreaInsets.top > 0 else { return .zero }
        guard let left = auxiliaryTopLeftArea?.width,
              let right = auxiliaryTopRightArea?.width,
              left > 0, right > 0 else { return .zero }
        let width = frame.width - left - right
        guard width > 0 else { return .zero }
        return CGSize(width: width, height: safeAreaInsets.top)
    }

    var hasHardwareNotch: Bool { hardwareNotchSize != .zero }

    /// The screen that currently contains the mouse pointer, main screen as a fallback.
    static var withPointer: NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

// MARK: - States

/// The panel's state machine. One shape, one window, five states.
enum NotchState: Equatable {
    case idle
    case hover
    case recording
    /// Meeting mode's persistent row: recording, or paused between
    /// fragments. Never auto-retracts to `.idle` on hover-out (only Stop or
    /// the menu toggle ends it) - see `NotchController.pointerMoved()`.
    case meeting
    case done
    /// A short message, usually a missing permission, with an optional button.
    case notice
    case expanded
    /// The eight-step first-launch walkthrough, restartable from Settings.
    /// Never leaves on its own (no hover-out, no idle timer, no
    /// click-outside, Escape does nothing) - only Finish or the last step's
    /// Skip returns to `.idle`. See docs/ARCHITECTURE.md "Onboarding".
    case onboarding
    /// The hard gate once the trial has ended and nothing has activated:
    /// lock icon, one line, "Buy a license" / "Enter key" pills. Escape or a
    /// click outside retracts it, same as `.expanded`; the next gated
    /// action (hotkey, quick action, menu item) shows it again. See
    /// docs/ARCHITECTURE.md "Licensing".
    case locked

    /// Mouse events reach the panel only in these states.
    var acceptsMouse: Bool {
        switch self {
        // Notice can carry a button, so it has to be clickable.
        case .hover, .recording, .meeting, .notice, .expanded, .onboarding, .locked: return true
        case .idle, .done: return false
        }
    }
}

/// How the expanded panel's History tab lays out its transcription cards.
/// Persisted so the choice survives a relaunch.
enum HistoryLayout: String {
    case row
    case grid

    private static let defaultsKey = "historyLayout"

    static var persisted: HistoryLayout {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(HistoryLayout.init) ?? .row
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// Which content the expanded panel is showing. Not a `NotchState`: the panel
/// stays `.expanded` throughout, only this flips. Always resets to `.history`
/// when the panel collapses, so reopening it never lands on Settings.
enum ExpandedPage {
    case history
    case settings
}

// MARK: - Metrics

/// Size and corner radii of the black shape for one state, on one screen.
struct NotchMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// Whether the screen this was measured for has a hardware notch. Drives
    /// the layout: notchless displays get one compact row, a MacBook needs the
    /// content pushed below the hardware notch.
    var hasNotch: Bool

    /// Height of the one content row in the small states.
    static let contentRowHeight: CGFloat = 22
    /// Padding above the row on a notchless display, and below it everywhere.
    static let rowPadding: CGFloat = 8
    static let bottomPadding: CGFloat = 10

    /// Size used on notchless displays and as the floor everywhere.
    static let defaultIdleSize = CGSize(width: 200, height: 32)

    /// Invisible strip at the top center of a notchless display that listens for hover.
    static let hotZoneSize = CGSize(width: 200, height: 12)

    /// Transparent slack around the shape inside the panel window. It gives the
    /// spring room to overshoot without clipping.
    static let windowInsets = NSEdgeInsets(top: 0, left: 56, bottom: 44, right: 56)

    /// The onboarding panel's full size (about 560 x 360 pt, per spec).
    static let onboardingSize = CGSize(width: 560, height: 400)
    /// The compact row shown while another app (System Settings, for a
    /// permission step) has focus during onboarding.
    static let onboardingCompactSize = CGSize(width: 280, height: 44)

    static func metrics(
        for state: NotchState, base: CGSize, hasNotch: Bool,
        historyLayout: HistoryLayout = .row, expandedPage: ExpandedPage = .history,
        noticeMessage: String = "", noticeHasSecondaryButton: Bool = false, noticeDismissible: Bool = false,
        onboardingCompact: Bool = false
    ) -> NotchMetrics {
        switch state {
        case .idle:
            // Nothing is ever drawn in idle, on any display: the hardware notch
            // is already black and a notchless display shows bare screen edge.
            // The footprint still matters, because the shape expands out of it:
            // on a MacBook it is the hardware notch rectangle, on a notchless
            // display it is zero height. The radii stay put so the very first
            // frame of an expansion is already rounded, never square.
            return NotchMetrics(
                width: base.width,
                height: hasNotch ? base.height : 0,
                topRadius: 10,
                bottomRadius: 12,
                hasNotch: hasNotch
            )
        case .hover:
            // Five quick actions: dictate, note, meeting (a toggle switch,
            // not a button - see `QuickActionsRow`), history, settings.
            return NotchMetrics(
                width: base.width + 136,
                height: rowHeight(hasNotch: hasNotch, base: base),
                topRadius: 10,
                bottomRadius: 12,
                hasNotch: hasNotch
            )
        case .recording:
            // One row of content, wherever it runs. On a MacBook the hardware
            // notch band is dead space, so it is added on top of the row; on a
            // notchless display the panel is just the row, about 40 pt.
            return NotchMetrics(
                width: max(base.width + 140, 360),
                height: rowHeight(hasNotch: hasNotch, base: base),
                topRadius: 10,
                bottomRadius: 14,
                hasNotch: hasNotch
            )
        case .meeting:
            // The compact status row (icon, pulse or waveform, timer, record or
            // pause, stop). Never swaps content on hover.
            let width = max(base.width + 260, 460)
            return NotchMetrics(
                width: width,
                height: rowHeight(hasNotch: hasNotch, base: base),
                topRadius: 10,
                bottomRadius: 14,
                hasNotch: hasNotch
            )
        case .done:
            return NotchMetrics(
                width: max(base.width + 40, 220),
                height: rowHeight(hasNotch: hasNotch, base: base),
                topRadius: 10,
                bottomRadius: 13,
                hasNotch: hasNotch
            )
        case .notice:
            // Sized to the message itself: measured (not guessed) so a long
            // disclosure like the meeting one is never cut off. Widens up to
            // ~520 pt before wrapping to a second or third line.
            let (width, lines) = noticeSize(
                for: noticeMessage, hasSecondaryButton: noticeHasSecondaryButton, isDismissible: noticeDismissible)
            let top = hasNotch ? base.height : rowPadding
            let contentHeight = max(contentRowHeight, CGFloat(lines) * noticeLineHeight + 6)
            return NotchMetrics(
                width: width,
                height: top + contentHeight + bottomPadding,
                topRadius: 10,
                bottomRadius: 13,
                hasNotch: hasNotch
            )
        case .expanded:
            // Height follows the content: search row, tab row, then the
            // history area, plus the hardware notch band on a MacBook. No
            // empty black. The history area itself is taller in grid mode, so
            // this is the one place either layout's height comes from.
            let top = hasNotch ? base.height : rowPadding
            return NotchMetrics(
                width: 720,
                height: top + expandedContentHeight(for: expandedPage, historyLayout: historyLayout) + bottomPadding,
                topRadius: 12,
                bottomRadius: 16,
                hasNotch: hasNotch
            )
        case .onboarding:
            // Larger than the small states, same shape/springs/black surface
            // as everything else. Compacts to a small row while another app
            // has focus on a permission step (see docs/ARCHITECTURE.md).
            let top = hasNotch ? base.height : rowPadding
            let size = onboardingCompact ? onboardingCompactSize : onboardingSize
            return NotchMetrics(
                width: size.width,
                height: top + size.height,
                topRadius: onboardingCompact ? 10 : 12,
                bottomRadius: onboardingCompact ? 13 : 16,
                hasNotch: hasNotch
            )
        case .locked:
            // One row, same shape as `.notice`: icon + message on the left,
            // the two pills on the right, wrapping to a second line past
            // 520 pt instead of shrinking the pills.
            let top = hasNotch ? base.height : rowPadding
            let (width, lines) = NotchMetrics.lockedSize(
                message: "Your 3-day trial has ended.", buyTitle: "Buy a license", enterTitle: "Enter key")
            let contentHeight = max(NotchMetrics.lockedPillRowHeight, CGFloat(lines) * NotchMetrics.lockedLineHeight + 10)
            return NotchMetrics(
                width: width,
                height: top + contentHeight + bottomPadding,
                topRadius: 10,
                bottomRadius: 14,
                hasNotch: hasNotch
            )
        }
    }

    var size: CGSize { CGSize(width: width, height: height) }

    /// Search row, gap, tab row, gap, then the history area.
    private static let expandedHeaderHeight: CGFloat = 26 + 12 + 28 + 12

    /// Height of the horizontal card row, row mode.
    static let expandedRowHeight: CGFloat = 118
    /// Height of the vertical grid's scroll area, grid mode. Sized so the
    /// panel lands around 520 pt total on a notchless display.
    static let expandedGridHeight: CGFloat = 424

    /// The history detail panel: a second black rounded rectangle drawn below
    /// the expanded panel in the same window, never part of `NotchShape`
    /// itself. Same width as the expanded panel.
    static let detailPanelHeight: CGFloat = 260
    static let detailPanelGap: CGFloat = 8
    static let detailPanelCornerRadius: CGFloat = 14

    /// Settings has its own single-row header (back chevron + title), not the
    /// search-field-plus-filter-pills header history uses.
    static let expandedSettingsHeaderHeight: CGFloat = 26 + 12
    /// Height of the settings body (category list plus its content pane).
    /// Reuses the grid's content height on purpose, so the panel lands at the
    /// same 480 pt total on a notchless display as the grid layout does.
    static let expandedSettingsBodyHeight: CGFloat = 424

    /// The single place either page's expanded content height comes from, so
    /// the view's own frames (`ExpandedPanelView`) and the window geometry
    /// this drives never disagree.
    static func expandedContentHeight(for page: ExpandedPage, historyLayout: HistoryLayout) -> CGFloat {
        switch page {
        case .history:
            switch historyLayout {
            case .row: return expandedHeaderHeight + expandedRowHeight
            case .grid: return expandedHeaderHeight + expandedGridHeight
            }
        case .settings:
            return expandedSettingsHeaderHeight + expandedSettingsBodyHeight
        }
    }

    /// Height of a small state: the content row plus its padding, plus the
    /// hardware notch band when there is one. Never a fixed number.
    private static func rowHeight(hasNotch: Bool, base: CGSize) -> CGFloat {
        let top = hasNotch ? base.height : rowPadding
        return top + contentRowHeight + bottomPadding
    }

    // MARK: - Notice sizing

    /// Room the glyph, the gaps and (when present) the action button's pill
    /// take up beside the text, on the line the text itself sits on.
    private static let noticeChrome: CGFloat = 8 + 15 + 8 + 8 + 66
    /// Extra room a second pill (and the gap before it) needs beside the
    /// first: the reminder proposal ("Set reminder" / "No"), the ambiguous
    /// time ask (two time pills), and the firing notice ("Done" / "Snooze
    /// 10 min").
    private static let noticeSecondaryChrome: CGFloat = 8 + 96
    /// Room for the trial notices' dismiss "x" circle (22 pt) and the gap
    /// before it, right of the primary pill.
    private static let noticeDismissibleChrome: CGFloat = 8 + 22
    private static let noticeMinWidth: CGFloat = 300
    private static let noticeMaxWidth: CGFloat = 520
    static let noticeLineHeight: CGFloat = 15

    /// Real text measurement (`NSString.boundingRect`), not a guess: widens
    /// up to `noticeMaxWidth` to fit the message on one line before it wraps,
    /// and reports how many lines (capped at 3) the wrapped text needs so the
    /// shape can grow tall enough to show every word.
    static func noticeSize(for message: String, hasSecondaryButton: Bool = false, isDismissible: Bool = false) -> (width: CGFloat, lines: Int) {
        let chrome = noticeChrome + (hasSecondaryButton ? noticeSecondaryChrome : 0) + (isDismissible ? noticeDismissibleChrome : 0)
        guard !message.isEmpty else { return (noticeMinWidth, 1) }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]
        let singleLineWidth = (message as NSString).size(withAttributes: attributes).width
        let desiredWidth = min(noticeMaxWidth, max(noticeMinWidth, singleLineWidth + chrome))
        let textWidth = desiredWidth - chrome
        let bounds = (message as NSString).boundingRect(
            with: CGSize(width: max(textWidth, 40), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes)
        let lines = max(1, min(3, Int((bounds.height / noticeLineHeight).rounded(.up))))
        return (desiredWidth, lines)
    }

    // MARK: - Locked (hard gate)

    private static let lockedMinWidth: CGFloat = 340
    private static let lockedMaxWidth: CGFloat = 520
    static let lockedLineHeight: CGFloat = 15
    static let lockedPillRowHeight: CGFloat = 28

    /// Same measuring approach as `noticeSize(for:hasSecondaryButton:)`: real
    /// text and pill widths, not a guess. One row - icon, message, two
    /// pills - up to 520 pt before the message wraps to a second line; the
    /// pills never wrap or shrink.
    static func lockedSize(message: String, buyTitle: String, enterTitle: String) -> (width: CGFloat, lines: Int) {
        let pillFont: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]
        let messageFont: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
        func pillWidth(_ title: String) -> CGFloat {
            (title as NSString).size(withAttributes: pillFont).width + 24
        }
        let pillsWidth = pillWidth(buyTitle) + pillWidth(enterTitle) + 8
        let iconAndGaps: CGFloat = 12 + 8 + 12
        let horizontalPadding: CGFloat = 32
        let chrome = horizontalPadding + iconAndGaps + pillsWidth
        let messageSingleLineWidth = (message as NSString).size(withAttributes: messageFont).width
        let desiredWidth = min(lockedMaxWidth, max(lockedMinWidth, messageSingleLineWidth + chrome))
        let textWidth = desiredWidth - chrome
        let bounds = (message as NSString).boundingRect(
            with: CGSize(width: max(textWidth, 60), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: messageFont)
        let lines = max(1, min(2, Int((bounds.height / lockedLineHeight).rounded(.up))))
        return (desiredWidth, lines)
    }
}
