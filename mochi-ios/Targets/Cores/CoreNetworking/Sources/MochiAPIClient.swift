import Foundation
import CoreDomain

/// 백엔드 `/api/v1` 와의 계약. 백엔드 `openapi.json` 과 1:1 매칭되어야 한다.
///
/// 실제 구현은 빌드 타임에 `swift-openapi-generator` 가 `openapi.json` 에서 생성하는
/// 클라이언트를 얇게 감싼다(`OpenAPIMochiClient`).
///
/// **계약 원칙:**
/// - 모든 요청은 `X-Mochi-Request-ID` 헤더로 분산 추적
/// - `POST /mochi_items` 는 `Idempotency-Key` 헤더 필수 (owner-scoped)
/// - 에러는 ``APIErrorEnvelope`` 통일 포맷
///
/// **백엔드에 없는 엔드포인트는 이 프로토콜에도 없다.** 분석은 ingest 후 백엔드 outbox/worker가 자동으로 트리거하고,
/// 캘린더 sync는 iOS가 EventKit 으로 처리한 뒤 추후 PATCH 로 결과만 백엔드에 반영한다(향후 추가 예정).
public protocol MochiAPIClient: Sendable {
    /// `POST /api/v1/mochi_items` — 사용자 캡처 ingestion. 응답은 분석 전 상태의 mochiItem (lifecycle=`ingested`).
    func ingestMochiItem(_ request: MochiItemIngestRequest, idempotencyKey: String) async throws -> MochiItemDTO

    /// `POST /api/v1/mochi_items/presign` — 캡처 이미지 업로드용 GCS Signed PUT URL 발급.
    func presignCaptureUpload(sha256: String, mimeType: String) async throws -> PresignUploadDTO

    /// GCS Signed URL 로 업로드용 이미지 bytes 를 직접 PUT.
    func putCaptureImage(uploadURL: URL, data: Data, mimeType: String) async throws

    /// `GET /api/v1/mochi_items/{id}` — owner-scoped mochiItem 조회.
    func getMochiItem(id: UUID) async throws -> MochiItemDTO

    /// `POST /api/v1/search` — 자연어 질의 → Hybrid Search RAG.
    func search(query: String, scope: SearchScope) async throws -> SearchResponse

    /// `POST /api/v1/devices/push-token` — APNs 단말/Live Activity push 토큰 등록 (owner-scoped upsert).
    /// `kind=.liveActivity` 면 `mochiItemID` 필수(백엔드가 item id 로 LA 토큰 조회).
    func registerPushToken(
        token: String,
        kind: PushTokenKind,
        environment: PushEnvironment,
        mochiItemID: UUID?
    ) async throws

    /// `POST /api/v1/mochi_items/{id}/reanalyze` — needs_review 항목 재분석.
    /// "다른 의도"에서 사용자가 적은 의도 힌트를 분석 context 에 합류시켜 백엔드 outbox→worker 를 다시 트리거한다.
    func reanalyzeMochiItem(id: UUID, userHint: String) async throws

    /// `POST /api/v1/mochi_items/{id}/instances/{instanceID}/lifecycle` — intent instance 의미상태 전이.
    /// 캘린더 todo 완료(`to=.archived(reason:.todoCompleted)`)/완료취소(`to=.active`). 갱신된 item 을 반환한다.
    /// 합법성은 서버 `lifecycle_policy` 가 instance 의 intent_type 으로 검증한다(불법이면 409 throw).
    /// `mochiServerID` 는 로컬 id 가 아니라 업로드된 서버 id(`syncState.uploaded`)여야 한다.
    func updateInstanceLifecycle(
        mochiServerID: UUID,
        instanceID: UUID,
        to newState: InstanceLifecycle
    ) async throws -> MochiItemDTO

    /// `DELETE /api/v1/mochi_items/{id}` — 기록 soft delete(서버는 행을 지우지 않고 `deleted_at` 마킹).
    /// `mochiServerID` 는 로컬 id 가 아니라 업로드된 서버 id(`syncState.uploaded`)여야 한다.
    /// 없는/이미 삭제된 항목은 404 throw.
    func deleteMochiItem(mochiServerID: UUID) async throws
}

