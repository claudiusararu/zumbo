import AppKit
import SwiftUI
import VesperEngine

/// Wraps a scrollable `NSTextView` for `HistoryDetailPanelView`'s full-text
/// editor. `TextEditor` has no public selection binding on macOS 14, and the
/// Teach popover needs both the selected range and its on-screen rect, so
/// this talks to `NSTextView` directly instead. Keeps every visible trait the
/// old `TextEditor` had: non-monospaced 13 pt, white 92% text, clear
/// background, editable, scrollable.
struct SelectableTextView: NSViewRepresentable {
    @Binding var text: String
    /// False for onboarding's "Try it" step (step 6): a read-only result the
    /// person cannot accidentally edit, same underline highlighting as the
    /// editable case.
    var editable: Bool = true
    /// Where a floating control (the Teach chip) sits over the text, in the
    /// visible area's top-leading space. The text view shows the pointing
    /// hand there instead of its own I-beam, which otherwise wins on every
    /// mouse move over the SwiftUI overlay.
    var pointerRect: CGRect? = nil
    /// Words to mark with a dashed green underline (Teach corrections).
    var highlightWords: [String] = []
    var highlightColor: NSColor = .systemGreen
    /// Fires whenever the selection changes: the raw selected substring
    /// (unexpanded, unstripped - the caller decides what to do with it), its
    /// UTF-16 range in `text`, and its bounding rect in this view's own
    /// top-left-origin coordinate space (matching the SwiftUI frame this
    /// representable occupies, so callers can position an overlay with a
    /// plain `.offset` from `.topLeading`). Range length 0 and a `nil` rect
    /// mean the selection is empty.
    var onSelectionChange: (String, NSRange, CGRect?) -> Void
    /// Fires on every scroll, so a floating chip/popover doesn't linger over
    /// text that has moved out from under it.
    var onScroll: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// NSTextView that yields the cursor to an overlay control: inside
    /// `pointerRect` (text view coordinates) the hand shows, elsewhere the
    /// usual I-beam.
    final class OverlayAwareTextView: NSTextView {
        var pointerRect: CGRect? {
            didSet { window?.invalidateCursorRects(for: self) }
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            if let pointerRect { addCursorRect(pointerRect, cursor: .pointingHand) }
        }

        override func mouseMoved(with event: NSEvent) {
            if let pointerRect, pointerRect.contains(convert(event.locationInWindow, from: nil)) {
                NSCursor.pointingHand.set()
                return
            }
            super.mouseMoved(with: event)
        }

        override func cursorUpdate(with event: NSEvent) {
            if let pointerRect, pointerRect.contains(convert(event.locationInWindow, from: nil)) {
                NSCursor.pointingHand.set()
                return
            }
            super.cursorUpdate(with: event)
        }
    }

    /// Draws the correction underline ourselves: the system dashed underline
    /// is hairline-thin and sits on the descenders. This one is 1.5 pt, short
    /// round dashes, 3 pt under the baseline, in the accent color.
    final class CorrectionLayoutManager: NSLayoutManager {
        var color: NSColor = .systemGreen

