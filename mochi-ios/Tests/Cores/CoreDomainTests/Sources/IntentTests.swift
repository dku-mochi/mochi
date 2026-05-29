import XCTest
@testable import CoreDomain

final class IntentTests: XCTestCase {
    func test_allCases_count() {
        XCTAssertEqual(Intent.allCases.count, 4)
    }

    func test_displayNames_are_korean() {
        XCTAssertEqual(Intent.schedule.displayName, "일정")
        XCTAssertEqual(Intent.todo.displayName, "할일")
        XCTAssertEqual(Intent.knowledge.displayName, "지식")
        XCTAssertEqual(Intent.memo.displayName, "기록")
    }
}
