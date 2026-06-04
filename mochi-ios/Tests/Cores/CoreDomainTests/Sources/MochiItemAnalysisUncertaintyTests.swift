import XCTest
@testable import CoreDomain

/// 빅뱅(2026-06-04) 후 `MochiItemAnalysis` 파생 검증.
///
/// 단수 intent·confidence·점수 후보(`candidates`)·박빙 판정을 폐기하고 복수 `instances`
/// (저장된 것은 곧 active) + `needsReview` boolean + `reviewOptions`(projection) 로 갔다.
/// 대표 intent 는 점수 argmax 가 아니라 고정 우선순위 `schedule > todo > knowledge > memo` 다.
final class MochiItemAnalysisUncertaintyTests: XCTestCase {

    private func instance(_ intent: Intent, label: String? = nil, lifecycle: InstanceLifecycle = .active) -> IntentInstance {
        IntentInstance(intentType: intent, label: label, lifecycle: lifecycle)
    }

    private func analysis(
        instances: [IntentInstance],
        needsReview: Bool = false,
        reviewOptions: [ReviewOption] = []
    ) -> MochiItemAnalysis {
        MochiItemAnalysis(
            summary: "s",
            instances: instances,
            needsReview: needsReview,
            reviewOptions: reviewOptions,
            entities: [],
            actionCandidates: [],
            tags: [],
            importance: .medium,
            modelVersion: "test",
            analyzedAt: .init()
        )
    }

    // MARK: - representativeIntent (고정 우선순위)

    func test_representative_picks_highest_priority_present() {
        // schedule 없음 → todo 가 최상위.
        let a = analysis(instances: [instance(.memo), instance(.todo), instance(.knowledge)])
        XCTAssertEqual(a.representativeIntent, .todo)
    }

    func test_representative_schedule_wins_over_others() {
        let a = analysis(instances: [instance(.memo), instance(.schedule), instance(.todo)])
        XCTAssertEqual(a.representativeIntent, .schedule)
    }

    func test_representative_nil_when_no_instances() {
        XCTAssertNil(analysis(instances: []).representativeIntent)
    }

    // MARK: - intentTypes (distinct, 출현 순서 보존)

    func test_intentTypes_distinct_preserving_order() {
        let a = analysis(instances: [instance(.todo), instance(.memo), instance(.todo)])
        XCTAssertEqual(a.intentTypes, [.todo, .memo])
    }

    // MARK: - needsReview / reviewOptions

    func test_needsReview_is_direct_boolean() {
        XCTAssertTrue(analysis(instances: [instance(.memo)], needsReview: true).needsReview)
        XCTAssertFalse(analysis(instances: [instance(.memo)]).needsReview)
    }

    func test_reviewOptions_preserve_intent_and_label() {
        let opt = ReviewOption(intentType: .todo, label: "회신", reasoning: nil)
        let a = analysis(instances: [instance(.memo)], needsReview: true, reviewOptions: [opt])
        XCTAssertEqual(a.reviewOptions.first?.intentType, .todo)
        XCTAssertEqual(a.reviewOptions.first?.label, "회신")
    }

    // MARK: - replacingInstances (instance lifecycle 전이용 — 다른 필드 보존)

    func test_replacingInstances_swaps_only_instances() {
        let a = analysis(instances: [instance(.todo)], needsReview: true)
        let archived = instance(.todo, lifecycle: .archived(reason: .todoCompleted))
        let b = a.replacingInstances([archived])
        XCTAssertEqual(b.instances.first?.lifecycle, .archived(reason: .todoCompleted))
        XCTAssertTrue(b.needsReview)   // 보존
        XCTAssertEqual(b.summary, "s") // 보존
    }

    // MARK: - displayLabel

    func test_instance_displayLabel_falls_back_to_intent_name() {
        XCTAssertEqual(instance(.schedule).displayLabel, Intent.schedule.displayName)
        XCTAssertEqual(instance(.todo, label: "회신").displayLabel, "회신")
    }
}
