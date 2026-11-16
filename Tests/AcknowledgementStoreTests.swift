import XCTest
@testable import DutyPing

final class AcknowledgementStoreTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "DutyPingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testSnoozeSurvivesRelaunchAndCompletionClearsIt() {
        let until = Date(timeIntervalSince1970: 2_000_000_000)
        let first = AcknowledgementStore(defaults: defaults)
        first.snooze("original-series", until: until)
        let relaunched = AcknowledgementStore(defaults: defaults)
        XCTAssertEqual(relaunched.snoozedUntil("original-series"), until)
        relaunched.markCompleted("original-series")
        XCTAssertTrue(first.contains("original-series"))
        XCTAssertNil(first.snoozedUntil("original-series"))
    }

    func testReopeningOnlyClearsSelectedOccurrence() {
        let store = AcknowledgementStore(defaults: defaults)
        store.markCompleted("today")
        store.markCompleted("yesterday")
        store.reopen("today")
        XCTAssertFalse(store.contains("today"))
        XCTAssertTrue(store.contains("yesterday"))
    }

    func testOldCompletionCannotBeResurrectedByCompletingAnotherTask() {
        defaults.set(["old": Date().addingTimeInterval(-200 * 86400).timeIntervalSince1970],
                     forKey: "completedReminderSeries")
        let store = AcknowledgementStore(defaults: defaults)
        store.markCompleted("new")
        XCTAssertTrue(store.contains("old"))
    }
}
