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
/// `confidence`는 0.0–1.0 범위, 사용자 메모 동반 시 백엔드에서 상향 보정.
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

    // MARK: - 불확실성 판정 ("모찌가 헷갈려요")

    /// confidence 가 이 값 미만이면 헷갈리는 것으로 본다.
    public static let uncertainConfidenceThreshold: Double = 0.6
    /// top-2 의견의 applicability 차가 이 값 미만이면 (= 박빙) 헷갈리는 것으로 본다.
    public static let uncertainGapThreshold: Double = 0.15

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

    /// 1·2위 의견의 applicability 차. 서로 다른 의견이 2개 미만이면 `1.0` (박빙 아님).
    public var topGap: Double {
        let ops = distinctOpinions
        guard ops.count >= 2 else { return 1.0 }
        return ops[0].applicability - ops[1].applicability
    }

    /// 모찌가 확신하지 못하는가 — confidence 가 낮거나 top-2 가 박빙.
    public var isUncertain: Bool {
        confidence < Self.uncertainConfidenceThreshold || topGap < Self.uncertainGapThreshold
    }

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
