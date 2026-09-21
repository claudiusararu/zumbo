import AppKit
import SwiftUI
import VesperEngine

/// The eight-step first-launch walkthrough's content, drawn inside the
/// `.onboarding` notch state's shape (`NotchGeometry.NotchMetrics
/// .onboardingSize`, 560 x 400 pt). `OnboardingCoordinator` owns every
/// transition and permission check; this view only reads `NotchModel`'s
/// onboarding fields and calls the request closures the coordinator wired.
///
/// One layout system for every step (`OnboardingStepFrame`): a 456 pt
/// content column centered in the 560 pt panel, a top bar (back chevron +
/// step dots), a left-aligned title block, a flexible body, and a footer
/// pinned to the bottom. Nothing defines its own inset outside that column.
struct OnboardingRootView: View {
    @ObservedObject var model: NotchModel
    @State private var forward = true

    var body: some View {
        Group {
            if model.onboardingCompact {
                OnboardingCompactRow(step: model.onboardingStep) {
                    model.onboardingRestoreFromCompactRequest?()
                }
            } else {
                stepContent
                    .id(model.onboardingStep)
                    .transition(stepTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.onboardingStep) { old, new in forward = new >= old }
        .animation(
            model.reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.86),
            value: model.onboardingStep)
    }

    private var stepTransition: AnyTransition {
        guard !model.reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.onboardingStep {
        case 1: WelcomeStep(model: model)
        case 2: MicrophoneStep(model: model)
        case 3: AccessibilityStep(model: model)
        case 4: InputMonitoringStep(model: model)
        case 5: HotkeyStep(model: model)
        case 6: DictateAreasStep(model: model)
        case 7: TryItStep(model: model)
        default: StartStep(model: model)
        }
    }
}

// MARK: - Compact row

/// The small row (~280 x 44 pt) shown while another app has focus during a
/// permission step. Clicking the pill or the permission being granted (the
/// coordinator's poll) both restore the full panel.
struct OnboardingCompactRow: View {
    let step: Int
    let restore: () -> Void

    private var stepName: String {
        switch step {
        case 2: return "Microphone"
        case 3: return "Accessibility"
        case 4: return "Keyboard"
        default: return "Setup"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Step \(step) of 8, \(stepName)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: restore) {
                Text("Back to setup")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .pointer()
            .hoverTip("Return to the full setup panel")
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Layout shell

/// Every step's shared chrome: top bar, title block, a flexible body slot,
/// a footer pinned to the bottom. `horizontalPadding` (52 pt each side of
/// the 560 pt panel) lives only here, as `columnWidth` (456 pt) - nothing
/// else defines its own inset.
private struct OnboardingStepFrame<BodyContent: View>: View {
    enum FooterButton {
        case primary(String, enabled: Bool, action: () -> Void)
        case none
    }

    let model: NotchModel
    let showBack: Bool
    let title: String
    let subtitle: String
    var footerLink: (String, () -> Void)?
    var footerButton: FooterButton = .none
    @ViewBuilder var content: () -> BodyContent

    static var columnWidth: CGFloat { 456 }

    private var hasFooter: Bool {
        footerLink != nil || !isNoneButton
    }

    private var isNoneButton: Bool {
        if case .none = footerButton { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.top, 14)
            titleBlock
                .padding(.top, 26)
                .entrance(delay: 0, reduceMotion: model.reduceMotion)
            content()
                .padding(.top, 18)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .entrance(delay: 0.08, reduceMotion: model.reduceMotion)
            if hasFooter {
                footer
                    .padding(.bottom, 18)
                    .entrance(delay: 0.12, reduceMotion: model.reduceMotion)
            }
        }
        .frame(width: Self.columnWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            if showBack {
                Button { model.onboardingBackRequest?() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .pointer()
                .hoverTip("Back")
            } else {
                Color.clear.frame(width: 26, height: 26)
            }
            Spacer(minLength: 0)
            OnboardingStepDots(step: model.onboardingStep)
            Spacer(minLength: 0)
            Color.clear.frame(width: 26, height: 26)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 14) {
            if let footerLink {
                OnboardingLinkButton(title: footerLink.0, action: footerLink.1)
            }
            Spacer(minLength: 0)
            if case let .primary(t, enabled, action) = footerButton {
                OnboardingPrimaryButton(title: t, enabled: enabled, action: action)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Fades and lifts a step's title, body or footer in, staggered by `delay`
/// against the step it belongs to. Reduce Motion collapses to a plain
/// crossfade. Relies on the step switch above giving every step a fresh
/// subtree (`.id(model.onboardingStep)`), so `onAppear` fires on every step
/// change even when two steps share a component type.
private struct EntranceModifier: ViewModifier {
    let delay: Double
    let reduceMotion: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
            .onAppear {
                if reduceMotion {
                    withAnimation(.easeOut(duration: 0.15)) { shown = true }
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85).delay(delay)) { shown = true }
                }
            }
    }
}

extension View {
    fileprivate func entrance(delay: Double, reduceMotion: Bool) -> some View {
        modifier(EntranceModifier(delay: delay, reduceMotion: reduceMotion))
    }
}

// MARK: - Step indicator

/// Eight dots, the current one green (`SettingsTheme.accent`) and 7 pt, the
/// rest a faint white at 5 pt. Grows/shrinks with a spring on every step
/// change.
private struct OnboardingStepDots: View {
    let step: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(1...8, id: \.self) { i in
                Circle()
                    .fill(i == step ? SettingsTheme.accent : Color.white.opacity(0.18))
                    .frame(width: i == step ? 7 : 5, height: i == step ? 7 : 5)
                    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: step)
            }
        }
    }
}

// MARK: - Shared pieces

private struct XShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.24, y: rect.minY + rect.height * 0.24))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.76))
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.24))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.24, y: rect.minY + rect.height * 0.76))
        return p
    }
}

