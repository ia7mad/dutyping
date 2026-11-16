import UserNotifications
import XCTest
@testable import DutyPing

final class NotificationRequestTests: XCTestCase {
    @MainActor
    func testNotificationTriggerPreservesSecondsAndOriginalDeadline() async throws {
        let calendar = Calendar.current
        let due = calendar.date(from: DateComponents(year: 2030, month: 1, day: 7, hour: 8, minute: 1, second: 45))!
        let followUp = due.addingTimeInterval(300)
        let occurrence = Occurrence(kind: .personal, title: "Call", body: "Original",
                                    followUpBody: "Still waiting", fireDate: followUp,
                                    dueDate: due, seriesID: "original", nagIndex: 1,
                                    eventTitle: "Call", isImportant: true, repeatIntervalMinutes: 5)
        let request = Scheduler.shared.makeRequest(for: occurrence)
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(trigger.dateComponents.second, 45)
        XCTAssertEqual(trigger.dateComponents.minute, 6)
        XCTAssertFalse(trigger.repeats)
        XCTAssertEqual(request.identifier, "original#1")
        XCTAssertEqual(request.content.userInfo["series"] as? String, "original")
        XCTAssertEqual(request.content.userInfo["dueDate"] as? TimeInterval, due.timeIntervalSince1970)
        XCTAssertEqual(request.content.body, "Still waiting")
        XCTAssertEqual(request.content.interruptionLevel, .timeSensitive)
    }
}
