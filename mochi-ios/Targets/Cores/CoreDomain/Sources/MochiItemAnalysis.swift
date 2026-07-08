import Foundation

/// Gemini 멀티모달 분석 결과.
///
/// 2026-06-04 빅뱅: 단수 `intent`·`confidence`·점수 후보(`candidates`)를 폐기하고, 복수 `instances`
/// (저장되면 곧 active)와 `needsReview` boolean·`reviewOptions`(미확정 후보)로 재배선했다.
public struct MochiItemAnalysis: Equatable, Sendable, Hashable, Codable {
    public let summary: String
    public let category: String?
    /// 쇼핑 캡처의 커머스 검색어 (브랜드+상품명+옵션) — 상세의 "검색된 상태" 구매 링크가 쓴다.
    /// 서버 분석이 entities(kind=shopping_product) 로 산출, 비쇼핑/모호 캡처는 nil.
    public let shoppingProductQuery: String?
    /// Agent 가 찾아준 참고 링크 (아이템당 최대 3개, relevance judge 통과분). 상세의 URL 카드가 쓴다.
    /// 서버 entities(kind=reference_url) projection, 없으면 빈 배열.
    public let referenceLinks: [ReferenceLink]
    /// 기록이 가리킨 장소 (WGS84 좌표 포함) — 상세의 지도 섹션이 쓴다.
    /// 서버 entities(kind=place) projection, 장소성 없는 기록은 nil.
    public let place: Place?
    /// 복수 의도 instance (저장된 것은 곧 active). 비어 있을 수 있다(분석 실패/폴백).
    public let instances: [IntentInstance]
    /// 모찌가 분류를 확신 못 해 사용자에게 물을지 — 서버 boolean 직접 미러 (LLM holistic, threshold 아님).
    public let needsReview: Bool
    /// `needsReview` 시 제시할 미확정 후보 (점수·정렬 없음, API projection).
    public let reviewOptions: [ReviewOption]
    public let entities: [ExtractedEntity]
    public let actionCandidates: [ActionCandidate]
    public let tags: [String]
    public let importance: Importance
    public let modelVersion: String
    public let analyzedAt: Date

    public init(
        summary: String,
        category: String? = nil,
        shoppingProductQuery: String? = nil,
        referenceLinks: [ReferenceLink] = [],
        place: Place? = nil,
        instances: [IntentInstance],
        needsReview: Bool = false,
        reviewOptions: [ReviewOption] = [],
        entities: [ExtractedEntity],
        actionCandidates: [ActionCandidate],
        tags: [String],
        importance: Importance,
        modelVersion: String,
        analyzedAt: Date
    ) {
        self.summary = summary
        self.category = category
        self.shoppingProductQuery = shoppingProductQuery
        self.referenceLinks = referenceLinks
        self.place = place
        self.instances = instances
        self.needsReview = needsReview
        self.reviewOptions = reviewOptions
        self.entities = entities
        self.actionCandidates = actionCandidates
        self.tags = tags
        self.importance = importance
        self.modelVersion = modelVersion
        self.analyzedAt = analyzedAt
    }

    // MARK: - 파생

    /// 분석이 실패/지연돼 클라이언트가 강등시킨 항목의 `modelVersion` 마커.
    /// (멱등 replay 로 instance 만 빈 정상 항목과 구분하기 위한 명시 신호.)
    public static let failedModelVersion = "analysis-failed"

    /// 클라이언트가 분석 실패로 강등한 항목인가 — 카드의 "잘 모르겠어요" + 재시도 분기에 쓰인다.
    public var isAnalysisFailed: Bool { modelVersion == Self.failedModelVersion }

    /// instances 의 distinct intent type (출현 순서 보존). 1:N 필터·요약 칩에 쓴다.
    public var intentTypes: [Intent] {
        var seen: Set<Intent> = []
        var result: [Intent] = []
        for inst in instances where !seen.contains(inst.intentType) {
            seen.insert(inst.intentType)
            result.append(inst.intentType)
        }
        return result
    }

    /// 대표 intent — **고정 우선순위** `schedule > todo > knowledge > memo` 중 존재하는 최상위.
    /// 캘린더 칸 대표색·요약 칩에 쓴다 (점수 argmax 아님, 의미 우선순위).
    public var representativeIntent: Intent? {
        let priority: [Intent] = [.schedule, .todo, .knowledge, .memo]
        let present = Set(instances.map(\.intentType))
        return priority.first { present.contains($0) }
    }

    /// `category` 만 교체한 복사본 (주간 정리 정규화 결과를 로컬에 반영할 때 사용).
    public func withCategory(_ newCategory: String?) -> MochiItemAnalysis {
        MochiItemAnalysis(
            summary: summary,
            category: newCategory,
            shoppingProductQuery: shoppingProductQuery,
            referenceLinks: referenceLinks,
            place: place,
            instances: instances,
            needsReview: needsReview,
            reviewOptions: reviewOptions,
            entities: entities,
            actionCandidates: actionCandidates,
            tags: tags,
            importance: importance,
            modelVersion: modelVersion,
            analyzedAt: analyzedAt
        )
    }

    /// `instances` 만 교체한 복사본 (instance lifecycle 전이 등에 사용).
    public func replacingInstances(_ newInstances: [IntentInstance]) -> MochiItemAnalysis {
        MochiItemAnalysis(
            summary: summary,
            category: category,
            shoppingProductQuery: shoppingProductQuery,
            referenceLinks: referenceLinks,
            place: place,
            instances: newInstances,
            needsReview: needsReview,
            reviewOptions: reviewOptions,
            entities: entities,
            actionCandidates: actionCandidates,
            tags: tags,
            importance: importance,
            modelVersion: modelVersion,
            analyzedAt: analyzedAt
        )
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