/// The green/grey/red mark every permission-flavored row (mic, accessibility,
/// the hotkey trial, the try-it result) shows: grey ring before it was
/// asked, a green ring with a drawn-in check once granted or done (a quick
/// pop on top), a red ring with a two-shake "x" if it was asked and refused.
struct OnboardingMark: View {
    let state: OnboardingMarkState
    var reduceMotion = false

    @State private var checkTrim: CGFloat = 0
    @State private var pop: CGFloat = 1
    @State private var shakeOffset: CGFloat = 0

    var body: some View {
        ZStack {
            switch state {
            case .notAsked:
                Circle().stroke(Color.white.opacity(0.3), lineWidth: 1.5)
            case .granted:
                Circle().fill(SettingsTheme.accent.opacity(0.16))
                Circle().stroke(SettingsTheme.accent, lineWidth: 1.5)
                CheckmarkShape()
                    .trim(from: 0, to: checkTrim)
                    .stroke(SettingsTheme.accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            case .denied:
                Circle().fill(Color.red.opacity(0.16))
                Circle().stroke(Color.red.opacity(0.85), lineWidth: 1.5)
                XShape().stroke(Color.red.opacity(0.85), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
        }
        .frame(width: 20, height: 20)
        .scaleEffect(pop)
        .offset(x: shakeOffset)
        .onAppear { if state == .granted { checkTrim = 1 } }
        .onChange(of: state) { _, new in animate(for: new) }
    }

    private func animate(for state: OnboardingMarkState) {
        guard !reduceMotion else {
            checkTrim = state == .granted ? 1 : 0
            return
        }
        switch state {
        case .granted:
            checkTrim = 0
            withAnimation(.easeOut(duration: 0.35)) { checkTrim = 1 }
            pop = 1.15
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5).delay(0.12)) { pop = 1 }
        case .denied:
            withAnimation(.easeInOut(duration: 0.07).repeatCount(4, autoreverses: true)) { shakeOffset = 3 }
            withAnimation(.easeOut(duration: 0.05).delay(0.28)) { shakeOffset = 0 }
        case .notAsked:
            break
        }
    }
}

/// A small always-visible pulsing dot: "asked but not resolved yet" (System
/// Settings is open, or a session is live).
private struct OnboardingPulseDot: View {
    var color: Color = .white.opacity(0.55)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .opacity(on ? 1 : 0.35)
                .animation(.easeInOut(duration: 0.5), value: on)
        }
        .frame(width: 20, height: 20)
    }
}

/// The one filled white pill, used for every step's primary "Continue".
/// Disabled state is white 12% fill, white 40% text - not a plain opacity
/// dim, so it never looks like a loading flicker.
struct OnboardingPrimaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(enabled ? Color.black : Color.white.opacity(0.4))
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(enabled ? Color.white : Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .pointer()
        .animation(.easeOut(duration: 0.15), value: enabled)
        .hoverTip(title)
    }
}

