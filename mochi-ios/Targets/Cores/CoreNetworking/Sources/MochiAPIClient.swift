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

    /// `GET /api/v1/mochi_items` — owner-scoped 전체 목록. 앱 재설치 후 서버→로컬 복구(pull)에 사용한다.
    /// 날짜 필터 없이 호출하면 owner 의 모든 항목을 capturedAt 내림차순으로 돌려준다(서버 상한 200).
    func listMochiItems(limit: Int) async throws -> [MochiItemDTO]

    /// `POST /api/v1/mochi_items/images/download-url` — `objectKey` → GCS Signed GET URL.
    /// 재설치 후 로컬 이미지 파일이 사라진 복구 항목의 원본을 내려받기 위해 발급한다(owner-scoped).
    func presignCaptureDownload(objectKey: String) async throws -> URL

    /// `POST /api/v1/search` — 자연어 질의 → Hybrid Search RAG.
    func search(query: String, scope: SearchScope) async throws -> SearchResponse

    /// `GET /api/v1/mochi_items/{id}/similar` — 상세 "비슷한 기록"(cosine 이웃 top-k).
    /// 자기 제외·임계값 미달 빈 배열·출처 dedup 은 서버가 처리한다. 빈 배열이면 뷰가 섹션을 숨긴다.
    /// `serverID` 는 업로드된 서버 id 여야 한다(미업로드 로컬 항목엔 호출하지 않는다).
    func similarItems(serverID: UUID, limit: Int) async throws -> [SimilarItemRef]

    /// `POST /api/v1/devices/push-token` — APNs 단말/Live Activity push-to-start 토큰 등록 (owner-scoped upsert).
    /// `apnsDevice`·`laStart` 모두 owner 단위라 `mochiItemID` 없이 등록한다.
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

    /// `PATCH /api/v1/mochi_items/{id}` — 콘텐츠(text/userMemo/summary) + instance 변경
    /// (payload 병합·label·lifecycle 전이)을 **한 트랜잭션**으로. 채팅 수정 proposal 확정 경로.
    /// 404(`*.not_found`) = 카드 만료, 409 = 불법 lifecycle 전이.
    /// 반환 = 갱신된 항목(서버 정본) — 호출자가 로컬 Realm 미러에 merge 한다
    /// (pullRemote 는 "없는 항목 채우기" 전용이라 기존 항목 수정을 반영하지 못한다).
    @discardableResult
    func updateMochiItem(mochiServerID: UUID, _ request: MochiItemUpdateRequestDTO) async throws -> MochiItemDTO

    /// `GET /api/v1/mochi_items/upcoming` — "이번주 정리"의 "아직 안 끝났어요".
    /// 미해결 todo + 다가올 schedule 을 서버가 마감일 파싱·임박순 정렬해 돌려준다(캘린더 탭과 별개).
    func upcomingActionables() async throws -> [UpcomingActionableDTO]

    /// `POST /api/v1/mochi_items/weekly_digest` — 이번주 정리. 그 주(KST 월~일) 항목의 카테고리를
    /// 서버가 정규화(write)하고 "모찌의 한마디"를 생성한다. `weekStart` 가 어긋나도 서버가 재정규화한다.
    func weeklyDigest(weekStart: Date) async throws -> WeeklyDigestDTO
}

/// push 토큰 종류. rawValue 는 백엔드 `device_push_tokens.token_type` 과 1:1.
public enum PushTokenKind: String, Sendable, Codable {
    case apnsDevice = "apns_device"
    /// Live Activity push-to-start 토큰 (owner 단위, item 무관). iOS 17.2+. needs_review=true 분석완료
    /// 시 백엔드가 이 토큰으로 LA 를 background(잠금)에서 시작한다. 구 per-item `live_activity` 폐기.
    case laStart = "la_start"
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
    /// 사용자 확정 instance — 존재 시 서버가 **분석을 생략**하고 instance 를 그대로 생성한다
    /// (DOMAIN_DESIGN §5.2 예외: 사용자 확정 = 분석보다 상위 신뢰). 채팅 일정 proposal 확정 경로.
    public let confirmedInstances: [ConfirmedInstanceIngestDTO]?

    public init(
        channel: IngestChannel,
        url: URL? = nil,
        text: String? = nil,
        userMemo: String? = nil,
        imageRefs: [ImageRefDTO] = [],
        confirmedInstances: [ConfirmedInstanceIngestDTO]? = nil
    ) {
        self.channel = channel
        self.url = url
        self.text = text
        self.userMemo = userMemo
        self.imageRefs = imageRefs
        self.confirmedInstances = confirmedInstances
    }

    private enum CodingKeys: String, CodingKey {
        case channel, url, text
        case userMemo = "userMemo"
        case imageRefs = "imageRefs"
        case confirmedInstances = "confirmedInstances"
    }
}

/// `confirmedInstances` 1건 — intentType rawValue 와 payload 키는 백엔드 스키마와 1:1.
public struct ConfirmedInstanceIngestDTO: Sendable, Hashable, Codable {
    public let intentType: String
    /// 부분 payload (title/date/time/end_date/end_time/deadline/person/topic/url/note 중 채워진 것만).
    public let payload: [String: String]
    public let label: String?

    public init(intentType: String, payload: [String: String], label: String? = nil) {
        self.intentType = intentType
        self.payload = payload
        self.label = label
    }
}

