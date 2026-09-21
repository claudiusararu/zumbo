import CryptoKit
import XCTest
@testable import VesperEngine

final class LicenseCoreTests: XCTestCase {

    private func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9, calendar: Calendar) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day; components.hour = hour
        return calendar.date(from: components)!
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: - Trial math

    func testTrialEndsOnThirdCalendarDay() {
        let calendar = utcCalendar()
        let start = makeDate(2026, 9, 20, calendar: calendar)
        let end = TrialWindow.endDate(start: start, calendar: calendar)
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: end)
        XCTAssertEqual(c.year, 2026); XCTAssertEqual(c.month, 9); XCTAssertEqual(c.day, 22)
        XCTAssertEqual(c.hour, 23); XCTAssertEqual(c.minute, 59); XCTAssertEqual(c.second, 59)
    }

    func testDaysLeftMatchesSpecExample() {
        let calendar = utcCalendar()
        let start = makeDate(2026, 9, 20, calendar: calendar)
        XCTAssertEqual(TrialWindow.daysLeft(now: start, start: start, calendar: calendar), 2)
        let lastDay = makeDate(2026, 9, 22, calendar: calendar)
        XCTAssertEqual(TrialWindow.daysLeft(now: lastDay, start: start, calendar: calendar), 0)
        XCTAssertTrue(TrialWindow.isInFinalStretch(now: lastDay, start: start, calendar: calendar))
        let dayBefore = makeDate(2026, 9, 21, calendar: calendar)
        XCTAssertTrue(TrialWindow.isInFinalStretch(now: dayBefore, start: start, calendar: calendar))
    }

    func testTrialEndsAcrossMonthBoundary() {
        let calendar = utcCalendar()
        let start = makeDate(2026, 1, 30, calendar: calendar)
        let end = TrialWindow.endDate(start: start, calendar: calendar)
        let c = calendar.dateComponents([.month, .day], from: end)
        XCTAssertEqual(c.month, 2); XCTAssertEqual(c.day, 1)
    }

    func testTrialEndsAcrossDSTSpringForward() {
        // US Eastern: DST starts 2026-03-08. A trial starting the day before
        // must still land on the right calendar day at 23:59:59 local time.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let start = makeDate(2026, 3, 7, calendar: calendar)
        let end = TrialWindow.endDate(start: start, calendar: calendar)
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: end)
        XCTAssertEqual(c.month, 3); XCTAssertEqual(c.day, 9)
        XCTAssertEqual(c.hour, 23); XCTAssertEqual(c.minute, 59)
        XCTAssertFalse(TrialWindow.hasEnded(now: end.addingTimeInterval(-1), start: start, calendar: calendar))
        XCTAssertTrue(TrialWindow.hasEnded(now: end.addingTimeInterval(1), start: start, calendar: calendar))
    }

    func testHasEndedIsFalseUntilTheInstantAfterEnd() {
        let calendar = utcCalendar()
        let start = makeDate(2026, 9, 20, calendar: calendar)
        let end = TrialWindow.endDate(start: start, calendar: calendar)
        XCTAssertFalse(TrialWindow.hasEnded(now: end, start: start, calendar: calendar))
        XCTAssertTrue(TrialWindow.hasEnded(now: end.addingTimeInterval(1), start: start, calendar: calendar))
    }

    // MARK: - Token verification

    private func samplePayload() -> LicenseTokenPayload {
        LicenseTokenPayload(
            key: "\(LicenseKeyFormat.prefix)-TEST-TEST-TEST-TEST", machineId: "abc123", tier: .single,
            issuedAt: Date(timeIntervalSince1970: 1_758_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_789_536_000)
        )
    }

    func testValidSignatureVerifies() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let token = try LicenseTokenVerifier.sign(samplePayload(), privateKey: privateKey)
        XCTAssertTrue(LicenseTokenVerifier.verify(token, publicKey: privateKey.publicKey))
    }

    func testTamperedPayloadFailsVerification() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        var token = try LicenseTokenVerifier.sign(samplePayload(), privateKey: privateKey)
        token.payload.tier = .three
        XCTAssertFalse(LicenseTokenVerifier.verify(token, publicKey: privateKey.publicKey))
    }

    func testTeamTierRoundTripsAndCarriesTenMachineLimit() throws {
        XCTAssertEqual(LicenseTier(rawValue: "team"), .team)
        XCTAssertEqual(LicenseTier.team.maxMachines, 10)
        var payload = samplePayload()
        payload.tier = .team
        let privateKey = Curve25519.Signing.PrivateKey()
        let token = try LicenseTokenVerifier.sign(payload, privateKey: privateKey)
        XCTAssertTrue(LicenseTokenVerifier.verify(token, publicKey: privateKey.publicKey))
        XCTAssertEqual(token.payload.tier, .team)
    }

    func testWrongPublicKeyFailsVerification() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let otherKey = Curve25519.Signing.PrivateKey()
        let token = try LicenseTokenVerifier.sign(samplePayload(), privateKey: privateKey)
        XCTAssertFalse(LicenseTokenVerifier.verify(token, publicKey: otherKey.publicKey))
    }

    func testMalformedSignatureFailsVerification() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        var token = try LicenseTokenVerifier.sign(samplePayload(), privateKey: privateKey)
        token.signature = "not-base64!!"
        XCTAssertFalse(LicenseTokenVerifier.verify(token, publicKey: privateKey.publicKey))
    }

    // MARK: - Grace window

    func testGraceWindowIsThirtyDaysPastExpiry() {
        let calendar = utcCalendar()
        let payload = samplePayload()
        let graceEnd = LicenseGrace.graceEnd(for: payload, calendar: calendar)
        XCTAssertTrue(LicenseGrace.isWithinGrace(payload, now: payload.expiresAt, calendar: calendar))
        XCTAssertTrue(LicenseGrace.isWithinGrace(payload, now: graceEnd, calendar: calendar))
        XCTAssertFalse(LicenseGrace.isWithinGrace(payload, now: graceEnd.addingTimeInterval(1), calendar: calendar))
    }

    // MARK: - Key formatting

    func testUUIDFormatIsActivatableAndNormalizesToLowercase() {
        let mixedCase = "DB44b22c-FE9b-4a68-bf0d-B0E0D6C6C8C0"
        XCTAssertTrue(LicenseKeyFormatter.isActivatable(mixedCase))
        XCTAssertEqual(LicenseKeyFormatter.normalized(mixedCase), "db44b22c-fe9b-4a68-bf0d-b0e0d6c6c8c0")

        let alreadyLower = "db44b22c-fe9b-4a68-bf0d-b0e0d6c6c8c0"
        XCTAssertTrue(LicenseKeyFormatter.isActivatable(alreadyLower))
        XCTAssertEqual(LicenseKeyFormatter.normalized(alreadyLower), alreadyLower)
    }

    func testUUIDFormatIsNeverReformattedWhileTyping() {
        // Pasting a lowercase Dodo UUID must not get uppercased or have its
        // hyphens touched by anything the UI calls per keystroke - only
        // `normalized(_:)`, called on submit, changes case.
        let pasted = "db44b22c-fe9b-4a68-bf0d-b0e0d6c6c8c0"
        XCTAssertEqual(pasted, pasted) // no format-on-type step exists anymore
        XCTAssertTrue(LicenseKeyFormatter.isActivatable(pasted))
    }

    func testManualFormatIsActivatableAndNormalizesToUppercase() {
        XCTAssertTrue(LicenseKeyFormatter.isActivatable("zumb-test-test-test-test"))
        XCTAssertEqual(LicenseKeyFormatter.normalized("zumb-test-test-test-test"), "ZUMB-TEST-TEST-TEST-TEST")
        XCTAssertTrue(LicenseKeyFormatter.isActivatable("ZUMB-TEST-TEST-TEST-TEST"))
        XCTAssertEqual(LicenseKeyFormatter.normalized("ZUMB-TEST-TEST-TEST-TEST"), "ZUMB-TEST-TEST-TEST-TEST")
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertTrue(LicenseKeyFormatter.isActivatable("  db44b22c-fe9b-4a68-bf0d-b0e0d6c6c8c0 \n"))
        XCTAssertEqual(LicenseKeyFormatter.normalized("  ZUMB-TEST-TEST-TEST-TEST \n"), "ZUMB-TEST-TEST-TEST-TEST")
    }

    func testRejectsJunkInput() {
        XCTAssertFalse(LicenseKeyFormatter.isActivatable(""))
        XCTAssertFalse(LicenseKeyFormatter.isActivatable("   "))
        XCTAssertFalse(LicenseKeyFormatter.isActivatable("ZUMB-TEST"))
        XCTAssertFalse(LicenseKeyFormatter.isActivatable("not a key at all"))
        XCTAssertFalse(LicenseKeyFormatter.isActivatable("ABCD-TEST-TEST-TEST-TEST"))
        // Too short / malformed UUID (missing a group).
        XCTAssertFalse(LicenseKeyFormatter.isActivatable("db44b22c-fe9b-4a68-bf0d"))
        // Right length, wrong shape (no hyphens).
        XCTAssertFalse(LicenseKeyFormatter.isActivatable("db44b22cfe9b4a68bf0db0e0d6c6c8c0"))
    }

    func testPlaceholderIsNotItselfAValidKey() {
        XCTAssertFalse(LicenseKeyFormatter.isActivatable(LicenseKeyFormatter.placeholder))
    }
}
