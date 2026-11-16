import XCTest
@testable import DutyPing

final class ReminderPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func candidate(_ id: String = "task", after seconds: TimeInterval) -> ActivityCandidate {
        ActivityCandidate(seriesID: id, kind: "personal", title: id,
                          dueDate: now.addingTimeInterval(seconds), repeatIntervalMinutes: 5)
    }

    func testOlderIOSDoesNotShowAnHourLongCountdown() {
        XCTAssertNil(ReminderPresentationPolicy.next([candidate(after: 4200)], now: now, canSchedule: false))
    }

    func testOlderIOSAllowsExactlyTenMinutesAndNotEarlier() {
        XCTAssertNotNil(ReminderPresentationPolicy.next([candidate(after: 600)], now: now, canSchedule: false))
        XCTAssertNil(ReminderPresentationPolicy.next([candidate(after: 601)], now: now, canSchedule: false))
    }

    func testScheduledActivityStartsAtTenMinutesInsteadOfImmediately() throws {
        let next = try XCTUnwrap(ReminderPresentationPolicy.next([candidate(after: 4200)], now: now, canSchedule: true))
        XCTAssertEqual(next.startDate, now.addingTimeInterval(3600))
    }

    func testExistingOverdueTaskStaysUntilConfirmation() {
        let active = candidate("active", after: -60)
        let earlier = candidate("another", after: -120)
        XCTAssertEqual(ReminderPresentationPolicy.next([active, earlier, candidate(after: 300)],
            now: now, canSchedule: true, currentSeries: "active"), active)
    }

    func testAfterConfirmationNextTaskBecomesEligible() {
        let upcoming = candidate("next", after: 300)
        XCTAssertEqual(ReminderPresentationPolicy.next([upcoming], now: now,
            canSchedule: true, currentSeries: "completed"), upcoming)
    }

    func testNoCandidatesMeansNoActivity() {
        XCTAssertNil(ReminderPresentationPolicy.next([], now: now, canSchedule: true))
    }

    func testShiftAppearanceUsesRealStartInsteadOfCheckInDelay() throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        let shift = Shift(weekday: calendar.component(.weekday, from: day),
                          start: TimeOfDay(hour: 7, minute: 25), end: TimeOfDay(hour: 16, minute: 0))
        let beforeShift = calendar.date(bySettingHour: 6, minute: 15, second: 0, of: day)!
        let plan = ReminderPlanner(isCompleted: { _ in false }, snoozedUntil: { _ in nil })
            .plan(shifts: [shift], reminders: [], settings: Settings(), now: beforeShift)
        let checkIn = try XCTUnwrap(plan.first { $0.kind == .checkIn })
        XCTAssertEqual(calendar.component(.minute, from: checkIn.dueDate), 28)
        XCTAssertEqual(calendar.component(.minute, from: try XCTUnwrap(checkIn.activityDate)), 25)
    }

    private func occurrence(_ series: String, due: Date, index: Int) -> Occurrence {
        Occurrence(kind: .personal, title: series, body: "", followUpBody: "",
                   fireDate: due.addingTimeInterval(Double(index) * 300), dueDate: due,
                   seriesID: series, nagIndex: index, eventTitle: series,
                   isImportant: false, repeatIntervalMinutes: 5)
    }

    func testStrongAlarmIsOncePerOccurrenceInsteadOfEveryFollowUp() {
        let due = now.addingTimeInterval(600)
        let events = (0..<20).map { occurrence("one", due: due, index: $0) }
        XCTAssertEqual(ReminderPresentationPolicy.alarmOccurrences(events, now: now).count, 1)
    }

    func testOverdueFollowUpsDoNotCreateNewStrongAlarms() {
        let overdue = occurrence("past", due: now.addingTimeInterval(-60), index: 1)
        XCTAssertTrue(ReminderPresentationPolicy.alarmOccurrences([overdue], now: now).isEmpty)
    }

    func testStrongAlarmSchedulingIsBoundedAndKeepsNearestDeadlines() {
        let events = (1...30).reversed().map { occurrence("task-\($0)", due: now.addingTimeInterval(Double($0) * 600), index: 0) }
        let planned = ReminderPresentationPolicy.alarmOccurrences(events, now: now)
        XCTAssertEqual(planned.count, 20)
        XCTAssertEqual(planned.first?.seriesID, "task-1")
        XCTAssertEqual(planned.last?.seriesID, "task-20")
    }

    func testAlarmIdentitySurvivesRebuildsAndDiffersBetweenTasks() {
        XCTAssertEqual(AlarmIdentity.id(for: "original"), AlarmIdentity.id(for: "original"))
        XCTAssertNotEqual(AlarmIdentity.id(for: "original"), AlarmIdentity.id(for: "other"))
    }

    func testVoiceShortcutRequestIsConsumedOnce() throws {
        let suite = "DutyPingVoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: VoiceShortcutRequest.key)
        XCTAssertTrue(VoiceShortcutRequest.consume(defaults: defaults))
        XCTAssertFalse(VoiceShortcutRequest.consume(defaults: defaults))
    }

    func testOlderSettingsDoNotEnableLoudAlarmsWithoutConsent() throws {
        let data = try JSONEncoder().encode(Settings())
        let restored = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertFalse(restored.usesSilentModeAlarms)
    }

    func testEditingShiftInvalidatesItsOldActivityDate() throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        var shift = Shift(weekday: calendar.component(.weekday, from: day),
                          start: TimeOfDay(hour: 7, minute: 25), end: TimeOfDay(hour: 16, minute: 0))
        let series = "shift-\(shift.id.uuidString)-in-\(Int(day.timeIntervalSince1970))"
        let original = try XCTUnwrap(ReminderPresentationPolicy.currentDate(seriesID: series,
            kind: "checkIn", reminders: [], shifts: [shift]))
        shift.start = TimeOfDay(hour: 9, minute: 25)
        let updated = try XCTUnwrap(ReminderPresentationPolicy.currentDate(seriesID: series,
            kind: "checkIn", reminders: [], shifts: [shift]))
        XCTAssertEqual(updated.timeIntervalSince(original), 7200)
    }

    func testSnoozedShiftUsesSnoozeDeadlineForItsActivity() {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        let shift = Shift(weekday: calendar.component(.weekday, from: day),
                          start: TimeOfDay(hour: 7, minute: 25), end: TimeOfDay(hour: 16, minute: 0))
        let series = "shift-\(shift.id.uuidString)-in-\(Int(day.timeIntervalSince1970))"
        let snooze = now.addingTimeInterval(600)
        XCTAssertEqual(ReminderPresentationPolicy.currentDate(seriesID: series, kind: "checkIn",
            reminders: [], shifts: [shift], snoozedUntil: snooze), snooze)
    }
}
