import XCTest
@testable import CoreDomain

/// 홈 "모찌가 헷갈려요" 판정(`isUncertain`) · 복수 의도(`isMultiIntent`/`activeSecondaryIntents`)
/// · 의견 도출(`reviewOpinions`) 검증.
///
/// 핵심 모델: confidence(= 최상위 후보 applicability) 단일 기준으로 3상태가 갈린다 —
/// 헷갈림(top1<0.6) / 단일 확신(top1≥0.6, top2<0.6) / 복수 의도(top1·top2 둘 다 ≥0.6).
/// 박빙(gap) 조건은 폐기됐다.
final class MochiItemAnalysisUncertaintyTests: XCTestCase {

    private func candidate(_ intent: Intent, _ applicability: Double, label: String? = nil) -> IntentCandidate {
        IntentCandidate(label: label, intent: intent, applicability: applicability)
    }

    private func analysis(confidence: Double, _ candidates: [IntentCandidate]) -> MochiItemAnalysis {
        MochiItemAnalysis(
            summary: "s",
            intent: candidates.first?.intent ?? .memo,
            entities: [],
            actionCandidates: [],
            tags: [],
            importance: .medium,
            confidence: confidence,
            modelVersion: "test",
            analyzedAt: .init(),
            candidates: candidates
        )
    }

    // MARK: - isUncertain (confidence 단일 기준)

    func test_low_confidence_is_uncertain() {
        // 최상위 후보(0.59) < 0.6 → 헷갈림.
        let a = analysis(confidence: 0.59, [candidate(.memo, 0.59), candidate(.todo, 0.1)])
        XCTAssertTrue(a.isUncertain)
    }

    func test_confidence_at_threshold_is_certain() {
        // 0.60 (not < 0.6) → 확신.
        let a = analysis(confidence: 0.60, [candidate(.memo, 0.60), candidate(.todo, 0.1)])
        XCTAssertFalse(a.isUncertain)
    }

    func test_weak_top_two_is_uncertain_regardless_of_gap() {
        // 둘 다 낮고 박빙 — 최상위(0.5) < 0.6 이라 헷갈림 (gap 과 무관).
        let a = analysis(confidence: 0.5, [candidate(.memo, 0.5), candidate(.todo, 0.45)])
        XCTAssertTrue(a.isUncertain)
        XCTAssertFalse(a.isMultiIntent)
    }

    func test_single_confident_candidate_is_certain() {
        let a = analysis(confidence: 0.9, [candidate(.memo, 0.9)])
        XCTAssertFalse(a.isUncertain)
        XCTAssertFalse(a.isMultiIntent)
    }

    // MARK: - isMultiIntent (둘 다 강함 = 복수 의도, 헷갈림 아님)

    func test_two_strong_candidates_is_multi_intent_not_uncertain() {
        // top1=0.9, top2=0.8 — 둘 다 ≥0.6 → 복수 의도. "헷갈려요" 아님.
        let a = analysis(confidence: 0.9, [candidate(.todo, 0.9), candidate(.knowledge, 0.8)])
        XCTAssertFalse(a.isUncertain)
        XCTAssertTrue(a.isMultiIntent)
        XCTAssertEqual(a.activeSecondaryIntents, [.knowledge])
    }

    func test_strong_primary_weak_secondary_is_single_intent() {
        // top1=0.9, top2=0.3 — secondary < 0.6 → 단일 확신.
        let a = analysis(confidence: 0.9, [candidate(.todo, 0.9), candidate(.knowledge, 0.3)])
        XCTAssertFalse(a.isUncertain)
        XCTAssertFalse(a.isMultiIntent)
        XCTAssertEqual(a.activeSecondaryIntents, [])
    }

    func test_uncertain_item_has_no_active_secondary() {
        // 헷갈리면 복수 의도 판정을 하지 않는다.
        let a = analysis(confidence: 0.4, [candidate(.todo, 0.4), candidate(.knowledge, 0.35)])
        XCTAssertTrue(a.isUncertain)
        XCTAssertEqual(a.activeSecondaryIntents, [])
    }

    func test_active_secondary_takes_max_per_distinct_intent() {
        // 같은 intent 중복 → 최댓값. todo 0.9 / todo 0.7(무시) / knowledge 0.65 → secondary [knowledge].
        let a = analysis(confidence: 0.9, [candidate(.todo, 0.9), candidate(.todo, 0.7), candidate(.knowledge, 0.65)])
        XCTAssertEqual(a.activeSecondaryIntents, [.knowledge])
    }

    // MARK: - reviewOpinions

    func test_reviewOpinions_returns_top_two_distinct_descending() {
        let a = analysis(confidence: 0.4, [candidate(.memo, 0.4), candidate(.todo, 0.9), candidate(.knowledge, 0.7)])
        let ops = a.reviewOpinions
        XCTAssertEqual(ops.count, 2)
        XCTAssertEqual(ops[0].intent, .todo)
        XCTAssertEqual(ops[1].intent, .knowledge)
    }

    func test_reviewOpinions_dedupes_intent() {
        let a = analysis(confidence: 0.4, [candidate(.todo, 0.9), candidate(.todo, 0.5), candidate(.memo, 0.6)])
        let ops = a.reviewOpinions
        XCTAssertEqual(ops.map(\.intent), [.todo, .memo])
    }

    func test_reviewOpinions_preserves_label() {
        let a = analysis(confidence: 0.4, [candidate(.todo, 0.9, label: "회신"), candidate(.memo, 0.6)])
        XCTAssertEqual(a.reviewOpinions.first?.label, "회신")
    }
}
