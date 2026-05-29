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
    public var lifecycleState: LifecycleState
    public var syncState: SyncState
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        source: IngestSource,
        analysis: MochiItemAnalysis? = nil,
        lifecycleState: LifecycleState = .ingested,
        syncState: SyncState = .pendingUpload,
        createdAt: Date = .init(),
        updatedAt: Date = .init()
    ) {
        self.source = source
        self.analysis = analysis
        self.lifecycleState = lifecycleState
        self.syncState = syncState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var intent: Intent? { analysis?.intent }
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
