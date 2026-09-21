import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Result of attempting to deliver transcribed text to the frontmost app.
public enum TextDeliveryResult: Equatable, Sendable {
    case inserted
    case copiedOnly
    case failed(String)
}

/// Pastes text into the frontmost app via the pasteboard + a Cmd-V CGEvent,
/// restoring the previous pasteboard contents 300 ms later. Concept lifted
/// from OpenDictation's `TextInsertionService` (Universal Paste), trimmed to
/// the fixed 300 ms restore this spec calls for instead of that service's
/// multi-tier verified-write/changeCount-tracked restore.
@MainActor
public final class TextInserter {
    private let restoreDelay: TimeInterval
    private var pendingRestore: [[NSPasteboard.PasteboardType: Data]]?
    private var insertedChangeCount: Int?

    public init(restoreDelay: TimeInterval = 0.3) {
        self.restoreDelay = restoreDelay
    }

    /// Accessibility permission check, required to simulate the Cmd-V
    /// keystroke. Without it, `insert` still copies to the clipboard and
    /// returns `.copiedOnly`.
    public static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the system Accessibility dialog if not yet decided, otherwise
    /// opens System Settings so the user can grant it manually.
    public static func requestAccessibilityPermission() {
        // The literal key value (stable ABI, documented by Apple) instead of
        // the imported `kAXTrustedCheckOptionPrompt` global: that CFString
        // constant is flagged as concurrency-unsafe shared mutable state
        // under Swift 6 strict concurrency.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public func insert(_ text: String) -> TextDeliveryResult {
        let pasteboard = NSPasteboard.general
        let saved = Self.savePasteboardContents(pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return .failed("Failed to write text to the clipboard.")
        }
        let changeCount = pasteboard.changeCount

        guard Self.isAccessibilityTrusted() else {
            return .copiedOnly
        }
        guard Self.simulatePasteKeystroke() else {
            Self.restorePasteboardContents(saved, to: pasteboard)
            return .failed("Failed to simulate the paste keystroke.")
        }

        pendingRestore = saved
        insertedChangeCount = changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [weak self] in
            self?.restoreIfStillOurs()
        }
        return .inserted
    }

    private func restoreIfStillOurs() {
        guard let saved = pendingRestore, let expected = insertedChangeCount else { return }
        pendingRestore = nil
        insertedChangeCount = nil
        let pasteboard = NSPasteboard.general
        // Only restore if nothing else has written to the clipboard since our
        // paste - a newer copy (the user's) must never be clobbered.
        guard pasteboard.changeCount == expected else { return }
        Self.restorePasteboardContents(saved, to: pasteboard)
    }

    private static func savePasteboardContents(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let value = item.data(forType: type) { data[type] = value }
            }
            return data
        }
    }

    private static func restorePasteboardContents(
        _ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { itemData -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in itemData { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private static func simulatePasteKeystroke() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)

        let commandKey = CGKeyCode(kVK_Command)
        let vKey = CGKeyCode(kVK_ANSI_V)
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: false)
        else { return false }
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        cmdDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
        return true
    }
}
