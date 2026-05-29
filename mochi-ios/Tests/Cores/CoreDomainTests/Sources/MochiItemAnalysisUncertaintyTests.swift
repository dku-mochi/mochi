import XCTest
@testable import CoreDomain

/// 홈 "모찌가 헷갈려요" 판정(`isUncertain`/`topGap`)과 의견 도출(`reviewOpinions`) 검증.
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

    // MARK: - topGap

    func test_topGap_is_one_when_fewer_than_two_distinct_intents() {
        XCTAssertEqual(analysis(confidence: 0.9, []).topGap, 1.0)
        XCTAssertEqual(analysis(confidence: 0.9, [candidate(.memo, 0.8)]).topGap, 1.0)
    }

    func test_topGap_is_difference_of_top_two_distinct() {
        let a = analysis(confidence: 0.9, [candidate(.memo, 0.4), candidate(.todo, 0.9), candidate(.knowledge, 0.7)])
        XCTAssertEqual(a.topGap, 0.9 - 0.7, accuracy: 1e-9)
    }

    func test_topGap_dedupes_same_intent_taking_max() {
        // todo 가 두 번 → 0.9 채택. distinct = [todo 0.9, memo 0.6] → gap 0.3
        let a = analysis(confidence: 0.9, [candidate(.todo, 0.9), candidate(.todo, 0.5), candidate(.memo, 0.6)])
        XCTAssertEqual(a.topGap, 0.9 - 0.6, accuracy: 1e-9)
    }

    // MARK: - isUncertain

    func test_low_confidence_is_uncertain_even_with_wide_gap() {
        // confidence 0.59 < 0.6 → 박빙 아니어도 헷갈림.
        let a = analysis(confidence: 0.59, [candidate(.memo, 0.95), candidate(.todo, 0.1)])
        XCTAssertTrue(a.isUncertain)
    }

    func test_confidence_at_threshold_with_wide_gap_is_certain() {
        // confidence 0.60 (not < 0.6) + 넓은 gap(0.85) → 확신.
        let a = analysis(confidence: 0.60, [candidate(.memo, 0.95), candidate(.todo, 0.1)])
        XCTAssertFalse(a.isUncertain)
    }

    func test_close_top_two_is_uncertain_even_with_high_confidence() {
        // gap 0.14 (< 0.15) → 박빙 헷갈림.
        let a = analysis(confidence: 0.95, [candidate(.memo, 0.80), candidate(.todo, 0.66)])
        XCTAssertTrue(a.isUncertain)
    }

    func test_wide_gap_and_high_confidence_is_certain() {
        // gap 0.16 (>= 0.15) + confidence 0.95 → 확신.
        let a = analysis(confidence: 0.95, [candidate(.memo, 0.80), candidate(.todo, 0.64)])
        XCTAssertFalse(a.isUncertain)
    }

    func test_single_confident_candidate_is_certain() {
        let a = analysis(confidence: 0.9, [candidate(.memo, 0.9)])
        XCTAssertFalse(a.isUncertain)
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