/// push 토큰 종류. rawValue 는 백엔드 `device_push_tokens.token_type` 과 1:1.
public enum PushTokenKind: String, Sendable, Codable {
    case apnsDevice = "apns_device"
    case liveActivity = "live_activity"
}

/// APNs 환경. 토큰은 환경에 묶여 잘못 매칭 시 BadDeviceToken — 클라가 빌드 환경을 명시한다.
public enum PushEnvironment: String, Sendable, Codable {
    case sandbox
    case production
}

// MARK: - Request / Response DTOs

public struct MochiItemIngestRequest: Sendable, Hashable, Codable {
    public let channel: IngestChannel
    public let url: URL?
    public let text: String?
    public let userMemo: String?
    public let imageRefs: [ImageRefDTO]

    public init(
        channel: IngestChannel,
        url: URL? = nil,
        text: String? = nil,
        userMemo: String? = nil,
        imageRefs: [ImageRefDTO] = []
    ) {
        self.channel = channel
        self.url = url
        self.text = text
        self.userMemo = userMemo
        self.imageRefs = imageRefs
    }

    private enum CodingKeys: String, CodingKey {
        case channel, url, text
        case userMemo = "userMemo"
        case imageRefs = "imageRefs"
    }
}

public struct ImageRefDTO: Sendable, Hashable, Codable {
    public let objectKey: String?
    public let mimeType: String
    public let byteSize: Int
    public let sha256: String

    public init(objectKey: String?, mimeType: String, byteSize: Int, sha256: String) {
        self.objectKey = objectKey
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.sha256 = sha256
    }
}

public struct PresignUploadDTO: Sendable, Hashable, Codable {
    public let objectKey: String
    public let uploadURL: URL
    public let expiresAt: Date

    private enum CodingKeys: String, CodingKey {
        case objectKey = "objectKey"
        case uploadURL = "uploadURL"
        case expiresAt = "expiresAt"
    }
}

