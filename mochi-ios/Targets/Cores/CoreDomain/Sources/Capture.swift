import Foundation

/// 모찌의 1급 도메인 객체.
///
/// **Capture identity 규약**: `Capture.id == CaptureSource.id`.
/// 단일 캡처는 단일 UUID 만으로 식별되며, 이 ID가 그대로
/// (a) Realm primary key, (b) 서버 측 capture id, (c) 멱등키 derivation 의 base 가 된다.
public struct Capture: Equatable, Sendable, Identifiable, Hashable {
    public var id: UUID { source.id }
    public let source: CaptureSource
    public var analysis: CaptureAnalysis?
    public var lifecycleState: LifecycleState
    public var syncState: SyncState
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        source: CaptureSource,
        analysis: CaptureAnalysis? = nil,
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
