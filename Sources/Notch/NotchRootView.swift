import AppKit
import SwiftUI

/// The single SwiftUI tree hosted in the panel. One shape, content swapped per
/// state, everything centered on the notch.
struct NotchRootView: View {

    @ObservedObject var model: NotchModel

    private var m: NotchMetrics { model.metrics }

    /// Vertical band at the top of the shape that is hidden behind the hardware
    /// notch, so content starts right under the notch bottom. On a notchless
    /// display it is just padding.
    private var topInset: CGFloat {
        m.hasNotch ? model.base.height : NotchMetrics.rowPadding
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(topRadius: m.topRadius, bottomRadius: m.bottomRadius)
                    .fill(Color.black)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: contentAlignment)
                    .padding(.horizontal, m.topRadius + 12)
                    .padding(.top, topInset)
                    .padding(.bottom, NotchMetrics.bottomPadding)
                    .opacity(model.contentVisible ? 1 : 0)
                    .scaleEffect(contentScale, anchor: .top)
                    .blur(radius: model.contentVisible || model.reduceMotion ? 0 : 3)
            }
            .frame(width: m.width, height: m.height)
            .opacity(shapeOpacity)
            // The fill fades on the last part of a retract, so the shape reads
            // as sliding back into the screen edge and then vanishing, and it
            // comes back instantly on the way out.
            .animation(fillFade, value: shapeOpacity)
            .contentShape(NotchShape(topRadius: m.topRadius, bottomRadius: m.bottomRadius))
            // Forgiving target: anywhere on the recording panel stops it.
            .onTapGesture {
                if model.state == .recording { model.stopRequest?() }
            }
            .modifier(PointingHandCursor(active: model.state == .recording))

            // A second black rounded rectangle below the expanded panel, in
            // the same window, never part of `NotchShape` itself: the shape
            // must not stretch over it.
            if model.state == .expanded, let detailID = model.detailEntryID {
                HistoryDetailPanelView(
                    history: model.history,
                    entryID: detailID,
                    settings: model.settings,
                    reduceMotion: model.reduceMotion,
                    notificationsDenied: model.notificationsDenied,
                    onClose: { model.setDetailEntryRequest?(nil) },
                    onInsertAgain: { model.insertAgainRequest?($0) },
                    onSetReminder: { model.setReminderRequest?(detailID, $0) },
                    onCancelReminder: { model.cancelReminderRequest?(detailID) },
                    demoOpenTeach: model.demoOpenTeach
                )
                // The notch shape flares outward by topRadius at the top only;
                // its body is narrower than m.width. Match the body, not the flares.
                .frame(width: m.width - 2 * m.topRadius)
                .padding(.top, NotchMetrics.detailPanelGap)
                .opacity(model.contentVisible ? 1 : 0)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    /// Idle never draws anything, on any display. The hardware notch is already
    /// black and a notchless display should look untouched.
    private var shapeOpacity: Double {
        model.state == .idle ? 0 : 1
    }

    private var fillFade: Animation {
        if model.reduceMotion { return .easeInOut(duration: 0.14) }
        return shapeOpacity == 0
            ? .easeIn(duration: 0.12).delay(0.13)   // tail of the retract
            : .easeOut(duration: 0.08)              // immediate on the way out
    }

    /// Expanded reads top down like a window. The small states look better with
    /// their row centered in the room below the hardware notch band.
    private var contentAlignment: Alignment {
        model.state == .expanded || model.state == .onboarding ? .top : .center
    }

    private var contentScale: CGFloat {
        if model.reduceMotion { return 1 }
        return model.contentVisible ? 1 : 0.9
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case .hover:
            QuickActionsRow(meetingOn: model.meetingModeOn) { model.quickActions?($0) }
                .hoverTipLayer()
        case .recording:
            RecordingContent(model: model)
                .hoverTipLayer()
        case .meeting:
            MeetingRecordingRow(model: model)
                .hoverTipLayer()
        case .done:
            DoneContent()
        case .notice:
            NoticeContent(
                notice: model.notice, action: { model.noticeAction?() },
                secondaryAction: { model.noticeSecondaryAction?() },
                dismiss: { model.collapseRequest?() })
                .hoverTipLayer()
        case .expanded:
            // Its own hoverTipLayer() is attached inside ExpandedPanelView's
            // body, not here: nesting two attachment points would draw the
            // same tooltip twice.
            ExpandedPanelView(
                history: model.history,
                settings: model.settings,
                licenseState: model.licenseState,
                page: model.expandedPage,
                historyLayout: model.historyLayout,
                initialSettingsCategory: model.initialSettingsCategory, initialKindFilter: model.initialKindFilter,
                modelReady: model.modelReady,
                pendingActivationKey: model.pendingActivationKey,
                onConsumePendingActivation: { model.pendingActivationKey = nil },
                onClose: { model.collapseRequest?() },
                onToggleLayout: { model.toggleHistoryLayoutRequest?() },
                onOpenSettings: { model.setExpandedPageRequest?(.settings) },
                onBack: { model.setExpandedPageRequest?(.history) },
                onOpenDetail: { model.setDetailEntryRequest?($0) }
            )
        case .onboarding:
            OnboardingRootView(model: model)
                .hoverTipLayer()
        case .locked:
            LockedContent(
                buyAction: { model.lockedBuyRequest?() },
                enterKeyAction: { model.lockedEnterKeyRequest?() })
                .hoverTipLayer()
        }
    }
}

