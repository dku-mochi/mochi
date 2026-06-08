import XCTest
@testable import CoreDomain

final class LifecyclePolicyTests: XCTestCase {
    func test_schedule_can_archive_with_scheduleEnded() {
        let result = LifecyclePolicy.validate(from: .active, to: .archived(reason: .scheduleEnded), intent: .schedule)
        assertValid(result)
    }

    func test_schedule_archive_with_wrong_reason_is_rejected() {
        let result = LifecyclePolicy.validate(from: .active, to: .archived(reason: .todoCompleted), intent: .schedule)
        if case .failure(.invalidArchiveReason(reason: .todoCompleted, intent: .schedule)) = result {
            return
        }
        XCTFail("schedule must reject archive reason .todoCompleted")
    }

    func test_memo_only_allows_userManual_archive() {
        assertValid(LifecyclePolicy.validate(from: .active, to: .archived(reason: .userManual), intent: .memo))
        if case .failure = LifecyclePolicy.validate(from: .active, to: .archived(reason: .knowledgeStale), intent: .memo) {
            return
        }
        XCTFail("memo must reject archive reason .knowledgeStale")
    }

    func test_knowledge_can_decay_then_review_then_revive_or_archive() {
        assertValid(LifecyclePolicy.validate(from: .active, to: .decaying, intent: .knowledge))
        assertValid(LifecyclePolicy.validate(from: .decaying, to: .reviewRequested, intent: .knowledge))
        assertValid(LifecyclePolicy.validate(from: .reviewRequested, to: .active, intent: .knowledge))
        assertValid(LifecyclePolicy.validate(from: .reviewRequested, to: .archived(reason: .knowledgeStale), intent: .knowledge))
    }

    func test_memo_cannot_enter_review_requested() {
        let result = LifecyclePolicy.validate(from: .active, to: .reviewRequested, intent: .memo)
        if case .failure = result {} else { XCTFail("memo must not enter reviewRequested") }
    }

    func test_todo_can_uncomplete_archived_to_active() {
        // 완료 취소 — 사용자가 todo 체크를 해제해 미완료로 되돌림(역전이). 잘못 누른 완료를 영구화하지 않는다.
        assertValid(LifecyclePolicy.validate(from: .archived(reason: .todoCompleted), to: .active, intent: .todo))
    }

    func test_non_todo_cannot_uncomplete_archived_to_active() {
        // 역전이는 todo 한정 — schedule 의 완료(archive)는 되돌릴 수 없다.
        let result = LifecyclePolicy.validate(from: .archived(reason: .scheduleEnded), to: .active, intent: .schedule)
        if case .failure = result {} else { XCTFail("schedule must not allow archived→active") }
    }

    // MARK: - Helper

    /// `LifecyclePolicy.validate` 는 `Result<Void, LifecycleTransitionError>` 를 반환하는데
    /// `Void` 가 `Equatable` 이 아니라 `XCTAssertEqual(_, .success(()))` 로는 검증할 수 없다.
    /// success 여부는 case 매칭으로 단언한다.
    private func assertValid(
        _ result: Result<Void, LifecycleTransitionError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case let .failure(error) = result {
            XCTFail("expected .success but got .failure(\(error))", file: file, line: line)
        }
    }
}
