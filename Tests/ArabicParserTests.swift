import XCTest
@testable import DutyPing

final class ArabicParserTests: XCTestCase {
    func testGrocerySentenceCreatesScheduledShoppingList() {
        let result = LocalReminderParser.organize(
            "ذكرني بأغراض البقاله, رز, بصل, ثوم, عصير, الساعه 4:10 م",
            shifts: [])

        XCTAssertEqual(result.cleanTitle, "أغراض البقالة")
        XCTAssertEqual(result.category, .errands)
        XCTAssertEqual(result.contentType, .shopping)
        XCTAssertEqual(result.checklist ?? [], ["رز", "بصل", "ثوم", "عصير"])
        XCTAssertTrue(result.hasSchedule)
        XCTAssertEqual(Calendar.current.component(.hour, from: result.dueDate), 16)
        XCTAssertEqual(Calendar.current.component(.minute, from: result.dueDate), 10)
        XCTAssertGreaterThan(result.dueDate, Date())
    }

    func testArabicDigitsAndAttachedConjunctions() {
        let result = LocalReminderParser.organize(
            "جيب حليب وخبز وبطاريات الساعة ٦:٣٥ م",
            shifts: [])

        XCTAssertEqual(result.checklist ?? [], ["حليب", "خبز", "بطاريات"])
        XCTAssertTrue(result.hasSchedule)
        XCTAssertEqual(Calendar.current.component(.hour, from: result.dueDate), 18)
        XCTAssertEqual(Calendar.current.component(.minute, from: result.dueDate), 35)
    }
}
