import AppKit
import Carbon
import Foundation
import IOKit.hid

/// The single-modifier hold-to-record options this app offers (default:
/// Right Option). Concept and key codes lifted from OpenSuperWhisper's
/// `ModifierKeyMonitor`.
///
/// Fn/Globe note: on Apple keyboards with a Globe key, macOS's own "Press
/// Globe key" setting (System Settings > Keyboard) must be set to "Do
/// Nothing", otherwise the system dictation/emoji popup fights this trigger
/// for the same keypress. Document this in onboarding, not just the README.
public enum HotkeyModifier: String, CaseIterable, Codable, Sendable {
    case fn
    case rightOption
    case rightCommand
    // Added later than the three above: new raw values only, so decoding an
    // older saved trigger is unaffected.
    case leftOption
    case leftCommand
    case control

    var keyCode: UInt16 {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        case .leftOption: return 58
        case .leftCommand: return 55
        case .control: return 59
        }
    }

    var physicalEventFlag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightOption: return CGEventFlags(rawValue: UInt64(NX_DEVICERALTKEYMASK))
        case .rightCommand: return CGEventFlags(rawValue: UInt64(NX_DEVICERCMDKEYMASK))
        case .leftOption: return CGEventFlags(rawValue: UInt64(NX_DEVICELALTKEYMASK))
        case .leftCommand: return CGEventFlags(rawValue: UInt64(NX_DEVICELCMDKEYMASK))
        case .control: return CGEventFlags(rawValue: UInt64(NX_DEVICELCTLKEYMASK))
        }
    }

    /// Keycap-style label for the Settings row and the shortcut recorder.
    public var displayLabel: String {
        switch self {
        case .fn: return "Fn"
        case .rightOption: return "Right \u{2325}"
        case .rightCommand: return "Right \u{2318}"
        case .leftOption: return "Left \u{2325}"
        case .leftCommand: return "Left \u{2318}"
        case .control: return "\u{2303}"
        }
    }
}

/// A normal key-combo hotkey (e.g. Option-Space), as an alternative to a held
/// modifier. Stores the raw `CGEventFlags` value (not the type itself) so the
/// struct is trivially `Codable` for `UserDefaults` persistence.
public struct HotkeyCombo: Codable, Equatable, Sendable {
    public let keyCode: UInt16
    public let rawModifierFlags: UInt64

    public init(keyCode: UInt16, modifierFlags: CGEventFlags) {
        self.keyCode = keyCode
        self.rawModifierFlags = modifierFlags.rawValue
    }

    var modifierFlags: CGEventFlags { CGEventFlags(rawValue: rawModifierFlags) }

    /// Keycap-style label, e.g. "\u{2325} Space" or "\u{2303}\u{21e7}D". Single-character key
    /// labels (letters, digits) sit flush against the modifier glyphs; named
    /// keys (Space, Return, ...) get a space, matching how macOS itself
    /// renders menu shortcuts.
    public var displayLabel: String {
        var glyphs = ""
        if modifierFlags.contains(.maskControl) { glyphs += "\u{2303}" }
        if modifierFlags.contains(.maskAlternate) { glyphs += "\u{2325}" }
        if modifierFlags.contains(.maskShift) { glyphs += "\u{21e7}" }
        if modifierFlags.contains(.maskCommand) { glyphs += "\u{2318}" }
        let keyLabel = Self.keyLabels[keyCode] ?? "Key \(keyCode)"
        return keyLabel.count == 1 ? glyphs + keyLabel : glyphs + " " + keyLabel
    }

    /// ANSI-US layout labels for the keys a shortcut is likely to use. An
    /// approximation on other layouts, the same simplification most hotkey
    /// recorders make.
    static let keyLabels: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
        28: "8", 25: "9",
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Escape",
        123: "Left", 124: "Right", 125: "Down", 126: "Up",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

/// Which physical trigger drives hold-to-record. A plain value type so the
/// app can store the user's choice in `UserDefaults` and hand a new value to
/// a running `HotkeyMonitor` at any time - no restart required.
public enum HotkeyTrigger: Codable, Equatable, Sendable {
    case modifier(HotkeyModifier)
    case combo(HotkeyCombo)

    public static let defaultTrigger: HotkeyTrigger = .modifier(.rightOption)

