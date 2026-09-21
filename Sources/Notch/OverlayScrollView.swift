import SwiftUI

/// A vertical scroll area with a thin, self-hiding indicator: 4 pt wide,
/// rounded, white at 25% opacity, no track, visible while scrolling and gone
/// ~800 ms after the last movement.
///
/// Pure SwiftUI on purpose. The first version hosted an `NSScrollView` with
/// Auto Layout constraints pinning an `NSHostingView` inside it. Inside the
/// borderless, animated notch panel that produced an AppKit exception
/// (`_postWindowNeedsUpdateConstraints` raised during the window resize, via
/// `_NSConstraintBasedLayoutHostingView`) and terminated the app whenever the
/// expanded panel collapsed. No constraints here, nothing for AppKit to throw.
struct OverlayScrollView<Content: View>: View {

    private let content: Content

    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var indicatorVisible = false
    @State private var hideTask: Task<Void, Never>?

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView(.vertical, showsIndicators: false) {
                content
                    .background(
                        GeometryReader { inner in
                            Color.clear
                                .preference(key: ContentFrameKey.self,
                                            value: inner.frame(in: .named("overlayScroll")))
                        }
                    )
            }
            .coordinateSpace(name: "overlayScroll")
            .onPreferenceChange(ContentFrameKey.self) { frame in
                contentHeight = frame.height
                let newOffset = -frame.minY
                if abs(newOffset - offset) > 0.5 { showIndicator() }
                offset = newOffset
            }
            .onAppear { viewportHeight = viewport.size.height }
            .onChange(of: viewport.size.height) { _, h in viewportHeight = h }
            .overlay(alignment: .topTrailing) { indicator }
        }
    }

    // MARK: - Indicator

    private var canScroll: Bool { contentHeight > viewportHeight + 1 && viewportHeight > 0 }

    @ViewBuilder
    private var indicator: some View {
        if canScroll {
            let trackInset: CGFloat = 3
            let track = max(viewportHeight - trackInset * 2, 0)
            let thumb = max(track * viewportHeight / contentHeight, 18)
            let maxOffset = max(contentHeight - viewportHeight, 1)
            let y = trackInset + (track - thumb) * min(max(offset / maxOffset, 0), 1)
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.25))
                .frame(width: 4, height: thumb)
                .padding(.trailing, 3)
                .offset(y: y)
                .opacity(indicatorVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: indicatorVisible)
                .allowsHitTesting(false)
        }
    }

    private func showIndicator() {
        indicatorVisible = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            if !Task.isCancelled { indicatorVisible = false }
        }
    }
}

private struct ContentFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
