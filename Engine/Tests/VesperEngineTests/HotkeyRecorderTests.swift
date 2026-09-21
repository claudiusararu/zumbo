import XCTest
@testable import VesperEngine

final class HotkeyRecorderTests: XCTestCase {

    // MARK: - Combo mapping

    func testComboRequiresAtLeastOneModifier() {
        // A lone letter, no modifier: refused.
        XCTAssertNil(HotkeyRecorder.comboTrigger(forKeyCode: 2, modifierFlags: []))
    }

    func testComboWithOptionSpace() {
        let trigger = HotkeyRecorder.comboTrigger(forKeyCode: 49, modifierFlags: .maskAlternate)
        guard case .combo(let combo) = trigger else { return XCTFail("expected a combo trigger") }
        XCTAssertEqual(combo.keyCode, 49)
        XCTAssertEqual(combo.modifierFlags, .maskAlternate)
        XCTAssertEqual(combo.displayLabel, "\u{2325} Space")
    }

    func testComboWithControlShiftD() {
        let flags: CGEventFlags = [.maskControl, .maskShift]
        let trigger = HotkeyRecorder.comboTrigger(forKeyCode: 2, modifierFlags: flags)
        guard case .combo(let combo) = trigger else { return XCTFail("expected a combo trigger") }
        XCTAssertEqual(combo.displayLabel, "\u{2303}\u{21e7}D")
    }

    func testComboStripsIrrelevantFlags() {
        // Caps lock, fn and non-coalesced bits should not leak into the
        // stored combo: HotkeyMonitor matches it as a subset of live flags,
        // so noise here would make the trigger stricter than intended.
        let noisy: CGEventFlags = [.maskAlternate, .maskAlphaShift, .maskSecondaryFn, .maskNonCoalesced]
        let trigger = HotkeyRecorder.comboTrigger(forKeyCode: 49, modifierFlags: noisy)
        guard case .combo(let combo) = trigger else { return XCTFail("expected a combo trigger") }
        XCTAssertEqual(combo.modifierFlags, .maskAlternate)
    }

    // MARK: - Lone-modifier mapping

    func testModifierForKeyCode() {
        XCTAssertEqual(HotkeyRecorder.modifier(forKeyCode: 61), .rightOption)
        XCTAssertEqual(HotkeyRecorder.modifier(forKeyCode: 54), .rightCommand)
        XCTAssertEqual(HotkeyRecorder.modifier(forKeyCode: 63), .fn)
        XCTAssertEqual(HotkeyRecorder.modifier(forKeyCode: 58), .leftOption)
        XCTAssertEqual(HotkeyRecorder.modifier(forKeyCode: 55), .leftCommand)
        XCTAssertEqual(HotkeyRecorder.modifier(forKeyCode: 59), .control)
    }

    func testModifierForUnknownKeyCodeIsNil() {
        XCTAssertNil(HotkeyRecorder.modifier(forKeyCode: 2)) // 'D', not a modifier key.
    }

    // MARK: - Display labels

    func testModifierDisplayLabels() {
        XCTAssertEqual(HotkeyModifier.rightOption.displayLabel, "Right \u{2325}")
        XCTAssertEqual(HotkeyModifier.fn.displayLabel, "Fn")
        XCTAssertEqual(HotkeyModifier.control.displayLabel, "\u{2303}")
    }

    func testTriggerDisplayLabelDelegates() {
        XCTAssertEqual(HotkeyTrigger.modifier(.rightOption).displayLabel, "Right \u{2325}")
        let combo = HotkeyCombo(keyCode: 49, modifierFlags: .maskAlternate)
        XCTAssertEqual(HotkeyTrigger.combo(combo).displayLabel, "\u{2325} Space")
    }

    // MARK: - Codable stability

    func testNewModifierCasesRoundTripAndOldDataStillDecodes() throws {
        for modifier in HotkeyModifier.allCases {
            let data = try JSONEncoder().encode(modifier)
            let decoded = try JSONDecoder().decode(HotkeyModifier.self, from: data)
            XCTAssertEqual(decoded, modifier)
        }
        // The three original cases keep their exact raw string, so a trigger
        // persisted before leftOption/leftCommand/control existed still
        // decodes: only new raw values were added, none changed.
        XCTAssertEqual(try JSONEncoder().encode(HotkeyModifier.fn), Data("\"fn\"".utf8))
        XCTAssertEqual(try JSONEncoder().encode(HotkeyModifier.rightOption), Data("\"rightOption\"".utf8))
        XCTAssertEqual(try JSONEncoder().encode(HotkeyModifier.rightCommand), Data("\"rightCommand\"".utf8))
    }
}