/// A muted text link, used for every "Skip" and "Change key".
struct OnboardingLinkButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? 0.85 : 0.55))
                .underline(hovering)
        }
        .buttonStyle(.plain)
        .pointer()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .hoverTip(title)
    }
}

/// The translucent secondary pill: the permission cards' action, "Activate"
/// on step 7's license field.
struct OnboardingSecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .pointer()
        .hoverTip(title)
    }
}

// MARK: - Step 1: Welcome

struct WelcomeStep: View {
    @ObservedObject var model: NotchModel
    private let facts: [(symbol: String, text: String)] = [
        ("bolt.fill", "You speak about 150 words a minute. Most people type 40."),
        ("lock.fill", "Runs entirely on this Mac. Nothing leaves it."),
        ("sparkles", "Learns the way you talk, and gets better the more you use it."),
        ("person.2.wave.2.fill", "Notes and meetings by voice, with every speaker told apart."),
    ]

    var body: some View {
        OnboardingStepFrame(
            model: model, showBack: false,
            title: "Zumbo lives here",
            subtitle: "Press a key anywhere, speak, and the text lands where your cursor is.",
            footerButton: .primary("Continue", enabled: true) { model.onboardingContinueRequest?() }
        ) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                    FactRow(symbol: fact.symbol, text: fact.text, delay: Double(index) * 0.12, reduceMotion: model.reduceMotion)
                }
            }
        }
    }
}

private struct FactRow: View {
    let symbol: String
    let text: String
    let delay: Double
    let reduceMotion: Bool
    @State private var shown = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle().fill(SettingsTheme.accent.opacity(0.15))
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsTheme.accent)
            }
            .frame(width: 30, height: 30)
            .scaleEffect(shown ? 1 : 0.6)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(shown ? 1 : 0)
        .onAppear {
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.15)) { shown = true }
            } else {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.75).delay(delay)) { shown = true }
            }
        }
    }
}

// MARK: - Steps 2, 3 & 4: Permission cards

/// Shared body for the three permission steps: mark, name, one-sentence why,
/// action pill. Steps 3 and 4 additionally show a "waiting in System
/// Settings" pulse after their action fires, and auto-advance 0.8 s after the poll
/// turns green.
private struct PermissionCardStep: View {
    @ObservedObject var model: NotchModel
    let title: String
    let subtitle: String
    let permissionName: String
    let why: String
    let state: OnboardingMarkState
    let actionTitle: String
    var waitingText: String?
    var autoAdvanceOnGrant = false
    /// Input Monitoring only: macOS's own "Quit & Reopen" dialog after a
    /// grant does not relaunch a menu-bar app with no Dock icon, so this
    /// tells the owner to dismiss it instead.
    var noteBelow: String?
    let footnote: String
    let action: () -> Void

    @State private var opened = false

    var body: some View {
        OnboardingStepFrame(
            model: model, showBack: true, title: title, subtitle: subtitle,
            footerButton: .primary("Continue", enabled: state == .granted) { model.onboardingContinueRequest?() }
        ) {
            VStack(alignment: .leading, spacing: 0) {
                card
                if let noteBelow {
                    Text(noteBelow)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 12)
                }
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, noteBelow == nil ? 16 : 6)
            }
        }
        .onChange(of: state) { _, new in
            guard autoAdvanceOnGrant, new == .granted, opened else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                model.onboardingContinueRequest?()
            }
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            if opened, state == .notAsked, let waitingText {
                OnboardingPulseDot()
                VStack(alignment: .leading, spacing: 3) {
                    Text(permissionName).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
                    Text(waitingText).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
            } else {
                OnboardingMark(state: state, reduceMotion: model.reduceMotion)
                VStack(alignment: .leading, spacing: 3) {
                    Text(permissionName).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
                    Text(why).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 8)
            if state != .granted {
                OnboardingSecondaryButton(title: actionTitle) {
                    opened = true
                    action()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct MicrophoneStep: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        PermissionCardStep(
            model: model,
            title: "Let Zumbo hear you",
            subtitle: "Audio is processed on this Mac and never stored.",
            permissionName: "Microphone",
            why: "Zumbo listens only while you hold or toggle the key. Nothing is recorded or sent anywhere.",
            state: model.onboardingMicState,
            actionTitle: "Open System Settings",
            footnote: "You can change this any time in System Settings > Privacy & Security > Microphone.",
            // The real prompt already fired when this step appeared
            // (`OnboardingCoordinator.requestMicIfNeeded()`); this pill only
            // opens the pane, for when the prompt was missed or dismissed.
            action: { model.onboardingAllowMicRequest?() })
    }
}

struct AccessibilityStep: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        PermissionCardStep(
            model: model,
            title: "Let Zumbo type for you",
            subtitle: "This is how the text lands where your cursor is, in any app.",
            permissionName: "Accessibility",
            why: "This lets Zumbo type into any app. It cannot see your screen or log your keystrokes. macOS asks for this once.",
            state: model.onboardingAccessibilityState,
            actionTitle: "Open System Settings",
            waitingText: "Waiting for you in System Settings",
            autoAdvanceOnGrant: true,
            footnote: "You can change this any time in System Settings > Privacy & Security > Accessibility.",
            action: { model.onboardingOpenAccessibilityRequest?() })
    }
}

