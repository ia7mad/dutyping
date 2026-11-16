import XCTest
@testable import DutyPing

final class ReminderPlannerTests: XCTestCase {
    private var calendar: Calendar { Calendar.current }
    private var day: Date {
        calendar.date(from: DateComponents(year: 2030, month: 1, day: 7))!
    }
    private func time(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: second, of: day)!
    }
    private func planner(completed: Set<String> = [], snoozes: [String: Date] = [:]) -> ReminderPlanner {
        ReminderPlanner(calendar: calendar, isCompleted: { completed.contains($0) },
                        snoozedUntil: { snoozes[$0] })
    }

    func testOpeningAppAfterDeadlinePreservesOneTimeFollowUps() {
        let reminder = PersonalReminder(title: "Call", dueDate: time(8))
        let result = planner().plan(shifts: [], reminders: [reminder], settings: Settings(), now: time(8, 1))
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result.first?.fireDate, time(8, 5))
        XCTAssertTrue(result.allSatisfy { $0.seriesID == reminder.seriesID(for: reminder.dueDate) })
        XCTAssertTrue(result.allSatisfy { $0.dueDate == reminder.dueDate })
    }

    func testRecurringReminderRetainsTodaysOverdueFollowUps() {
        var reminder = PersonalReminder(title: "Medicine", dueDate: time(8))
        reminder.repeatRule = .daily
        let result = planner().plan(shifts: [], reminders: [reminder], settings: Settings(), now: time(8, 1))
        XCTAssertTrue(result.contains { $0.seriesID == reminder.seriesID(for: time(8)) && $0.fireDate == time(8, 5) })
    }

    func testOvernightShiftCheckoutSurvivesOpeningAfterMidnight() {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: day)!
        let shift = Shift(weekday: calendar.component(.weekday, from: yesterday),
                          start: TimeOfDay(hour: 22, minute: 0), end: TimeOfDay(hour: 6, minute: 0))
        var settings = Settings()
        settings.nagEnabled = false
        let result = planner().plan(shifts: [shift], reminders: [], settings: settings, now: time(5))
        XCTAssertTrue(result.contains { $0.kind == .checkOut && $0.fireDate == time(6) })
    }

    func testConfirmationOnlyClosesMatchingRecurringOccurrence() {
        var reminder = PersonalReminder(title: "Daily", dueDate: time(8))
        reminder.repeatRule = .daily
        let today = reminder.seriesID(for: time(8))
        let result = planner(completed: [today]).plan(shifts: [], reminders: [reminder],
                                                    settings: Settings(), now: time(7))
        XCTAssertFalse(result.contains { $0.seriesID == today })
        XCTAssertFalse(result.isEmpty)
    }

    func testSnoozeKeepsOriginalIdentityAcrossRebuilds() {
        let reminder = PersonalReminder(title: "Call", dueDate: time(8))
        let series = reminder.seriesID(for: reminder.dueDate)
        let subject = planner(snoozes: [series: time(8, 12)])
        for now in [time(8, 2), time(8, 4)] {
            let result = subject.plan(shifts: [], reminders: [reminder], settings: Settings(), now: now)
            XCTAssertEqual(result.first?.fireDate, time(8, 12))
            XCTAssertEqual(result.first?.dueDate, time(8, 12))
            XCTAssertTrue(result.allSatisfy { $0.seriesID == series && $0.fireDate >= time(8, 12) })
        }
    }

    func testCompletingSnoozedReminderPreventsOriginalAndSnoozedAlerts() {
        let reminder = PersonalReminder(title: "Call", dueDate: time(8))
        let series = reminder.seriesID(for: reminder.dueDate)
        let result = planner(completed: [series], snoozes: [series: time(8, 12)])
            .plan(shifts: [], reminders: [reminder], settings: Settings(), now: time(8, 2))
        XCTAssertTrue(result.isEmpty)
    }

    func testDisabledDeletedAndInboxTasksProduceNoNotifications() {
        var disabled = PersonalReminder(title: "Disabled", dueDate: time(8))
        disabled.isEnabled = false
        let inbox = PersonalReminder.inbox(title: "Inbox")
        XCTAssertTrue(planner().plan(shifts: [], reminders: [disabled, inbox], settings: Settings(), now: time(7)).isEmpty)
        XCTAssertTrue(planner().plan(shifts: [], reminders: [], settings: Settings(), now: time(7)).isEmpty)
    }

    func testPastCompletedOneTimeReminderStaysCompleted() {
        let reminder = PersonalReminder(title: "Done", dueDate: time(8))
        let result = planner(completed: [reminder.seriesID(for: reminder.dueDate)])
            .plan(shifts: [], reminders: [reminder], settings: Settings(), now: time(18))
        XCTAssertTrue(result.isEmpty)
    }

    func testQueueHonorsCapacityAndDoesNotStarveLaterFirstAlerts() {
        let reminders = (0..<40).map { index in
            PersonalReminder(title: "Task \(index)", dueDate: time(8).addingTimeInterval(Double(index) * 3600))
        }
        let result = planner().plan(shifts: [], reminders: reminders, settings: Settings(), now: time(7))
        XCTAssertEqual(result.count, 58)
        XCTAssertGreaterThanOrEqual(Set(result.map(\.seriesID)).count, 29)
    }

    func testDisabledFollowUpsCanUseEntireQueueForFirstAlerts() {
        let reminders = (0..<70).map { index in
            PersonalReminder(title: "Task \(index)", dueDate: time(8).addingTimeInterval(Double(index) * 3600))
        }
        var settings = Settings()
        settings.nagEnabled = false
        let result = planner().plan(shifts: [], reminders: reminders, settings: settings, now: time(7))
        XCTAssertEqual(result.count, 58)
        XCTAssertTrue(result.allSatisfy { $0.nagIndex == 0 })
    }

    func testPauseExcludesAllAlertsBeforeResumeIncludingSnoozes() {
        let reminder = PersonalReminder(title: "Pause", dueDate: time(8))
        var settings = Settings()
        settings.pausedUntil = time(9)
        let result = planner(snoozes: [reminder.seriesID(for: time(8)): time(8, 10)])
            .plan(shifts: [], reminders: [reminder], settings: settings, now: time(7))
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.allSatisfy { $0.fireDate >= time(9) })
    }

    func testRelativeReminderRetainsSeconds() {
        let reminder = PersonalReminder(title: "In a minute", dueDate: time(8, 1, 45))
        let result = planner().plan(shifts: [], reminders: [reminder], settings: Settings(), now: time(8))
        XCTAssertEqual(result.first?.fireDate, time(8, 1, 45))
    }

    func testFirstRecurringOccurrenceIsNotLostToFractionalSeconds() {
        var reminder = PersonalReminder(title: "Daily", dueDate: time(8, 1, 45).addingTimeInterval(0.5))
        reminder.repeatRule = .daily
        let result = planner().plan(shifts: [], reminders: [reminder], settings: Settings(), now: time(8))
        XCTAssertEqual(result.first?.fireDate, time(8, 1, 45))
    }

    func testOldVersionRecurringConfirmationIsStillHonored() {
        var reminder = PersonalReminder(title: "Daily", dueDate: time(8, 1, 45))
        reminder.repeatRule = .daily
        let oldSeries = reminder.seriesID(for: time(8, 1))
        let result = planner(completed: [oldSeries]).plan(shifts: [], reminders: [reminder], settings: Settings(), now: time(8))
        XCTAssertFalse(result.contains { $0.dueDate == time(8, 1, 45) })
        XCTAssertFalse(result.isEmpty)
    }

    func testEditingDueDateInvalidatesPreviouslyDeliveredOccurrence() {
        var reminder = PersonalReminder(title: "Moved", dueDate: time(8))
        let original = reminder.seriesID(for: reminder.dueDate)
        XCTAssertTrue(reminder.ownsSeries(original))
        reminder.dueDate = time(9)
        XCTAssertFalse(reminder.ownsSeries(original))
    }

    func testExpiredPersistentOneTimeQueueRecoversOnReopen() {
        let reminder = PersonalReminder(title: "Overdue", dueDate: time(0))
        let reopenDate = time(23).addingTimeInterval(3 * 86400)
        let result = planner().plan(shifts: [], reminders: [reminder], settings: Settings(), now: reopenDate)
        XCTAssertEqual(result.first?.fireDate, reopenDate.addingTimeInterval(5 * 60))
    }

    func testZeroRemainingCapacityDoesNotScheduleAnything() {
        let reminder = PersonalReminder(title: "Full", dueDate: time(8))
        XCTAssertTrue(planner().plan(shifts: [], reminders: [reminder], settings: Settings(), now: time(7), limit: 0).isEmpty)
    }

    func testFiniteFollowUpsRespectSelectedCountAndInterval() {
        var settings = Settings()
        settings.persistentFollowUps = false
        settings.nagIntervalMinutes = 3
        settings.nagCount = 2
        let reminder = PersonalReminder(title: "Finite", dueDate: time(8))
        let result = planner().plan(shifts: [], reminders: [reminder], settings: settings, now: time(7))
        XCTAssertEqual(result.map(\.fireDate), [time(8), time(8, 3), time(8, 6)])
    }
}