        override func drawUnderline(
            forGlyphRange glyphRange: NSRange, underlineType: NSUnderlineStyle, baselineOffset: CGFloat,
            lineFragmentRect lineRect: CGRect, lineFragmentGlyphRange lineGlyphRange: NSRange,
            containerOrigin: CGPoint
        ) {
            guard underlineType.contains(.patternDash), let container = textContainer(forGlyphAt: glyphRange.location, effectiveRange: nil) else {
                super.drawUnderline(
                    forGlyphRange: glyphRange, underlineType: underlineType, baselineOffset: baselineOffset,
                    lineFragmentRect: lineRect, lineFragmentGlyphRange: lineGlyphRange, containerOrigin: containerOrigin)
                return
            }
            let bounds = boundingRect(forGlyphRange: glyphRange, in: container)
            let baseline = lineRect.minY + location(forGlyphAt: glyphRange.location).y
            let y = baseline + 3 + containerOrigin.y
            let path = NSBezierPath()
            path.move(to: CGPoint(x: bounds.minX + containerOrigin.x + 0.5, y: y))
            path.line(to: CGPoint(x: bounds.maxX + containerOrigin.x - 0.5, y: y))
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.setLineDash([3, 3.5], count: 2, phase: 0)
            color.setStroke()
            path.stroke()
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 stack on purpose, so the custom layout manager above
        // draws the underlines (a plain NSTextView() would pick TextKit 2).
        let storage = NSTextStorage()
        let layoutManager = CorrectionLayoutManager()
        layoutManager.color = highlightColor
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let textView = OverlayAwareTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = NSColor.white.withAlphaComponent(0.92)
        textView.insertionPointColor = NSColor.white.withAlphaComponent(0.92)
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scrollView = scrollView
        context.coordinator.observeScroll()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? OverlayAwareTextView else { return }
        let clipOrigin = scrollView.contentView.bounds.origin
        let inTextView = pointerRect.map { $0.offsetBy(dx: clipOrigin.x, dy: clipOrigin.y) }
        if textView.pointerRect != inTextView { textView.pointerRect = inTextView }
        (textView.layoutManager as? CorrectionLayoutManager)?.color = highlightColor
        if textView.string != text {
            let previous = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(previous.location, length), length: 0))
        }
        applyHighlights(to: textView)
    }

    /// Dashed underline in the accent color under every whole-word match of
    /// a corrected word. Re-applied on every update; cheap for note-sized text.
    private func applyHighlights(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.underlineStyle, range: full)
        storage.removeAttribute(.underlineColor, range: full)
        let style = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue
        for word in highlightWords where !word.isEmpty {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: storage.string, range: full) {
                storage.addAttributes([.underlineStyle: style, .underlineColor: highlightColor], range: match.range)
            }
        }
        storage.endEditing()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SelectableTextView
        weak var scrollView: NSScrollView?
        private var scrollObserver: NSObjectProtocol?

        init(_ parent: SelectableTextView) { self.parent = parent }

        func observeScroll() {
            guard let scrollView else { return }
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak self] _ in
                self?.parent.onScroll()
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            guard range.length > 0,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let scrollView
            else {
                parent.onSelectionChange("", NSRange(location: range.location, length: 0), nil)
                return
            }
            let selected = (textView.string as NSString).substring(with: range)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            // The clip view is flipped like the text view (top-down) and its
            // bounds origin is the scroll offset, so converting into it and
            // subtracting that origin gives the rect in the visible area's
            // own top-leading space, which is exactly what the SwiftUI
            // overlay (sized to the scroll view) uses for `.offset`.
            let clipView = scrollView.contentView
            let inClip = textView.convert(rect, to: clipView)
            let topDown = CGRect(
                x: inClip.origin.x - clipView.bounds.origin.x,
                y: inClip.origin.y - clipView.bounds.origin.y,
                width: inClip.width,
                height: inClip.height)
            parent.onSelectionChange(selected, range, topDown)
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }
    }
}

// MARK: - Selection state

/// What the Teach chip/popover need about the current selection, built by
/// `HistoryDetailPanelView` from the raw `SelectableTextView` callback: the
/// word/phrase expanded and prefix-stripped (see `Teach`), the exact range in
/// the full text to replace for "Replace here", and where to float the chip.
struct TeachSelection {
    /// Cleaned selected text ("Heard as"), with any leading timestamp or
    /// speaker label already stripped.
    let heard: String
    /// The range in the full text that "Replace here" replaces - the
    /// word-expanded selection minus any stripped prefix.
    let range: NSRange
    /// Bounding rect of the selection in the editor's own top-leading
    /// coordinate space.
    let rect: CGRect

    /// Builds a `TeachSelection` from a raw `SelectableTextView` callback, or
    /// `nil` when there is nothing to teach: an empty/whitespace-only
    /// selection, or one that is only a timestamp/speaker label.
    static func build(text: String, rawRange: NSRange, rect: CGRect?) -> TeachSelection? {
        guard rawRange.length > 0, let rect else { return nil }
        let expandedRange = Teach.expandToWord(in: text, range: rawRange)
        let ns = text as NSString
        guard expandedRange.location != NSNotFound, expandedRange.location + expandedRange.length <= ns.length
        else { return nil }
        let raw = ns.substring(with: expandedRange)
        let (cleaned, prefix) = Teach.stripLeadingPrefix(from: raw)
        let heard = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else { return nil }
        let prefixLength = (prefix as NSString?)?.length ?? 0
        let wordRange = NSRange(
            location: expandedRange.location + prefixLength, length: (heard as NSString).length)
        return TeachSelection(heard: heard, range: wordRange, rect: rect)
    }
}

// MARK: - Chip

/// The small floating "Teach" chip above a text selection: same black pill,
/// white text visual language as `HoverTip`.
struct TeachChip: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text("Teach")
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(Color.black)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(SettingsTheme.accent, in: Capsule(style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .pointer()
        .hoverTip("Fix this word and teach it to Zumbo")
    }
}
