import XCTest
@testable import VesperEngine

final class ReminderParserTests: XCTestCase {

    /// A fixed calendar (UTC, so the test is not sensitive to the machine's
    /// own time zone) and a fixed reference: Wednesday 2026-09-16, 14:00.
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private var reference: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 14, minute: 0))!
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func parse(_ text: String) -> ReminderParser.Outcome {
        ReminderParser.parse(text, reference: reference, calendar: calendar)
    }

    // MARK: - Relative offsets

    func testInMinutes() {
        XCTAssertEqual(parse("remind me in 20 minutes"), .date(reference.addingTimeInterval(20 * 60)))
    }

    func testInHours() {
        XCTAssertEqual(parse("ping me in 2 hours"), .date(reference.addingTimeInterval(2 * 3600)))
    }

    // MARK: - Named dayparts

    func testThisEvening() {
        XCTAssertEqual(parse("take out the trash this evening"), .date(date(2026, 9, 16, 18)))
    }

    func testTonight() {
        XCTAssertEqual(parse("call mom tonight"), .date(date(2026, 9, 16, 20)))
    }

    func testThisAfternoon() {
        XCTAssertEqual(parse("pick up the package this afternoon"), .date(date(2026, 9, 16, 15)))
    }

    func testThisEveningWithExplicitTimeOverridesTheDefaultHour() {
        // NOTES.md's own example: "this evening at 7 p.m." should read 19:00,
        // not the bare "this evening" default of 18:00.
        XCTAssertEqual(
            parse("Remind me to take out the trash this evening at 7 p.m."),
            .date(date(2026, 9, 16, 19)))
    }

    // MARK: - Tomorrow

    func testTomorrowMorning() {
        XCTAssertEqual(parse("call Dana tomorrow morning"), .date(date(2026, 9, 17, 9)))
    }

    func testTomorrowAlone() {
        XCTAssertEqual(parse("water the plants tomorrow"), .date(date(2026, 9, 17, 9)))
    }

    // MARK: - Weekdays

    func testNextWeekday() {
        // Reference is a Wednesday; "next Monday" is the coming Monday, 5 days out.
        XCTAssertEqual(parse("next Monday"), .date(date(2026, 9, 21, 9)))
    }

    func testNextWeekdayWithExplicitTime() {
        XCTAssertEqual(parse("next Monday 3pm"), .date(date(2026, 9, 21, 15)))
    }

    func testWeekdayWithDaypart() {
        XCTAssertEqual(parse("Friday morning"), .date(date(2026, 9, 18, 9)))
    }

    // MARK: - Ambiguity

    func testBareHourWithNoDaypartAsks() {
        // Reference is 14:00: the 7 AM reading has already passed today, so
        // it rolls to tomorrow; the 7 PM reading is still ahead today.
        let outcome = parse("call me at 7")
        XCTAssertEqual(outcome, .ambiguous(date(2026, 9, 17, 7), date(2026, 9, 16, 19)))
    }

    func testPastTimeTodayRollsToTomorrow() {
        // Reference is 14:00; "at 10 a.m." has already passed today, so it
        // rolls to tomorrow instead of firing in the past.
        XCTAssertEqual(parse("stand-up at 10 a.m."), .date(date(2026, 9, 17, 10)))
    }

    // MARK: - No match

    func testNoTimePhrase() {
        XCTAssertEqual(parse("buy oat milk and coffee filters"), .none)
    }

    // MARK: - Task text

    func testTaskTextRemindMeToPhrasing() {
        XCTAssertEqual(
            ReminderParser.taskText(from: "Remind me to get off my chair and stretch a bit in 3 minutes."),
            "Get off my chair and stretch a bit.")
    }

    func testTaskTextReminderToPhrasing() {
        XCTAssertEqual(
            ReminderParser.taskText(from: "reminder to call Dana tomorrow morning."),
            "Call Dana.")
    }

    func testTaskTextSetAReminderToPhrasing() {
        XCTAssertEqual(
            ReminderParser.taskText(from: "set a reminder to water the plants next Monday."),
            "Water the plants.")
    }

    func testTaskTextFallsBackToOriginalWhenNothingReadableIsLeft() {
        XCTAssertEqual(
            ReminderParser.taskText(from: "Remind me in 20 minutes."),
            "Remind me in 20 minutes.")
    }
}