// MARK: - Step 4: Keyboard

struct InputMonitoringStep: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        PermissionCardStep(
            model: model,
            title: "Let Zumbo see your keys",
            subtitle: "So Escape can cancel a recording and your shortcut works in every app.",
            permissionName: "Input Monitoring",
            why: "macOS asks for this once. Zumbo only reacts to your shortcut and Escape; it never records what you type.",
            state: model.onboardingInputMonitoringState,
            actionTitle: "Open System Settings",
            waitingText: "Waiting for you in System Settings",
            autoAdvanceOnGrant: true,
            noteBelow: "If macOS offers to quit and reopen, choose Later. Zumbo picks up the permission without restarting.",
            footnote: "You can change this any time in System Settings > Privacy & Security > Input Monitoring.",
            action: { model.onboardingOpenInputMonitoringRequest?() })
    }
}

// MARK: - Step 5: Your key

struct HotkeyStep: View {
    @ObservedObject var model: NotchModel
    @State private var showRecorder = false

    private var keyLabel: String { model.settings.hotkeyTrigger.displayLabel }

    var body: some View {
        OnboardingStepFrame(
            model: model, showBack: true,
            title: "One key does it all",
            subtitle: "\(keyLabel) is set. Press it now to try.",
            footerLink: ("Change key", { showRecorder = true }),
            footerButton: .primary("Continue", enabled: true) { model.onboardingContinueRequest?() }
        ) {
            if showRecorder {
                ShortcutRecorderRow(settings: model.settings)
                    .frame(maxWidth: .infinity)
            } else {
                HStack(alignment: .center, spacing: 16) {
                    KeycapView(model: model)
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tap to start and stop.")
                                .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.7))
                            Text("Hold to talk, release to stop.")
                                .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.7))
                        }
                        HStack(spacing: 8) {
                            OnboardingMark(state: model.onboardingHotkeyState, reduceMotion: model.reduceMotion)
                            Text(model.onboardingHotkeyState == .granted ? "It worked" : "Press it now to try")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
            }
        }
    }
}

/// The large keycap: presses to 0.94 with a spring the instant the hotkey
/// fires, stays pressed for the duration of a hold, and glows + rings once
/// on the first successful press.
private struct KeycapView: View {
    @ObservedObject var model: NotchModel
    @State private var pressed = false
    @State private var ringScale: CGFloat = 1
    @State private var ringOpacity: Double = 0

    var body: some View {
        Text(model.settings.hotkeyTrigger.displayLabel)
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .overlay(
                Circle()
                    .stroke(SettingsTheme.accent.opacity(ringOpacity), lineWidth: 2)
                    .scaleEffect(ringScale))
            .shadow(color: SettingsTheme.accent.opacity(pressed ? 0.35 : 0), radius: 12)
            .scaleEffect(pressed ? 0.94 : 1)
            .onChange(of: model.onboardingHotkeyHeld) { _, held in
                if model.reduceMotion {
                    pressed = held
                } else {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { pressed = held }
                }
            }
            .onChange(of: model.onboardingHotkeyState) { old, new in
                guard new == .granted, old != .granted, !model.reduceMotion else { return }
                ringScale = 1
                ringOpacity = 0.7
                withAnimation(.easeOut(duration: 0.5)) {
                    ringScale = 1.4
                    ringOpacity = 0
                }
            }
    }
}

// MARK: - Step 6: What you dictate most

