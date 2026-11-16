import XCTest
@testable import DutyPing

final class AlarmDismissalTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 2_000_000_000)
    private var suite: String!
    private var defaults: UserDefaults!
    private var state: AcknowledgementStore!

    override func setUp() {
        super.setUp()
        suite = "DutyPingDismissalTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        state = AcknowledgementStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func event(_ index: Int, minutes: Int? = nil, interval: Int = 2) -> Occurrence {
        Occurrence(kind: .personal, title: "Call", body: "Call", followUpBody: "Still waiting",
                   fireDate: base.addingTimeInterval(Double(minutes ?? index * interval) * 60),
                   dueDate: base, seriesID: "original", nagIndex: index,
                   eventTitle: "Call", isImportant: true, repeatIntervalMinutes: interval)
    }

    func testSystemCloseButtonCannotConfirmATask() {
        XCTAssertEqual(AlarmButtonRole.systemStop.action, .silence)
        XCTAssertNotEqual(AlarmButtonRole.systemStop.action, AlarmButtonRole.confirm.action)
        XCTAssertEqual(AlarmButtonRole.confirm.action, .confirm)
        XCTAssertEqual(AlarmButtonRole.snooze.action, .snooze)
    }

    func testClosingSoundPersistsWithoutAcknowledgingTask() {
        state.markAlarmDismissed("original", at: base)
        let relaunched = AcknowledgementStore(defaults: defaults)
        XCTAssertFalse(relaunched.contains("original"))
        XCTAssertEqual(relaunched.alarmDismissedAt("original"), base)
        XCTAssertNil(relaunched.snoozedUntil("original"))
    }

    func testStopSoundKeepsTwoMinuteNotificationsAndNextStrongAlarm() throws {
        let reminder = PersonalReminder(title: "Call", dueDate: base)
        let series = reminder.seriesID(for: base)
        let stopped = base.addingTimeInterval(10)
        state.markAlarmDismissed(series, at: stopped)
        var settings = Settings()
        settings.nagIntervalMinutes = 2
        let planner = ReminderPlanner(isCompleted: { self.state.contains($0) },
                                      snoozedUntil: { self.state.snoozedUntil($0) })
        let notifications = planner.plan(shifts: [], reminders: [reminder], settings: settings, now: stopped)
        XCTAssertEqual(notifications.first?.fireDate, base.addingTimeInterval(120))
        let alarms = ReminderPresentationPolicy.alarmOccurrences(notifications, now: stopped,
            dismissedAt: { self.state.alarmDismissedAt($0) }, persistentFollowUps: true)
        XCTAssertEqual(alarms.first?.fireDate, base.addingTimeInterval(120))
        XCTAssertFalse(state.contains(series))
        state.markCompleted(series)
        let afterConfirmation = planner.plan(shifts: [], reminders: [reminder], settings: settings, now: stopped)
        XCTAssertTrue(afterConfirmation.isEmpty)
        XCTAssertNil(state.alarmDismissedAt(series))
    }

    func testRepeatedCloseDoesNotDriftFromSelectedInterval() {
        let events = (1...10).map { event($0) }
        for (seconds, expected) in [(10, 120), (130, 240), (250, 360)] {
            let stopped = base.addingTimeInterval(Double(seconds))
            let next = ReminderPresentationPolicy.alarmOccurrences(events, now: stopped,
                dismissedAt: { _ in stopped }, persistentFollowUps: true)
            XCTAssertEqual(next.first?.fireDate, base.addingTimeInterval(Double(expected)))
            XCTAssertEqual(next.first?.dueDate, base)
            XCTAssertEqual(next.first?.seriesID, "original")
        }
    }

    func testTwoMinuteNativeRepeatsDoNotExpandWithSparseSafetyTail() {
        let stopped = base.addingTimeInterval(31 * 60 + 15)
        let tail = [event(16, minutes: 40), event(17, minutes: 60)]
        let next = ReminderPresentationPolicy.alarmOccurrences(tail, now: stopped,
            dismissedAt: { _ in stopped }, persistentFollowUps: true)
        XCTAssertEqual(next.first?.fireDate, base.addingTimeInterval(32 * 60))
    }

    func testTurningNaggingOffDoesNotRearmStrongAlarm() {
        let stopped = base.addingTimeInterval(10)
        let next = ReminderPresentationPolicy.alarmOccurrences([event(1, interval: 0)], now: stopped,
            dismissedAt: { _ in stopped }, persistentFollowUps: true)
        XCTAssertTrue(next.isEmpty)
    }

    func testFiniteFollowUpsStopAfterTheirConfiguredCount() {
        let events = (1...3).map { event($0) }
        let stopped = base.addingTimeInterval(370)
        XCTAssertTrue(ReminderPresentationPolicy.alarmOccurrences(events, now: stopped,
            dismissedAt: { _ in stopped }, persistentFollowUps: false).isEmpty)
    }

    func testFiniteFollowUpsChooseNearestFutureAlertEvenIfInputIsUnsorted() {
        let stopped = base.addingTimeInterval(10)
        let next = ReminderPresentationPolicy.alarmOccurrences([event(3), event(1), event(2)], now: stopped,
            dismissedAt: { _ in stopped }, persistentFollowUps: false)
        XCTAssertEqual(next.first?.fireDate, base.addingTimeInterval(120))
    }

    func testSnoozeClearsDismissalAndDoesNotConfirmTask() {
        state.markAlarmDismissed("original", at: base)
        let until = base.addingTimeInterval(600)
        state.snooze("original", until: until)
        XCTAssertNil(state.alarmDismissedAt("original"))
        XCTAssertEqual(state.snoozedUntil("original"), until)
        XCTAssertFalse(state.contains("original"))
    }

    func testLateCloseCallbackCannotUndoExplicitConfirmation() {
        state.markCompleted("original")
        state.markAlarmDismissed("original", at: base)
        XCTAssertTrue(state.contains("original"))
        XCTAssertNil(state.alarmDismissedAt("original"))
    }

    func testDismissalBeforeNewDeadlineDoesNotCountAsClosingNewAlarm() {
        let now = base.addingTimeInterval(10)
        let next = ReminderPresentationPolicy.alarmOccurrences([event(1)], now: now,
            dismissedAt: { _ in self.base.addingTimeInterval(-60) }, persistentFollowUps: true)
        XCTAssertTrue(next.isEmpty)
    }

    func testAlignmentPreservesQueueCapacityAndShowsActualStrongRepeat() throws {
        let tail = [event(16, minutes: 40), event(17, minutes: 60)]
        let fire = base.addingTimeInterval(32 * 60)
        let aligned = ReminderPresentationPolicy.alignNotifications(tail, alarms: ["original": fire], now: base)
        XCTAssertEqual(aligned.count, tail.count)
        XCTAssertEqual(aligned.first?.fireDate, fire)
        XCTAssertEqual(aligned.first?.seriesID, "original")
        XCTAssertEqual(aligned.first?.dueDate, base)
        XCTAssertEqual(Set(aligned.map(\.nagIndex)).count, aligned.count)
        XCTAssertTrue(aligned.allSatisfy { $0.nagIndex > 0 })
    }

    func testAlignmentDoesNotChangeUnrelatedTasks() {
        let other = Occurrence(kind: .personal, title: "Other", body: "", followUpBody: "",
            fireDate: base.addingTimeInterval(180), dueDate: base.addingTimeInterval(180),
            seriesID: "other", nagIndex: 0, eventTitle: "Other", isImportant: false, repeatIntervalMinutes: 2)
        let aligned = ReminderPresentationPolicy.alignNotifications([event(16, minutes: 40), other],
            alarms: ["original": base.addingTimeInterval(120)], now: base)
        XCTAssertEqual(aligned.first(where: { $0.seriesID == "other" })?.fireDate, other.fireDate)
        XCTAssertEqual(aligned.count, 2)
    }

    func testLegacyAlarmRegistryCanDecodeAndIsReplacedWithoutLosingIdentity() throws {
        let old = #"{"seriesID":"original","kind":"personal","title":"Call","dueDate":123}"#
        let legacy = try JSONDecoder().decode(ManagedAlarmRecord.self, from: Data(old.utf8))
        XCTAssertEqual(legacy.scheduledDate, legacy.dueDate)
        XCTAssertNil(legacy.configurationVersion)
        let updated = ManagedAlarmRecord(seriesID: legacy.seriesID, kind: legacy.kind, title: legacy.title,
            dueDate: legacy.dueDate, fireDate: legacy.dueDate, configurationVersion: 2)
        XCTAssertEqual(legacy.id, updated.id)
        XCTAssertNotEqual(legacy, updated)
    }

    func testAlreadyRingingAlarmCannotReplaceFutureNotificationWithAPastDate() {
        let future = [event(1), event(2)]
        let result = ReminderPresentationPolicy.alignNotifications(future, alarms: ["original": base],
            now: base.addingTimeInterval(10))
        XCTAssertEqual(result.map(\.fireDate), future.map(\.fireDate))
        XCTAssertTrue(result.allSatisfy { $0.fireDate > base })
    }
}