/// `PATCH /mochi_items/{id}` 요청 — nil 필드는 미변경(merge 시맨틱).
public struct MochiItemUpdateRequestDTO: Sendable, Hashable, Codable {
    public let text: String?
    public let userMemo: String?
    public let summary: String?
    public let instances: [InstanceChangeRequestDTO]

    public init(
        text: String? = nil, userMemo: String? = nil,
        summary: String? = nil, instances: [InstanceChangeRequestDTO] = []
    ) {
        self.text = text
        self.userMemo = userMemo
        self.summary = summary
        self.instances = instances
    }
}

public struct InstanceChangeRequestDTO: Sendable, Hashable, Codable {
    public let instanceID: UUID
    /// 부분 payload 병합 필드 — 키는 IntentPayloadPatchDTO (title/date/time/...).
    public let payload: [String: String]
    public let label: String?
    public let lifecycleKind: String?
    public let archiveReason: String?

    public init(
        instanceID: UUID, payload: [String: String] = [:],
        label: String? = nil, lifecycleKind: String? = nil, archiveReason: String? = nil
    ) {
        self.instanceID = instanceID
        self.payload = payload
        self.label = label
        self.lifecycleKind = lifecycleKind
        self.archiveReason = archiveReason
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
    public let category: String?
    /// 쇼핑 캡처의 커머스 검색어 — entities(kind=shopping_product) 서버 projection. 비쇼핑은 nil.
    public let shoppingProductQuery: String?
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
        case id, channel, url, text, summary, category, importance
        case userMemo = "userMemo"
        case shoppingProductQuery = "shoppingProductQuery"
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
        category: String?,
        shoppingProductQuery: String? = nil,
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
        self.category = category
        self.shoppingProductQuery = shoppingProductQuery
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
        category = try c.decodeIfPresent(String.self, forKey: .category)
        shoppingProductQuery = try c.decodeIfPresent(String.self, forKey: .shoppingProductQuery)
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
    /// 기간형 일정의 끝 — date/time 은 시작 의미(없으면 점 일정).
    public let endDate: String?
    public let endTime: String?
    public let deadline: String?
    public let person: String?
    public let topic: String?
    public let url: String?
    public let note: String?

    public init(
        title: String? = nil,
        date: String? = nil,
        time: String? = nil,
        endDate: String? = nil,
        endTime: String? = nil,
        deadline: String? = nil,
        person: String? = nil,
        topic: String? = nil,
        url: String? = nil,
        note: String? = nil
    ) {
        self.title = title
        self.date = date
        self.time = time
        self.endDate = endDate
        self.endTime = endTime
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

// MARK: - 비슷한 기록 (similar)

/// 상세 "비슷한 기록" 1건 — 서버가 계산한 cosine 이웃 ref. 카드 렌더는 로컬 MochiItem lookup.
public struct SimilarItemRef: Equatable, Sendable, Hashable, Codable, Identifiable {
    public let mochiItemID: UUID
    public let score: Double
    public let reasons: [SimilarReason]
    public var id: UUID { mochiItemID }

    public init(mochiItemID: UUID, score: Double, reasons: [SimilarReason]) {
        self.mochiItemID = mochiItemID
        self.score = score
        self.reasons = reasons
    }
}

/// "왜 비슷한지" 연결 이유 — 서버 enum. 한국어 카피는 뷰가 매핑한다(카피 변경이 ⓪ 폭포를 안 타도록).
public struct SimilarReason: Equatable, Sendable, Hashable, Codable {
    public let kind: Kind
    /// 보조값 — sameIntent 의 교집합 intent_type, sharedSource 의 url 등 (없으면 nil).
    public let value: String?

    public enum Kind: String, Sendable, Codable {
        case sharedSource   // 같은 출처
        case sameIntent     // 같은 의도
        case closeInTime    // 비슷한 시기
    }

    public init(kind: Kind, value: String?) {
        self.kind = kind
        self.value = value
    }
}

// MARK: - 이번주 정리 DTOs

/// "아직 안 끝났어요" 1건 — 미해결 todo 또는 다가올 schedule.
public struct UpcomingActionableDTO: Sendable, Hashable, Codable {
    public let item: MochiItemDTO
    /// 서버가 마감/일시 free-text 를 파싱한 값(미상이면 nil).
    public let dueAt: Date?
    /// 파싱 전 원문(클라 표시·디버깅용).
    public let dueLabel: String?
    /// false=todo(카드에서 1-tap 완료, ``instanceID`` 가 전이 대상), true=schedule(표시·상세만).
    public let isSchedule: Bool
    public let instanceID: UUID

    public init(item: MochiItemDTO, dueAt: Date?, dueLabel: String?, isSchedule: Bool, instanceID: UUID) {
        self.item = item
        self.dueAt = dueAt
        self.dueLabel = dueLabel
        self.isSchedule = isSchedule
        self.instanceID = instanceID
    }
}

/// 이번주 정리 — 모찌 한마디 + 정규화된 카테고리 묶음.
public struct WeeklyDigestDTO: Sendable, Hashable, Codable {
    public let greeting: String
    public let groups: [Group]
    /// false 면 그 주 항목이 적어 LLM 미호출한 정적 폴백(클라가 캐시 정책에 활용).
    public let generated: Bool

    public struct Group: Sendable, Hashable, Codable {
        public let coarse: String
        public let itemIDs: [UUID]

        public init(coarse: String, itemIDs: [UUID]) {
            self.coarse = coarse
            self.itemIDs = itemIDs
        }
    }

    public init(greeting: String, groups: [Group], generated: Bool) {
        self.greeting = greeting
        self.groups = groups
        self.generated = generated
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