// MARK: - Locked (hard gate)

/// NOTES.md's hard gate: "Your 3-day trial has ended." plus "Buy a license"
/// (green accent) and "Enter key" (white). One row, same shape as
/// `NoticeContent`: text left, pills right, vertically centered, message
/// wraps to a second line past 520 pt (`NotchMetrics.lockedSize`) while the
/// pills stay put. Static content - no `NotchNotice` needed since the
/// message never changes - shown by `NotchController.showLocked()` and
/// dismissed by Escape/click-outside like `.expanded`.
private struct LockedContent: View {
    let buyAction: () -> Void
    let enterKeyAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.28))

            Text("Your 3-day trial has ended.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button(action: buyAction) {
                    Text("Buy a license")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(SettingsTheme.accent, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .pointer()
                .hoverTip("Opens the checkout page")

                Button(action: enterKeyAction) {
                    Text("Enter key")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .pointer()
                .hoverTip("Opens Settings > License")
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Hover

private struct QuickActionsRow: View {

    let meetingOn: Bool
    let action: (NotchQuickAction) -> Void

    var body: some View {
        HStack(spacing: 14) {
            button("mic.fill", "Dictate", .dictate)
            button("note.text", "New note", .note)
            MeetingToggle(isOn: meetingOn) { action(.meeting) }
            button("clock.arrow.circlepath", "History", .history)
            button("gearshape.fill", "Settings", .settings)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func button(_ symbol: String, _ label: String, _ which: NotchQuickAction) -> some View {
        Button {
            action(which)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 20)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointer()
        .hoverTip(label)
        .accessibilityLabel(label)
    }
}

/// "Start a meeting" as a real toggle switch, not a click button: a track
/// and a knob that slides, green when on, so the state reads at a glance
/// (never just a momentary button press) and matches the Settings toggle
/// language (`PillToggle`) elsewhere in the app.
private struct MeetingToggle: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("Meeting mode")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                ZStack(alignment: isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isOn ? Color(red: 0.35, green: 0.85, blue: 0.45) : Color.white.opacity(0.22))
                    Circle()
                        .fill(Color.white.opacity(0.9))
                        .padding(2)
                }
                .frame(width: 26, height: 16)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointer()
        .animation(.spring(response: 0.26, dampingFraction: 0.78), value: isOn)
        .hoverTip("Meeting mode: what you record goes into a meeting note instead of being pasted. Turn it on, then press Right Option or Record.")
        .accessibilityLabel("Meeting mode")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Slow, never-frozen "still recording" pulse, for a paused meeting or any
/// quiet stretch of it - green, unlike the plain-dictation red dot, so the
/// two states are never confused at a glance.
private struct PulsingDot: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.6)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate / 1.1) % 2 == 0
            Circle()
                .fill(Color(red: 0.35, green: 0.85, blue: 0.45))
                .frame(width: 7, height: 7)
                .opacity(on ? 1 : 0.35)
                .animation(.easeInOut(duration: 0.55), value: on)
        }
    }
}

// MARK: - Meeting row