public struct MochiItemDTO: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let channel: IngestChannel
    public let url: URL?
    public let text: String?
    public let userMemo: String?
    public let summary: String?
    public let importance: Int
    /// 저장된 의도 instance (저장된 것은 곧 active, 위계 없음). 분석 전엔 빈 배열.
    public let intentInstances: [IntentInstanceDTO]
    /// 모찌가 분류를 확신 못 함 — "헷갈려요" 버킷.
    public let needsReview: Bool
    /// `needsReview` 시 제시할 미확정 후보 (점수 없음, projection). 현재 빈 배열일 수 있다.
    public let reviewOptions: [ReviewOptionDTO]
    /// item 처리상태 (`ingested|analyzing|analyzed|failed`).
    public let lifecycleKind: String
    public let syncKind: String
    public let imageRefs: [ImageRefDTO]
    public let capturedAt: Date
    public let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, channel, url, text, summary, importance
        case userMemo = "userMemo"
        case intentInstances = "intentInstances"
        case needsReview = "needsReview"
        case reviewOptions = "reviewOptions"
        case lifecycleKind = "lifecycleKind"
        case syncKind = "syncKind"
        case imageRefs = "imageRefs"
        case capturedAt = "capturedAt"
        case createdAt = "createdAt"
    }

    public init(
        id: UUID,
        channel: IngestChannel,
        url: URL?,
        text: String?,
        userMemo: String?,
        summary: String?,
        importance: Int,
        intentInstances: [IntentInstanceDTO],
        needsReview: Bool,
        reviewOptions: [ReviewOptionDTO],
        lifecycleKind: String,
        syncKind: String,
        imageRefs: [ImageRefDTO],
        capturedAt: Date,
        createdAt: Date
    ) {
        self.id = id
        self.channel = channel
        self.url = url
        self.text = text
        self.userMemo = userMemo
        self.summary = summary
        self.importance = importance
        self.intentInstances = intentInstances
        self.needsReview = needsReview
        self.reviewOptions = reviewOptions
        self.lifecycleKind = lifecycleKind
        self.syncKind = syncKind
        self.imageRefs = imageRefs
        self.capturedAt = capturedAt
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        channel = try c.decode(IngestChannel.self, forKey: .channel)
        url = try c.decodeIfPresent(URL.self, forKey: .url)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        userMemo = try c.decodeIfPresent(String.self, forKey: .userMemo)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        importance = try c.decode(Int.self, forKey: .importance)
        intentInstances = try c.decodeIfPresent([IntentInstanceDTO].self, forKey: .intentInstances) ?? []
        needsReview = try c.decodeIfPresent(Bool.self, forKey: .needsReview) ?? false
        reviewOptions = try c.decodeIfPresent([ReviewOptionDTO].self, forKey: .reviewOptions) ?? []
        lifecycleKind = try c.decode(String.self, forKey: .lifecycleKind)
        syncKind = try c.decode(String.self, forKey: .syncKind)
        imageRefs = try c.decodeIfPresent([ImageRefDTO].self, forKey: .imageRefs) ?? []
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

public struct IntentInstanceDTO: Sendable, Hashable, Codable {
    /// 서버 instance 식별자 — 완료/완료취소(lifecycle 전이) API 의 대상으로 보존한다.
    public let id: UUID
    public let intentType: Intent
    public let payload: IntentPayloadDTO?
    public let label: String?
    public let reasoning: String?
    /// instance 의미상태 (`active|decaying|reviewRequested|archived`).
    public let lifecycleKind: String
    /// archived 일 때의 사유 (`scheduleEnded|todoCompleted|knowledgeStale|userManual`). 그 외 nil.
    public let lifecycleArchiveReason: String?

    public init(
        id: UUID,
        intentType: Intent,
        payload: IntentPayloadDTO?,
        label: String?,
        reasoning: String?,
        lifecycleKind: String,
        lifecycleArchiveReason: String?
    ) {
        self.id = id
        self.intentType = intentType
        self.payload = payload
        self.label = label
        self.reasoning = reasoning
        self.lifecycleKind = lifecycleKind
        self.lifecycleArchiveReason = lifecycleArchiveReason
    }

    private enum CodingKeys: String, CodingKey {
        case id = "instanceId"
        case intentType, payload, label, reasoning, lifecycleKind, lifecycleArchiveReason
    }
}

public struct IntentPayloadDTO: Sendable, Hashable, Codable {
    public let title: String?
    public let date: String?
    public let time: String?
    public let deadline: String?
    public let person: String?
    public let topic: String?
    public let url: String?
    public let note: String?

    public init(
        title: String? = nil,
        date: String? = nil,
        time: String? = nil,
        deadline: String? = nil,
        person: String? = nil,
        topic: String? = nil,
        url: String? = nil,
        note: String? = nil
    ) {
        self.title = title
        self.date = date
        self.time = time
        self.deadline = deadline
        self.person = person
        self.topic = topic
        self.url = url
        self.note = note
    }
}

public struct ReviewOptionDTO: Sendable, Hashable, Codable {
    public let intentType: Intent
    public let label: String?
    public let reasoning: String?

    public init(intentType: Intent, label: String?, reasoning: String?) {
        self.intentType = intentType
        self.label = label
        self.reasoning = reasoning
    }
}

public enum SearchScope: String, Codable, Sendable, CaseIterable {
    case all
    case schedule
    case todo
    case knowledge
    case memo
}

public struct SearchResponse: Equatable, Sendable, Hashable, Codable {
    public let answer: String
    public let citations: [Citation]
    public let totalTokens: Int
    public let agentRunID: UUID?

    public struct Citation: Equatable, Sendable, Hashable, Codable {
        public let mochiItemID: UUID
        public let snippet: String
        public let score: Double

        private enum CodingKeys: String, CodingKey {
            case mochiItemID = "mochiItemId"
            case snippet, score
        }
    }

    private enum CodingKeys: String, CodingKey {
        case answer, citations
        case totalTokens = "totalTokens"
        case agentRunID = "agentRunId"
    }
}

// MARK: - Error envelope

/// 백엔드 에러 통일 포맷. 백엔드 `core/error_envelope.py` 와 동일 스키마.
public struct APIErrorEnvelope: Error, Equatable, Sendable, Codable {
    public let code: String                  // 예: "mochi_item.not_found", "agent.tool_failed"
    public let message: String
    public let requestID: String
    public let retryAfter: TimeInterval?

    public init(code: String, message: String, requestID: String, retryAfter: TimeInterval?) {
        self.code = code
        self.message = message
        self.requestID = requestID
        self.retryAfter = retryAfter
    }

    private enum CodingKeys: String, CodingKey {
        case code, message
        case requestID = "requestId"
        case retryAfter
    }
}
