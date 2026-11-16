import XCTest
@testable import DutyPing

@available(iOS 16.2, *)
final class LiveActivityTests: XCTestCase {
    func testOpeningActivityIsDifferentFromConfirmingIt() throws {
        let attributes = ReminderActivityAttributes(seriesID: "series-1", title: "Call & buy milk", kind: "personal")
        XCTAssertEqual(attributes.openURL.host, "open")
        XCTAssertEqual(attributes.completionURL.host, "complete")
        XCTAssertNotEqual(attributes.openURL, attributes.completionURL)
        XCTAssertEqual(attributes.snoozeURL.host, "snooze")
        XCTAssertNotEqual(attributes.snoozeURL, attributes.completionURL)
        let query = try XCTUnwrap(URLComponents(url: attributes.completionURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(query.queryItems?.first { $0.name == "title" }?.value, attributes.title)
        XCTAssertEqual(query.queryItems?.first { $0.name == "series" }?.value, attributes.seriesID)
    }

    func testExistingActivityStateDecodesAfterUpgrade() throws {
        let original = #"{"dueDate":123,"isCompleted":false,"repeatIntervalMinutes":5}"#
        let state = try JSONDecoder().decode(ReminderActivityAttributes.ContentState.self,
                                             from: Data(original.utf8))
        XCTAssertEqual(state.repeatIntervalMinutes, 5)
        XCTAssertNil(state.startedAt)
    }
}
