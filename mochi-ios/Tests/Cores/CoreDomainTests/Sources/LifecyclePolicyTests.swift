import XCTest
@testable import CoreDomain

final class LifecyclePolicyTests: XCTestCase {
    func test_schedule_can_archive_with_scheduleEnded() {
        let result = LifecyclePolicy.validate(from: .active, to: .archived(reason: .scheduleEnded), intent: .schedule)
        XCTAssertEqual(result, .success(()))
    }

    func test_schedule_archive_with_wrong_reason_is_rejected() {
        let result = LifecyclePolicy.validate(from: .active, to: .archived(reason: .todoCompleted), intent: .schedule)
        if case .failure(.invalidArchiveReason(reason: .todoCompleted, intent: .schedule)) = result {
            return
        }
        XCTFail("schedule must reject archive reason .todoCompleted")
    }

    func test_memo_only_allows_userManual_archive() {
        XCTAssertEqual(
            LifecyclePolicy.validate(from: .active, to: .archived(reason: .userManual), intent: .memo),
            .success(())
        )
        if case .failure = LifecyclePolicy.validate(from: .active, to: .archived(reason: .knowledgeStale), intent: .memo) {
            return
        }
        XCTFail("memo must reject archive reason .knowledgeStale")
    }

    func test_knowledge_can_decay_then_review_then_revive_or_archive() {
        XCTAssertEqual(LifecyclePolicy.validate(from: .active, to: .decaying, intent: .knowledge), .success(()))
        XCTAssertEqual(LifecyclePolicy.validate(from: .decaying, to: .reviewRequested, intent: .knowledge), .success(()))
        XCTAssertEqual(LifecyclePolicy.validate(from: .reviewRequested, to: .active, intent: .knowledge), .success(()))
        XCTAssertEqual(
            LifecyclePolicy.validate(from: .reviewRequested, to: .archived(reason: .knowledgeStale), intent: .knowledge),
            .success(())
        )
    }

    func test_memo_cannot_enter_review_requested() {
        let result = LifecyclePolicy.validate(from: .active, to: .reviewRequested, intent: .memo)
        if case .failure = result {} else { XCTFail("memo must not enter reviewRequested") }
    }
}