/// The persistent row while meeting mode is on: a green meeting icon (so it
/// is never mistaken for a plain dictation), the live waveform or a pulsing
/// dot when paused, a live m:ss timer that only counts recorded time, a
/// transient "Saved, N words" flash after each chunk lands, then Pause/Resume
/// and a two-step Stop.
private struct MeetingRecordingRow: View {

    @ObservedObject var model: NotchModel
    @State private var stopConfirming = false
    @State private var confirmRevertTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            if stopConfirming {
                Text("End meeting?")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Keep going") { armStopConfirm(false) }
                    .buttonStyle(.plain)
                    .pointer()
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Button {
                    armStopConfirm(false)
                    model.meetingEndRequest?()
                } label: {
                    Text("End")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.white, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .pointer()
            } else {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.35, green: 0.85, blue: 0.45))
                    .hoverTip(model.meetingIsPaused
                        ? "Meeting mode is on. Nothing is recorded until you press Record or Right Option."
                        : "A meeting is recording. Nothing is pasted; it is saved to the meeting note.")

                Group {
                    if let saved = model.meetingSavedNotice {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(red: 0.35, green: 0.85, blue: 0.45))
                            Text(saved)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white)
                                .fixedSize()
                        }
                    } else if model.meetingIsPaused {
                        HStack(spacing: 6) {
                            PulsingDot()
                            Text(model.meetingElapsedBase > 0 ? "Paused" : "Press Right Option or Record to start")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.6))
                                .fixedSize()
                        }
                    } else {
                        WaveformBarsView(level: model.level)
                            .frame(width: 56, height: 18)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.15), value: model.meetingSavedNotice)

                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    Text(elapsed(at: context.date))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                }

                MeetingPauseButton(isPaused: model.meetingIsPaused) { model.meetingPauseToggleRequest?() }

                Button { armStopConfirm(true) } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .pointer()
                .hoverTip("End the meeting")
                .accessibilityLabel("End meeting")
            }
        }
        .frame(height: NotchMetrics.contentRowHeight)
    }

    private func armStopConfirm(_ on: Bool) {
        confirmRevertTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { stopConfirming = on }
        guard on else { return }
        confirmRevertTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { stopConfirming = false }
        }
    }

    /// Recorded time only: `meetingRunStartedAt` is nil while paused, so the
    /// live tick simply stops advancing instead of needing its own pause math.
    private func elapsed(at now: Date) -> String {
        var seconds = model.meetingElapsedBase
        if let runStartedAt = model.meetingRunStartedAt {
            seconds += now.timeIntervalSince(runStartedAt)
        }
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// Pause: skip a part of the meeting, discoverable rather than hotkey-only -
/// becomes green Resume while paused.
private struct MeetingPauseButton: View {
    let isPaused: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isPaused ? "record.circle.fill" : "pause.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(isPaused ? Color(red: 0.35, green: 0.85, blue: 0.45) : .white.opacity(hovering ? 1 : 0.85))
                .frame(width: 19, height: 19)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointer()
        .hoverTip(
            isPaused
                ? "Record: start recording into this meeting note (Right Option does the same)"
                : "Pause: stop recording for now, nothing is heard until you press Record again")
        .accessibilityLabel(isPaused ? "Record meeting" : "Pause meeting")
    }
}

// MARK: - Recording

private struct RecordingContent: View {

    @ObservedObject var model: NotchModel

    /// One row: meter, live text, then the red dot and the clock. Same row on
    /// every display, so there is never an empty band of black.
    var body: some View {
        HStack(spacing: 8) {
            WaveformBarsView(level: model.level)
                .frame(width: 80, height: 18)

            Text(model.recordingContext == .note ? "Note" : model.liveText)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            StopButton { model.stopRequest?() }

            RecordingDot()

            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(elapsed(at: context.date))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
            }
        }
        .frame(height: NotchMetrics.contentRowHeight)
    }

    private func elapsed(at now: Date) -> String {
        guard let start = model.recordingStartedAt else { return "0:00" }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The discoverable way to stop with the mouse. Sits left of the red dot and
/// the clock, which stay passive indicators.
private struct StopButton: View {

    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 19))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.85))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointer()
        .hoverTip("Stop dictation")
        .accessibilityLabel("Stop dictation")
    }
}

