import FluidAudio
import XCTest
@testable import VesperEngine

/// `AppSettings.language`/`.multilingual` -> FluidAudio `Language` mapping.
/// Exercises the same path `DictationSession.setLanguage` uses, so a typo
/// in a code (e.g. onboarding writing "eng" instead of "en") is caught here
/// rather than surfacing as a silent English fallback in the app.
final class DictationLanguageTests: XCTestCase {
    func testSettingsCodeMapsToMatchingLanguage() {
        XCTAssertEqual(Language.forSettingsCode("en"), .english)
        XCTAssertEqual(Language.forSettingsCode("ro"), .romanian)
        XCTAssertEqual(Language.forSettingsCode("ru"), .russian)
    }

    func testUnrecognizedCodeFallsBackToEnglish() {
        XCTAssertEqual(Language.forSettingsCode("xx"), .english)
        XCTAssertEqual(Language.forSettingsCode(""), .english)
    }

    /// Same ternary `DictationSession.setLanguage`/`MeetingSession.language`
    /// use: `multilingual` true always wins, `code` is ignored. Exercised
    /// here directly (not through `DictationSession`, which owns live
    /// `AudioCapture`/`Transcriber` instances unsuited to a unit test) so
    /// the mapping itself is covered without a full session.
    private func hint(code: String, multilingual: Bool) -> Language? {
        multilingual ? nil : .forSettingsCode(code)
    }

    func testMultilingualAlwaysMapsToNilRegardlessOfCode() {
        XCTAssertNil(hint(code: "fr", multilingual: true))
    }

    func testSingleLanguageMapsToThatHint() {
        XCTAssertEqual(hint(code: "fr", multilingual: false), .french)
    }

    func testMenuOptionsListEnglishFirstThenAlphabetical() {
        let options = DictationLanguageOption.menuOptions
        XCTAssertEqual(options.first?.code, "en")
        let rest = options.dropFirst().map(\.displayName)
        XCTAssertEqual(rest, rest.sorted())
    }
}
