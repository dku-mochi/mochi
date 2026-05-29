import Foundation

/// LLM 이 한 캡처에 대해 내놓은 단일 의도 후보.
///
/// - `label`: 사용자가 보게 될 한국어 시나리오 라벨 (예: "구매 고민", "회신"). back-tap 분류
///   응답에만 존재하며, metadata-only(공유/메모/URL) 경로엔 없어 `nil` 이다 — 이 경우 UI 는
///   `intent.displayName` 으로 폴백한다.
/// - `applicability`: 0.0–1.0. "이 의도가 이 기록에 얼마나 잘 들어맞는가" 의 독립 강도
///   (백엔드 `IntentClassification.applicability` 와 동치). 후보 간 합이 1.0 일 필요 없다.
public struct IntentCandidate: Equatable, Sendable, Hashable, Codable {
    public let label: String?
    public let intent: Intent
    public let applicability: Double

    public init(label: String?, intent: Intent, applicability: Double) {
        self.label = label
        self.intent = intent
        self.applicability = applicability
    }
}

/// Gemini 멀티모달 분석 결과.
///
/// `confidence`는 0.0–1.0 범위 — 최상위 use case 후보의 applicability(백엔드 derive).
public struct MochiItemAnalysis: Equatable, Sendable, Hashable, Codable {
    public let summary: String
    public let intent: Intent
    public let entities: [ExtractedEntity]
    public let actionCandidates: [ActionCandidate]
    public let tags: [String]
    public let importance: Importance
    public let confidence: Double
    public let modelVersion: String
    public let analyzedAt: Date
    /// LLM 이 제시한 의도 후보들 (applicability 순 정렬 보장 없음). 비어 있을 수 있다.
    public let candidates: [IntentCandidate]

    public init(
        summary: String,
        intent: Intent,
        entities: [ExtractedEntity],
        actionCandidates: [ActionCandidate],
        tags: [String],
        importance: Importance,
        confidence: Double,
        modelVersion: String,
        analyzedAt: Date,
        candidates: [IntentCandidate] = []
    ) {
        self.summary = summary
        self.intent = intent
        self.entities = entities
        self.actionCandidates = actionCandidates
        self.tags = tags
        self.importance = importance
        self.confidence = confidence
        self.modelVersion = modelVersion
        self.analyzedAt = analyzedAt
        self.candidates = candidates
    }

    // MARK: - 불확실성 / 복수 의도 판정

    /// confidence(= 최상위 후보 applicability, 백엔드 derive)가 이 값 미만이면 "헷갈려요" —
    /// 가장 잘 맞는 후보조차 약해 모찌가 확신 못 함.
    public static let uncertainConfidenceThreshold: Double = 0.6

    /// 분석이 실패/지연돼 클라이언트가 강등시킨 항목의 `modelVersion` 마커.
    /// (멱등 replay 로 candidates 만 빈 정상 항목과 구분하기 위한 명시 신호.)
    public static let failedModelVersion = "analysis-failed"

    /// 클라이언트가 분석 실패로 강등한 항목인가 — 카드의 "잘 모르겠어요" + 재시도 분기에 쓰인다.
    public var isAnalysisFailed: Bool { modelVersion == Self.failedModelVersion }

    /// applicability 내림차순으로 intent 중복을 제거한 의견 리스트 (각 intent 최댓값 채택).
    private var distinctOpinions: [IntentCandidate] {
        var byIntent: [Intent: IntentCandidate] = [:]
        for c in candidates {
            if let existing = byIntent[c.intent], existing.applicability >= c.applicability { continue }
            byIntent[c.intent] = c
        }
        return byIntent.values.sorted { $0.applicability > $1.applicability }
    }

    /// 모찌가 확신하지 못하는가 — 최상위 후보조차 확신 임계 미만.
    ///
    /// 박빙(top-2 gap) 조건은 폐기됐다: top1·top2 가 둘 다 높은 건 "헷갈림"이 아니라 "복수 의도"다
    /// (`activeSecondaryIntents`). 둘 다 낮고 박빙인 경우는 이미 `confidence < 임계` 로 잡힌다.
    public var isUncertain: Bool {
        confidence < Self.uncertainConfidenceThreshold
    }

    /// 확신 임계를 넘는 보조 의도들 — primary 외에 "둘 다 강한" 복수 의도. 추천·알림·채팅에서 활용한다.
    /// (사용자 UI 엔 primary 만 노출.)
    public var activeSecondaryIntents: [Intent] {
        guard !isUncertain else { return [] }
        return distinctOpinions
            .dropFirst()
            .filter { $0.applicability >= Self.uncertainConfidenceThreshold }
            .map(\.intent)
    }

    /// 복수 의도 — 확신하면서 보조 의도도 확신 임계 이상.
    public var isMultiIntent: Bool { !activeSecondaryIntents.isEmpty }

    /// "모찌가 헷갈려요" 카드에 노출할 의견 — 서로 다른 intent 상위 2개.
    /// (직접 지정 버튼은 화면이 항상 함께 그린다.)
    public var reviewOpinions: [IntentCandidate] {
        Array(distinctOpinions.prefix(2))
    }

    public enum Importance: Int, Codable, Sendable, CaseIterable, Comparable {
        case low = 1
        case mediumLow = 2
        case medium = 3
        case mediumHigh = 4
        case high = 5

        public static func < (lhs: Importance, rhs: Importance) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Agent가 제안한 후속 액션 — 사용자 확인 후 실제 수행.
    public enum ActionCandidate: Equatable, Sendable, Hashable, Codable {
        case createCalendarEvent(title: String, startISO8601: String, endISO8601: String?)
        case createReminder(title: String, dueISO8601: String?)
        case openURL(URL)
        case followUpSearch(query: String)
    }
}