    private static let userDefaultsKey = "com.vesper.hotkeyTrigger"

    public static func load(from defaults: UserDefaults = .standard) -> HotkeyTrigger {
        guard let data = defaults.data(forKey: userDefaultsKey),
              let trigger = try? JSONDecoder().decode(HotkeyTrigger.self, from: data)
        else { return .defaultTrigger }
        return trigger
    }

    /// Keycap-style label for the Settings row.
    public var displayLabel: String {
        switch self {
        case .modifier(let modifier): return modifier.displayLabel
        case .combo(let combo): return combo.displayLabel
        }
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.userDefaultsKey)
    }
}

/// Input Monitoring permission check/request, required for the CGEvent tap
/// this monitor installs.
public enum InputMonitoringPermission {
    public static func isAuthorized() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Shows the system prompt if undecided, otherwise opens System Settings.
    public static func request() {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            return
        case kIOHIDAccessTypeUnknown:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        default:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

/// Pure mapping from a captured key event to the `HotkeyTrigger` it
/// represents, shared by the Settings shortcut recorder and its unit tests.
/// No `NSEvent`/`CGEvent` dependency in the signatures themselves, so both
/// sides stay in sync with `HotkeyMonitor.handle(type:event:)` without
/// needing a live event to test against.
public enum HotkeyRecorder {
    /// The modifier bits the recorder cares about. Everything else (caps
    /// lock, fn, numeric pad, non-coalesced, ...) is noise: `HotkeyMonitor`
    /// already matches a stored combo as a subset of the live event's flags
    /// (see `handle(type:event:)`), so filtering here keeps the stored value
    /// exact without breaking that match later.
    static let relevantFlags: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]

    /// A key pressed with at least one modifier becomes a combo trigger.
    /// Returns `nil` for a lone key with no modifier at all - plain letters
    /// are reserved for typing, not shortcuts.
    public static func comboTrigger(forKeyCode keyCode: UInt16, modifierFlags: CGEventFlags) -> HotkeyTrigger? {
        let relevant = modifierFlags.intersection(relevantFlags)
        guard !relevant.isEmpty else { return nil }
        return .combo(HotkeyCombo(keyCode: keyCode, modifierFlags: relevant))
    }

    /// The `HotkeyModifier` a physical modifier key's key code corresponds
    /// to, if any. A lone modifier press-and-release becomes a modifier
    /// trigger.
    public static func modifier(forKeyCode keyCode: UInt16) -> HotkeyModifier? {
        HotkeyModifier.allCases.first { $0.keyCode == keyCode }
    }
}

/// Hold-to-record hotkey, hybrid and automatic: the same physical trigger
/// (a held modifier, or a normal key combo) does both.
///
/// - A press released within `tapHoldThreshold` is a **tap**: it toggles
///   recording on; the next tap toggles it off.
/// - A press held past `tapHoldThreshold` becomes **push-to-talk**: recording
///   starts the instant the threshold is crossed and stops on release.
///
/// `trigger` can be reassigned at any time - the underlying `CGEvent` tap
/// always listens for both `.flagsChanged` and `.keyDown`/`.keyUp`, so
/// switching between a modifier and a combo trigger never needs a
/// stop/start cycle.
public final class HotkeyMonitor {
    /// How long a press can last and still count as a tap (toggle), not a
    /// hold (push-to-talk).
    public static let tapHoldThreshold: TimeInterval = 0.3

    public var onPressed: (@Sendable () -> Void)?
    public var onReleased: (@Sendable () -> Void)?

    /// The active trigger. Reassigning this while running takes effect on the
    /// very next event - no need to call `stop()`/`start()` again. Any
    /// in-progress press-hold timer or an active toggle-on recording is
    /// safely resolved (a pending hold fires `onReleased` if it had already
    /// started recording) before the switch.
    public var trigger: HotkeyTrigger {
        didSet { resetInteractionState(firingReleaseIfRecording: true) }
    }

    /// True when the last start() could not create the event tap (no Input Monitoring).

    public private(set) var tapCreationFailed = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Permission-free path: modifier keys arrive through NSEvent global and
    /// local monitors for .flagsChanged, which macOS allows without Input
    /// Monitoring or Accessibility. The CGEvent tap is only needed for key
    /// combos (keyDown/keyUp of normal keys).
    private var flagsGlobalMonitor: Any?
    private var flagsLocalMonitor: Any?