struct DictateAreasStep: View {
    @ObservedObject var model: NotchModel
    /// Observed separately from `model` so the language row redraws when
    /// `AppSettings.language`/`.multilingual` change - `model.settings` is
    /// a `let` reference, so `NotchModel`'s own `objectWillChange` does not
    /// fire for it.
    @ObservedObject private var settings: AppSettings
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    init(model: NotchModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        OnboardingStepFrame(
            model: model, showBack: true,
            title: "Make it yours",
            subtitle: "Pick your language and what you dictate most. Zumbo loads the right vocabulary and keeps learning yours.",
            footerLink: ("Skip, use the developer set", { model.onboardingSkipRequest?() }),
            footerButton: .primary("Continue", enabled: true) { model.onboardingContinueRequest?() }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                languageRow
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(OnboardingArea.allCases) { area in
                        AreaTile(area: area, isOn: model.onboardingPickedAreas.contains(area)) {
                            model.onboardingPickAreaRequest?(area)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(OnboardingArea.allCases.filter { model.onboardingPickedAreas.contains($0) }) { area in
                        Text(area.line).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6))
                    }
                    Text(OnboardingArea.notesLine).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6))
                    Text(OnboardingArea.meetingLine).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Main language" menu plus the "I also dictate in other languages"
    /// toggle, same control and copy as Settings > Dictation's Language
    /// card - the same question, asked once, up front.
    private var languageRow: some View {
        HStack(spacing: 10) {
            Text("Main language")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
            LanguagePickerMenu(code: $settings.language)
                .hoverTip("The language you dictate in most")
            Spacer(minLength: 10)
            Text("Also dictate in other languages")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.6))
            PillToggle(isOn: $settings.multilingual)
                .hoverTip("Auto-detect the language per sentence")
        }
        .padding(.bottom, 2)
    }
}

private struct AreaTile: View {
    let area: OnboardingArea
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(area.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(SettingsTheme.accent)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(
                isOn ? SettingsTheme.accent.opacity(0.14) : Color.white.opacity(hovering ? 0.08 : 0.05),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isOn ? SettingsTheme.accent.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1))
            .offset(y: hovering && !isOn ? -1 : 0)
        }
        .buttonStyle(.plain)
        .pointer()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isOn)
        .hoverTip(area.title)
    }
}

// MARK: - Step 7: Try it

struct TryItStep: View {
    @ObservedObject var model: NotchModel

    private var keyLabel: String { model.settings.hotkeyTrigger.displayLabel }

    /// The first picked area's own hint, so the field never asks for a
    /// generic sentence when step 5 already said what this person dictates -
    /// never example terms, just what kind of thing to say. Always names the
    /// actual key, never a hard-coded "Right Option".
    private var hint: String {
        switch model.onboardingPickedAreas.first {
        case .developers: return "Press \(keyLabel). Try a sentence with a tool or command in it."
        case .marketing: return "Press \(keyLabel). Try a sentence with a channel or a metric in it."
        default: return "Press \(keyLabel). Say anything, the way you would say it to a colleague."
        }
    }

