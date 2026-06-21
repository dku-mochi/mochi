import CoreDomain
import Foundation

/// 감지 신호 집합 → 민감도 평가 결과.
public struct SensitivityAssessment: Equatable, Sendable {
    /// 0-10 (cap).
    public let score: Int
    public let level: SensitivityLevel
    public let signals: [SensitivitySignal]
    /// 등급 기반 기본 추천 정책(`PRIVACY_SENSITIVE_CAPTURE.md §5.2`).
    public let recommendedPolicy: PrivacyPolicy

    /// 검증기를 통과한 고신뢰 신호가 하나라도 있는지 — 저장 흐름에 시트를 띄울지의 기준.
    public var hasHighPrecisionSignal: Bool { signals.contains(where: \.isHighPrecision) }

    /// 사용자에게 선택 시트를 띄워야 하는가. false positive 의 UX 마찰을 막기 위해
    /// **고신뢰 신호가 있을 때만** true — 흔한 문맥/전화/이메일 단독으로는 막지 않는다.
    public var shouldPromptUser: Bool { hasHighPrecisionSignal }
}

/// 신호 점수 합산 + 조합 가중 + 등급화. 순수 함수(테스트 대상).
public struct SensitivityScorer {
    public init() {}

    public func assess(_ signals: [SensitivitySignal]) -> SensitivityAssessment {
        let base = signals.reduce(0) { $0 + $1.score }
        let raw = base + Self.comboBonus(signals)
        let score = min(10, max(0, raw))
        let level = Self.level(for: score)
        return SensitivityAssessment(
            score: score,
            level: level,
            signals: signals,
            recommendedPolicy: Self.recommendedPolicy(for: level)
        )
    }

    /// 조합 가중치(`§4.3`) — 단일 신호보다 조합이 위험. 이름(NER) 제외분은 식별자 조합으로 대체.
    static func comboBonus(_ signals: [SensitivitySignal]) -> Int {
        let types = Set(signals.map(\.type))
        var bonus = 0
        // 은행 계좌 + 금융 문맥(금액·송금 등)
        if types.contains(.bankAccount), types.contains(.finance) { bonus += 3 }
        // 의료 문맥 + 개인 식별자
        if types.contains(.medical), types.contains(.nationalID) || types.contains(.phoneNumber) { bonus += 2 }
        // 서로 다른 고신뢰 식별자가 둘 이상 동시 등장
        let highPrecisionTypes = Set(signals.filter(\.isHighPrecision).map(\.type))
        if highPrecisionTypes.count >= 2 { bonus += 2 }
        return bonus
    }

    static func level(for score: Int) -> SensitivityLevel {
        switch score {
        case ...2: return .low
        case 3...5: return .caution
        case 6...8: return .sensitive
        default: return .highlySensitive
        }
    }

    /// 등급별 기본 추천 정책 — 사용자가 시트에서 바꿀 수 있다(강제 아님).
    static func recommendedPolicy(for level: SensitivityLevel) -> PrivacyPolicy {
        switch level {
        case .low, .caution: return .originalUpload
        case .sensitive: return .blurredUpload
        case .highlySensitive: return .localOnly
        }
    }
}