    private var isKeyPhysicallyDown = false
    private var pressStart: Date?
    private var holdWorkItem: DispatchWorkItem?
    /// True once `onPressed` has fired for the current logical session
    /// (either a completed tap-toggle-on, or an escalated hold).
    private var isRecording = false
    /// True only when the *current* session escalated into push-to-talk, so
    /// release always stops it regardless of toggle state.
    private var isHoldSession = false

    public init(trigger: HotkeyTrigger = .defaultTrigger) {
        self.trigger = trigger
    }

    deinit {
        stop()
    }

    public func start() {
        stop()
        // A fixed superset mask: `trigger` can change at runtime, so the tap
        // must always be able to see both key styles.
        let eventMask =
            CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)

        if flagsGlobalMonitor == nil {
            flagsGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
                guard let self, let cg = event.cgEvent else { return }
                self.handle(type: .flagsChanged, event: cg)
            }
            flagsLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
                if let self, let cg = event.cgEvent { self.handle(type: .flagsChanged, event: cg) }
                return event
            }
        }
        // Modifier-only triggers are fully served by the monitors above; the
        // tap below adds normal-key combos and needs Input Monitoring. When it
        // cannot be created, modifier triggers keep working.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.reenable()
                    return Unmanaged.passUnretained(event)
                }
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Input Monitoring is bound to the code signature: a build signed
            // with a different identity is a new app to macOS and the tap
            // silently fails. Surface it instead of dying quietly.
            tapCreationFailed = true
            if case .combo = trigger { InputMonitoringPermission.request() }
            return
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        if let m = flagsGlobalMonitor { NSEvent.removeMonitor(m) }
        if let m = flagsLocalMonitor { NSEvent.removeMonitor(m) }
        flagsGlobalMonitor = nil
        flagsLocalMonitor = nil
        resetInteractionState(firingReleaseIfRecording: true)
    }

    private func reenable() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func resetInteractionState(firingReleaseIfRecording: Bool) {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        isKeyPhysicallyDown = false
        pressStart = nil
        let wasRecording = isRecording
        isRecording = false
        isHoldSession = false
        if firingReleaseIfRecording, wasRecording {
            let callback = onReleased
            DispatchQueue.main.async { callback?() }
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch trigger {
        case .modifier(let modifier):
            guard type == .flagsChanged else { return }
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode == modifier.keyCode else { return }
            setPhysicalKey(down: event.flags.contains(modifier.physicalEventFlag))
        case .combo(let combo):
            guard type == .keyDown || type == .keyUp else { return }
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode == combo.keyCode, event.flags.contains(combo.modifierFlags) else { return }
            setPhysicalKey(down: type == .keyDown)
        }
    }

    private func setPhysicalKey(down: Bool) {
        guard down != isKeyPhysicallyDown else { return }
        isKeyPhysicallyDown = down
        if down {
            handlePress()
        } else {
            handleRelease()
        }
    }

    private func handlePress() {
        pressStart = Date()
        // Already recording via a prior tap-toggle: a hold on top of that is
        // left alone (the toggle-on recording keeps going) rather than
        // starting a second, conflicting session.
        guard !isRecording else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isKeyPhysicallyDown, !self.isRecording else { return }
            self.isRecording = true
            self.isHoldSession = true
            let callback = self.onPressed
            DispatchQueue.main.async { callback?() }
        }
        holdWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tapHoldThreshold, execute: workItem)
    }

    private func handleRelease() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        let heldDuration = pressStart.map { Date().timeIntervalSince($0) } ?? 0
        pressStart = nil

        if isHoldSession {
            // Push-to-talk: release always stops it.
            isHoldSession = false
            isRecording = false
            let callback = onReleased
            DispatchQueue.main.async { callback?() }
            return
        }

        guard heldDuration < Self.tapHoldThreshold else {
            // Held past the threshold but never escalated (a toggle-on
            // recording was already in progress) - nothing to do.
            return
        }

        // A genuine tap: toggle.
        if isRecording {
            isRecording = false
            let callback = onReleased
            DispatchQueue.main.async { callback?() }
        } else {
            isRecording = true
            let callback = onPressed
            DispatchQueue.main.async { callback?() }
        }
    }
}