    var body: some View {
        OnboardingStepFrame(
            model: model, showBack: true,
            title: "Say something",
            subtitle: "Press \(keyLabel), speak, press it again. The text is there in about a fifth of a second. Nothing is pasted on this step.",
            footerLink: ("Skip", { model.onboardingSkipRequest?() }),
            footerButton: .primary("Continue", enabled: model.onboardingTryState == .granted) {
                model.onboardingContinueRequest?()
            }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                TryItField(model: model)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// The read-only result field: a live listening/transcribing row sits at its
/// bottom edge, the border breathes green while a session is live, and each
/// result replaces the field with a short per-character reveal. Never
/// interrupted - the person can try as many times as they like.
private struct TryItField: View {
    @ObservedObject var model: NotchModel
    @State private var revealedText = ""
    @State private var revealTask: Task<Void, Never>?
    @State private var tryCount = 0
    @State private var breathing = false

    private var listening: Bool { model.onboardingTryListening }
    private var transcribing: Bool { listening && model.liveText == "Transcribing..." }
    private var done: Bool { model.onboardingTryState == .granted }
    private var revealDone: Bool { revealedText == model.onboardingTryText }
    private var keyLabel: String { model.settings.hotkeyTrigger.displayLabel }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        listening ? SettingsTheme.accent.opacity(breathing ? 0.7 : 0.4) : Color.white.opacity(0.06),
                        lineWidth: 1)
                VStack(alignment: .leading, spacing: 0) {
                    SelectableTextView(
                        text: .constant(revealedText),
                        editable: false,
                        highlightWords: revealDone ? model.onboardingTryHighlights : [],
                        onSelectionChange: { _, _, _ in },
                        onScroll: {}
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(10)
                    statusRow
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if tryCount >= 2 {
                Text("\(tryCount) dictations")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .transition(.opacity)
            }
        }
        .frame(maxHeight: .infinity)
        .onChange(of: model.onboardingTryText) { _, new in
            reveal(new)
            tryCount += 1
        }
        .onChange(of: listening) { _, isListening in updateBreathing(isListening) }
        .onAppear { updateBreathing(listening) }
        .animation(.easeOut(duration: 0.2), value: tryCount)
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            if transcribing {
                OnboardingPulseDot()
                Text("Transcribing").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            } else if listening {
                WaveformBarsView(level: model.level).frame(width: 80, height: 18)
                Text("Listening...").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            } else if done {
                OnboardingMark(state: .granted, reduceMotion: model.reduceMotion)
                Text("Got it").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            } else {
                OnboardingMark(state: .notAsked, reduceMotion: model.reduceMotion)
                Text("Waiting for \(keyLabel)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func updateBreathing(_ isListening: Bool) {
        guard isListening, !model.reduceMotion else {
            breathing = false
            return
        }
        breathing = false
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { breathing = true }
    }

    /// 12 ms per character, capped at 0.6 s total - never a slow reveal on a
    /// long result.
    private func reveal(_ text: String) {
        revealTask?.cancel()
        guard !text.isEmpty else {
            revealedText = ""
            return
        }
        guard !model.reduceMotion else {
            revealedText = text
            return
        }
        let chars = Array(text)
        let perChar = min(0.012, 0.6 / Double(max(chars.count, 1)))
        revealTask = Task { @MainActor in
            revealedText = ""
            for ch in chars {
                revealedText.append(ch)
                try? await Task.sleep(for: .seconds(perChar))
                if Task.isCancelled { return }
            }
        }
    }
}

// MARK: - Step 8: Start

struct StartStep: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        OnboardingStepFrame(
            model: model, showBack: true,
            title: "You are set",
            subtitle: "Everything is unlocked for 3 days: dictation, notes, meetings. No account, no card."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    StartTrialPillButton(model: model)
                        .entrance(delay: 0, reduceMotion: model.reduceMotion)
                    BuyLicensePillButton(model: model)
                        .entrance(delay: 0.06, reduceMotion: model.reduceMotion)
                }
                .frame(height: 40)
                Text(OnboardingPricing.priceLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                    .padding(.top, 2)
                LicenseKeyRow(model: model)
            }
        }
    }
}

/// White, fills green and shows the trial end date on itself as it commits,
/// then the coordinator retracts the panel and fires the finish
/// notification.
private struct StartTrialPillButton: View {
    @ObservedObject var model: NotchModel
    @State private var committed = false

    private var trialEndsLabel: String {
        let end = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: end)
    }

    var body: some View {
        Button {
            guard !committed else { return }
            if model.reduceMotion {
                model.onboardingStartTrialRequest?()
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { committed = true }
                Task {
                    try? await Task.sleep(for: .milliseconds(420))
                    model.onboardingStartTrialRequest?()
                }
            }
        } label: {
            HStack(spacing: 6) {
                if committed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .transition(.scale.combined(with: .opacity))
                }
                Text(committed ? "Trial ends \(trialEndsLabel)" : "Start my 3-day trial")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(committed ? SettingsTheme.accent : Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointer()
        .hoverTip("Start my 3-day trial")
    }
}

private struct BuyLicensePillButton: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        Button { model.onboardingBuyRequest?() } label: {
            Text("Buy a license")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SettingsTheme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointer()
        .hoverTip("Buy a license")
    }
}

/// Full-width key field + same-height Activate pill, same field language as
/// Settings > License.
private struct LicenseKeyRow: View {
    @ObservedObject var model: NotchModel
    private var hasText: Bool { !model.onboardingLicenseKey.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            TextField("Paste your license key", text: Binding(
                get: { model.onboardingLicenseKey },
                set: { model.onboardingLicenseKey = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))

            Button {
                model.onboardingActivateRequest?(model.onboardingLicenseKey)
            } label: {
                Text("Activate")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(hasText ? Color.black : Color.white.opacity(0.4))
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(
                        hasText ? Color.white : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .pointer()
            .disabled(!hasText)
            .animation(.easeOut(duration: 0.15), value: hasText)
            .hoverTip("Activate")
        }
    }
}