/// Passive red dot with a slow pulse, next to the elapsed time.
private struct RecordingDot: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Circle()
                .fill(Color(red: 0.98, green: 0.24, blue: 0.24))
                .frame(width: 7, height: 7)
                .opacity(on ? 1 : 0.45)
                .animation(.easeInOut(duration: 0.5), value: on)
        }
    }
}

/// Pointing-hand cursor while the panel is a click target, balanced push/pop.
private struct PointingHandCursor: ViewModifier {

    let active: Bool

    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, active, !pushed {
                    NSCursor.pointingHand.push()
                    pushed = true
                } else if (!inside || !active), pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}

// MARK: - Notice

/// A missing permission, or the model still loading. Same one row as every
/// other small state: glyph, message, optional button.
private struct NoticeContent: View {

    let notice: NotchNotice?
    let action: () -> Void
    var secondaryAction: () -> Void = {}

    /// The permission-style icon reads oddly on a reminder message; those
    /// always carry a bell instead. A reminder notice is always the one with
    /// a second pill, or the word "Reminder"/"Missed reminder" in the text.
    private var isReminder: Bool {
        notice?.secondaryActionTitle != nil
            || (notice?.message.hasPrefix("Reminder") ?? false)
            || (notice?.message.hasPrefix("Missed reminder") ?? false)
            || (notice?.message.hasPrefix("Note saved. Remind") ?? false)
    }

    /// An update actively downloading or installing (`UpdateDriver`) - not
    /// a warning, so it gets the download glyph instead of the triangle.
    /// `progress` is set while downloading; "Installing..." can follow with
    /// `progress` back to nil, so both are checked.
    private var isUpdateInProgress: Bool {
        notice?.progress != nil || notice?.message == "Installing..."
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: isUpdateInProgress ? "arrow.down.circle.fill" : (isReminder ? "bell.fill" : "exclamationmark.triangle.fill"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    isUpdateInProgress ? Color(red: 0.35, green: 0.85, blue: 0.45)
                        : isReminder ? Color(red: 0.35, green: 0.85, blue: 0.45)
                        : Color(red: 1.0, green: 0.78, blue: 0.28))

            // Sized to the message by `NotchMetrics.noticeSize` (up to 3
            // lines), so a long disclosure like the meeting one is never cut
            // off - never a fixed one-line truncation. A fixed line height
            // (matching the pills' own height) keeps a one-line message
            // centered with the icon and the pills instead of sitting on
            // its own baseline above them.
            Text(notice?.message ?? "")
                .font(.system(size: 11, weight: .medium))
                .lineSpacing(3)
                .foregroundStyle(.white)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 20)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let secondaryTitle = notice?.secondaryActionTitle {
                Button(action: secondaryAction) {
                    Text(secondaryTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.14), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .pointer()
                .accessibilityLabel(secondaryTitle)
            }

            if let title = notice?.actionTitle {
                Button(action: action) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black)
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Color.white, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .pointer()
                .accessibilityLabel(title)
            }

            if notice?.dismissible == true {
                Button(action: { dismiss?() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .pointer()
                .hoverTip("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .frame(minHeight: NotchMetrics.contentRowHeight)
        .overlay(alignment: .bottom) {
            // The updater's download/install line. An overlay, not a row in
            // the stack: it must not add height, because the notice's height
            // is measured from the message alone.
            if let progress = notice?.progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.14))
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.85))
                            .frame(width: max(2, proxy.size.width * CGFloat(min(max(progress, 0), 1))))
                    }
                }
                .frame(height: 2)
                .animation(.easeOut(duration: 0.2), value: progress)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Dismiss on click anywhere in the row when there is no explicit
            // action button (which already dismisses itself via `action`).
            if notice?.actionTitle == nil { dismiss?() }
        }
    }

    /// Background-tap dismissal, nil when an action button already owns the
    /// tap (see above).
    var dismiss: (() -> Void)?
}

// MARK: - Done

private struct DoneContent: View {

    @State private var progress: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            CheckmarkShape()
                .trim(from: 0, to: progress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 16)
            Text("Inserted")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.28)) { progress = 1 }
        }
    }
}

/// A check that can draw itself with `.trim`.
struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.80))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.86, y: rect.minY + rect.height * 0.24))
        return path
    }
}
