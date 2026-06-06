import Foundation

/// 모찌의 1급 도메인 객체.
///
/// **MochiItem identity 규약**: `MochiItem.id == IngestSource.id` — 로컬 식별자.
/// 이 ID가 (a) Realm primary key, (c) 멱등키(Idempotency-Key) 로 쓰인다.
/// 단, (b) **서버 측 mochiItem id 는 다르다**: 백엔드 ingest 가 자체 uuid4 를 PK 로 부여하고
/// (클라 UUID 는 멱등키로만 전달), iOS 는 업로드 응답의 서버 id 를 `SyncState.uploaded(serverID:)`
/// 에 보관한다. 서버 조회(`getMochiItem`)는 이 serverID 로 한다 — 로컬 id 로 GET 하면 404.
public struct MochiItem: Equatable, Sendable, Identifiable, Hashable {
    public var id: UUID { source.id }
    public let source: IngestSource
    public var analysis: MochiItemAnalysis?
    public var lifecycleState: ProcessingState
    public var syncState: SyncState
    /// 사용자가 직접 교정한 제목 (로컬 오버라이드). nil 이면 AI 추출 제목(대표 payload.title)을 쓴다.
    /// 분석 재동기화로 instances 가 delete-reinsert 돼도 보존된다 — payload.title 과 분리한 이유.
    public var userTitle: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        source: IngestSource,
        analysis: MochiItemAnalysis? = nil,
        lifecycleState: ProcessingState = .ingested,
        syncState: SyncState = .pendingUpload,
        userTitle: String? = nil,
        createdAt: Date = .init(),
        updatedAt: Date = .init()
    ) {
        self.source = source
        self.analysis = analysis
        self.lifecycleState = lifecycleState
        self.syncState = syncState
        self.userTitle = userTitle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 추출된 의도 instance 들 (분석 전이면 빈 배열).
    public var instances: [IntentInstance] { analysis?.instances ?? [] }
    /// distinct intent type (출현 순서). 1:N 필터·요약 칩.
    public var intentTypes: [Intent] { analysis?.intentTypes ?? [] }
    /// 대표 intent — 고정 우선순위 schedule>todo>knowledge>memo (캘린더 대표색·칩).
    public var representativeIntent: Intent? { analysis?.representativeIntent }
    /// 모찌가 분류를 확신 못 함 — "헷갈려요" 버킷.
    public var needsReview: Bool { analysis?.needsReview ?? false }

    /// AI 가 추출한 대표 제목 — 대표 의도 instance 의 payload.title. 비면 nil.
    public var representativeTitle: String? {
        guard let rep = representativeIntent,
              let inst = instances.first(where: { $0.intentType == rep }),
              let title = inst.payload.title, !title.isEmpty else { return nil }
        return title
    }

    /// 기록상세 헤더에 보일 제목 — 사용자 교정(``userTitle``) 우선, 없으면 AI 추출 제목.
    /// 둘 다 없으면 nil → 화면은 placeholder 를 보여준다(요약문을 제목으로 폴백하지 않는다).
    public var displayHeadline: String? {
        if let userTitle, !userTitle.isEmpty { return userTitle }
        return representativeTitle
    }
}

/// 백엔드 / 시스템 캘린더와의 동기화 상태.
public enum SyncState: Equatable, Sendable, Hashable, Codable {
    case pendingUpload
    case uploading
    case uploaded(serverID: UUID, at: Date)
    case calendarSynced(eventIdentifier: String)
    case reminderSynced(reminderIdentifier: String)
    case syncFailed(reason: String, retryAfter: Date?)
}
