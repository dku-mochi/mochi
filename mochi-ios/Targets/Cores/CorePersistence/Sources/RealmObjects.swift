import Foundation
import RealmSwift

/// Realm 1급 객체. 도메인 객체 ``MochiItem`` 와 동치이지만 Realm 직렬화에 맞춰 평탄화.
///
/// Mapper(`RealmMochiItemMapper`)가 양방향 변환을 책임진다.
public final class RealmMochiItem: Object, Identifiable {
    @Persisted(primaryKey: true) public var id: String
    @Persisted public var channelRawValue: String
    @Persisted public var urlString: String?
    @Persisted public var text: String?
    @Persisted public var userMemo: String?
    /// 처리상태 (`ingested|analyzing|analyzed|failed`). intent instance 의미상태와 직교.
    @Persisted public var lifecycleStateRawValue: String
    @Persisted public var syncStateRawValue: String
    /// 사용자가 직접 교정한 제목 (로컬 오버라이드). nil 이면 AI 추출 제목 사용.
    @Persisted public var userTitle: String?
    /// 사용자가 준 "중요" 즐겨찾기 신호 — 서버 동기화 상태(서버 정본 미러, userTitle 의 로컬전용과 반대).
    @Persisted public var isFavorite: Bool = false
    @Persisted public var summary: String?
    @Persisted public var category: String?
    /// 쇼핑 캡처의 커머스 검색어 — 상세 구매 링크용 (서버 분석 미러).
    @Persisted public var shoppingProductQuery: String?
    /// Agent 가 찾아준 참고 링크 — 상세 URL 카드용 (서버 분석 미러, 아이템당 최대 3개).
    @Persisted public var referenceLinks: List<RealmReferenceLink>
    @Persisted public var importance: Int = 3
    /// 모찌가 분류를 확신 못 함 — "헷갈려요" 버킷 (서버 boolean 미러).
    @Persisted public var needsReview: Bool = false
    @Persisted public var modelVersion: String?
    /// 저장 시점 민감 캡처 정책(`originalUpload|blurredUpload|localOnly`). nil = 미감지/비민감.
    /// 업로드 워커가 이 값으로 원본/블러본/스킵을 고른다. iOS 내부 전용(서버 미전송).
    @Persisted public var privacyPolicyRawValue: String?
    /// 감지된 민감도 등급(`low|caution|sensitive|highlySensitive`). nil = 미감지. 경고 UI·디버깅용.
    @Persisted public var sensitivityLevelRawValue: String?
    @Persisted public var capturedAt: Date
    @Persisted public var analyzedAt: Date?
    @Persisted public var createdAt: Date
    @Persisted public var updatedAt: Date

    /// 저장된 의도 instance (저장된 것은 곧 active, 위계 없음). 미분석 시 비어 있다.
    @Persisted public var intentInstances: List<RealmIntentInstance>
    /// `needsReview` 시 제시할 미확정 후보 (점수 없음). 현재 빈 배열일 수 있다.
    @Persisted public var reviewOptions: List<RealmReviewOption>

    @Persisted public var imageRefs: List<RealmImageRef>
    @Persisted public var entities: List<RealmExtractedEntity>
    @Persisted public var tags: List<String>
    @Persisted public var actionCandidates: List<RealmActionCandidate>

    public override class func primaryKey() -> String? { "id" }
}

public final class RealmIntentInstance: EmbeddedObject {
    @Persisted public var instanceID: String
    @Persisted public var intentRawValue: String
    @Persisted public var label: String?
    @Persisted public var reasoning: String?
    /// 의미상태 kind (`active|decaying|reviewRequested|archived`).
    @Persisted public var lifecycleKindRawValue: String
    /// archived 일 때 reason (`scheduleEnded|todoCompleted|knowledgeStale|userManual`), 아니면 nil.
    @Persisted public var archiveReasonRawValue: String?
    // payload (typed, 전부 optional)
    @Persisted public var payloadTitle: String?
    @Persisted public var payloadDate: String?
    @Persisted public var payloadTime: String?
    /// 기간형 일정의 끝 — date/time 은 시작 의미(없으면 점 일정).
    @Persisted public var payloadEndDate: String?
    @Persisted public var payloadEndTime: String?
    @Persisted public var payloadDeadline: String?
    @Persisted public var payloadPerson: String?
    @Persisted public var payloadTopic: String?
    @Persisted public var payloadURL: String?
    @Persisted public var payloadNote: String?
}

public final class RealmReferenceLink: EmbeddedObject {
    @Persisted public var urlString: String
    @Persisted public var title: String
    @Persisted public var label: String
    @Persisted public var role: String
    @Persisted public var provider: String
    @Persisted public var rankProfile: String
    @Persisted public var source: String?
    @Persisted public var usefulness: Int?
    @Persisted public var subtitle: String?
    @Persisted public var priceText: String?
}

public final class RealmReviewOption: EmbeddedObject {
    @Persisted public var intentRawValue: String
    @Persisted public var label: String?
    @Persisted public var reasoning: String?
}

public final class RealmImageRef: EmbeddedObject {
    @Persisted public var id: String
    @Persisted public var relativePath: String
    @Persisted public var mimeType: String
    @Persisted public var byteSize: Int
    @Persisted public var sha256: String
    @Persisted public var objectKey: String?
    /// 민감 영역 블러 파생본의 App Group 상대 경로(`blurredUpload` 시 생성). nil = 블러본 없음.
    @Persisted public var redactedRelativePath: String?
}

public final class RealmExtractedEntity: EmbeddedObject {
    @Persisted public var kindRawValue: String
    @Persisted public var value: String
    /// "textRange" | "ocrBox" | "" (empty when no provenance)
    @Persisted public var provenanceKind: String = ""
    @Persisted public var textRangeStart: Int?
    @Persisted public var textRangeEnd: Int?
    @Persisted public var ocrX: Double?
    @Persisted public var ocrY: Double?
    @Persisted public var ocrWidth: Double?
    @Persisted public var ocrHeight: Double?
}

public final class RealmActionCandidate: EmbeddedObject {
    /// "calendar" | "reminder" | "openURL" | "followUp"
    @Persisted public var kind: String
    @Persisted public var title: String?
    @Persisted public var startISO8601: String?
    @Persisted public var endISO8601: String?
    @Persisted public var urlString: String?
    @Persisted public var query: String?
}
