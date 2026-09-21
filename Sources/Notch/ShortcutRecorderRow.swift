import AppKit
import CoreGraphics
import SwiftUI
import VesperEngine

/// The "Shortcut" row in Settings > General. Shows the current trigger as a
/// keycap-style label; "Change" swaps it for a live recorder that captures
/// the next key event and maps it to a `HotkeyTrigger`.
///
/// The panel is key-capable while expanded (`NotchPanel.isKeyCapable`), so a
/// local `NSEvent` monitor sees the key normally; a global monitor is kept as
/// a fallback in case focus is momentarily elsewhere (e.g. right after the
/// "Change" button click before the panel regains key status).
struct ShortcutRecorderRow: View {
    @ObservedObject var settings: AppSettings
    /// False (the default) is the main "Hold to dictate" trigger; true is the
    /// second, optional note-only trigger (`AppSettings.noteHotkeyTrigger`,
    /// nil = off).
    var isNote = false

    @State private var isRecording = false
    @State private var errorMessage: String?
    @State private var localMonitor: Any?
    @State private var globalMonitor: Any?
    /// The modifier key code seen on the first `flagsChanged` of the current
    /// recording session (its key-down). A second `flagsChanged` for the
    /// same code is its key-up, i.e. a completed press-and-release.
    @State private var pendingModifierKeyCode: UInt16?

    private var title: String { isNote ? "Note shortcut" : "Hold to dictate" }
    private var subtitle: String {
        isNote
            ? "Start a note from anywhere, without pasting into the app you are in. Off until you set one."
            : "Tap to toggle, hold for push-to-talk"
    }
    private var currentTrigger: HotkeyTrigger? { isNote ? settings.noteHotkeyTrigger : settings.hotkeyTrigger }
    private var otherTrigger: HotkeyTrigger? { isNote ? settings.hotkeyTrigger : settings.noteHotkeyTrigger }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.92))
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 8)
                keycap
            }

            HStack(spacing: 8) {
                Button(isRecording ? "Cancel" : (currentTrigger == nil ? "Set" : "Change")) {
                    if isRecording {
                        stopRecording(applying: nil)
                    } else {
                        startRecording()
                    }
                }
                .buttonStyle(.plain)
                .pointer()
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.10), in: Capsule())

                if isNote {
                    if currentTrigger != nil {
                        Button("Clear") {
                            stopRecording(applying: nil)
                            settings.noteHotkeyTrigger = nil
                        }
                        .buttonStyle(.plain)
                        .pointer()
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                    }
                } else {
                    Button("Reset to Right Option") {
                        stopRecording(applying: nil)
                        settings.hotkeyTrigger = .modifier(.rightOption)
                    }
                    .buttonStyle(.plain)
                    .pointer()
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.9))
            }

            permissionCaption
        }
        .onDisappear { stopRecording(applying: nil) }
    }

    private var keycap: some View {
        Text(isRecording ? "Press keys…" : (currentTrigger?.displayLabel ?? "Off"))
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minWidth: 104)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(isRecording ? 0.18 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(isRecording ? 0.35 : 0.14), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var permissionCaption: some View {
        switch currentTrigger {
        case .none:
            EmptyView()
        case .modifier:
            Text("Single modifier keys work without extra permissions")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        case .combo:
            if InputMonitoringPermission.isAuthorized() {
                EmptyView()
            } else {
                HStack(spacing: 8) {
                    Text("Key combos need Input Monitoring")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange.opacity(0.9))
                    Button("Allow") {
                        InputMonitoringPermission.request()
                    }
                    .buttonStyle(.plain)
                    .pointer()
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.15), in: Capsule())
                }
            }
        }
    }

    // MARK: - Recording

    private func startRecording() {
        errorMessage = nil
        isRecording = true
        pendingModifierKeyCode = nil
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event: event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event: event)
        }
    }

    private func stopRecording(applying trigger: HotkeyTrigger?) {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        isRecording = false
        pendingModifierKeyCode = nil
        if let trigger {
            guard trigger != otherTrigger else {
                errorMessage = isNote
                    ? "Already used for Hold to dictate"
                    : "Already used for the note shortcut"
                return
            }
            errorMessage = nil
            if isNote {
                settings.noteHotkeyTrigger = trigger
            } else {
                settings.hotkeyTrigger = trigger
            }
        }
    }

    private func handle(event: NSEvent) {
        guard isRecording else { return }

        if event.type == .keyDown, event.keyCode == 53 { // Escape cancels.
            stopRecording(applying: nil)
            return
        }

        // Read modifier flags off the CGEvent, matching exactly what
        // `HotkeyMonitor` itself reads from its CGEvent tap, so a recorded
        // trigger matches the live events it will later be compared against.
        guard let cgEvent = event.cgEvent else { return }
        let keyCode = UInt16(cgEvent.getIntegerValueField(.keyboardEventKeycode))

        if event.type == .keyDown {
            guard let trigger = HotkeyRecorder.comboTrigger(forKeyCode: keyCode, modifierFlags: cgEvent.flags) else {
                errorMessage = "Add a modifier, like \u{2325}Space"
                return
            }
            stopRecording(applying: trigger)
            return
        }

        if event.type == .flagsChanged {
            guard let modifier = HotkeyRecorder.modifier(forKeyCode: keyCode) else { return }
            // Accept on release, not press: a lone modifier is a
            // press-and-release gesture, and waiting for the key to come
            // back up avoids capturing a modifier that is actually the
            // start of a combo (e.g. Option held down before Space, which
            // arrives as a `.keyDown` and is handled above instead).
            if pendingModifierKeyCode == keyCode {
                pendingModifierKeyCode = nil
                stopRecording(applying: .modifier(modifier))
            } else {
                pendingModifierKeyCode = keyCode
            }
        }
    }
}
