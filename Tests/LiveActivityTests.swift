import XCTest
@testable import DutyPing

final class LiveActivityTests: XCTestCase {
    func testOpeningActivityIsDifferentFromConfirmingIt() throws {
        let attributes = ReminderActivityAttributes(seriesID: "series-1", title: "Call & buy milk", kind: "personal")
        XCTAssertEqual(attributes.openURL.host, "open")
        XCTAssertEqual(attributes.completionURL.host, "complete")
        XCTAssertNotEqual(attributes.openURL, attributes.completionURL)
        let query = try XCTUnwrap(URLComponents(url: attributes.completionURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(query.queryItems?.first { $0.name == "title" }?.value, attributes.title)
        XCTAssertEqual(query.queryItems?.first { $0.name == "series" }?.value, attributes.seriesID)
    }
}
