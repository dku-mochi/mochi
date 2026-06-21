import CoreDomain
import XCTest
@testable import CorePrivacy

final class SensitivityScorerTests: XCTestCase {
    private let scorer = SensitivityScorer()

    func test_levelMapping() {
        XCTAssertEqual(SensitivityScorer.level(for: 0), .low)
        XCTAssertEqual(SensitivityScorer.level(for: 2), .low)
        XCTAssertEqual(SensitivityScorer.level(for: 3), .caution)
        XCTAssertEqual(SensitivityScorer.level(for: 5), .caution)
        XCTAssertEqual(SensitivityScorer.level(for: 6), .sensitive)
        XCTAssertEqual(SensitivityScorer.level(for: 8), .sensitive)
        XCTAssertEqual(SensitivityScorer.level(for: 9), .highlySensitive)
        XCTAssertEqual(SensitivityScorer.level(for: 10), .highlySensitive)
    }

    func test_capAt10() {
        let signals = [
            sig(.nationalID, 5, true),
            sig(.cardNumber, 5, true),
            sig(.passwordOrToken, 5, true),
        ]
        XCTAssertEqual(scorer.assess(signals).score, 10)
    }

    func test_shouldPromptOnlyWithHighPrecision() {
        let lowOnly = [sig(.phoneNumber, 2, false), sig(.email, 2, false)]
        XCTAssertFalse(scorer.assess(lowOnly).shouldPromptUser)

        let withHigh = [sig(.cardNumber, 5, true)]
        XCTAssertTrue(scorer.assess(withHigh).shouldPromptUser)
    }

    func test_comboBonus_bankPlusFinance() {
        let s = [sig(.bankAccount, 3, true), sig(.finance, 3, false)]
        XCTAssertEqual(SensitivityScorer.comboBonus(s), 3)
    }

    func test_comboBonus_multipleHighPrecision() {
        let s = [sig(.cardNumber, 5, true), sig(.nationalID, 5, true)]
        XCTAssertEqual(SensitivityScorer.comboBonus(s), 2)
    }

    func test_emptySignals_low() {
        let result = scorer.assess([])
        XCTAssertEqual(result.score, 0)
        XCTAssertEqual(result.level, .low)
        XCTAssertFalse(result.shouldPromptUser)
    }

    func test_recommendedPolicy() {
        XCTAssertEqual(SensitivityScorer.recommendedPolicy(for: .low), .originalUpload)
        XCTAssertEqual(SensitivityScorer.recommendedPolicy(for: .caution), .originalUpload)
        XCTAssertEqual(SensitivityScorer.recommendedPolicy(for: .sensitive), .blurredUpload)
        XCTAssertEqual(SensitivityScorer.recommendedPolicy(for: .highlySensitive), .localOnly)
    }

    private func sig(_ type: SensitivityType, _ score: Int, _ high: Bool) -> SensitivitySignal {
        SensitivitySignal(type: type, score: score, textRange: nil, isHighPrecision: high)
    }
}
