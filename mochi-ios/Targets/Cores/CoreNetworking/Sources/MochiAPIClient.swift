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

    /// `POST /api/v1/mochi_items/{id}/favorite` — 즐겨찾기 신호 set-state 토글. 갱신된 item 을 반환한다.
    /// set-state 멱등(같은 값 재전송 no-op 200) — 빠른 더블탭·재시도가 낙관적 업데이트를 오롤백하지 않게.
    /// `mochiServerID` 는 로컬 id 가 아니라 업로드된 서버 id(`syncState.uploaded`)여야 한다. 없으면 404 throw.
    @discardableResult
    func setFavorite(mochiServerID: UUID, isFavorite: Bool) async throws -> MochiItemDTO

    /// `POST /api/v1/mochi_items/{id}/access` — 상세 열람 이벤트 기록(append-only, best-effort).
    /// `source` 는 상세를 연 직전 화면(navigation origin) — origin 이 의도를 인코딩한다
    /// (검색=의도적 회수, 채팅=모찌가 찾아줌). 능동 회수 랭킹의 "최근 클릭한 기록" 신호.
    /// fire-and-forget: 호출부가 `try?` 로 실패를 삼킨다(로깅이 UI 를 막지 않는다).
    /// `mochiServerID` 는 업로드된 서버 id 여야 한다(미업로드 로컬 항목엔 호출하지 않는다).
    func logItemAccess(mochiServerID: UUID, source: ItemAccessSource) async throws

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

    /// `POST /api/v1/mochi_items/monthly_digest` — 이번 달 정리. 그 달(KST 1일~말일) 항목의 카테고리를
    /// 서버가 정규화(write)하고 "모찌의 한마디"를 생성한다. `monthStart` 가 어긋나도 서버가 재정규화한다.
    func monthlyDigest(monthStart: Date) async throws -> MonthlyDigestDTO

    /// `GET /api/v1/recall/feed` — 능동 회수 피드(홈 한 칸·자세히 목록). owner 의 "다시 볼 지식".
    /// cold-start 빈손은 정상(`[]`). UI 필드(색/아이콘)는 iOS 가 `reason` → 매핑한다.
    func recallFeed(limit: Int) async throws -> [RecallFeedEntryDTO]

    /// `GET /api/v1/recall/events/{event_id}` — 알림 landing fallback. 로컬 역매핑 실패 시
    /// `recallEventID` 로 단건 회수 entry 를 서버에서 가져온다(빈 상세 금지). owner 스코프, 404 가능.
    func recallLanding(eventID: UUID) async throws -> RecallFeedEntryDTO

    /// `POST /api/v1/recall/events/{event_id}/reaction` — 알림/회수 반응 보고(204). 멱등.
    /// `opened`(양성·탭/열기) / `dismissed`(soft 부정) / `stop`("이 기억 그만" → plan cancel).
    func recordRecallReaction(eventID: UUID, reaction: RecallReaction) async throws

    /// `GET /api/v1/recall/upcoming?limit=` — 홈 "예정된 알림"(모찌가 보낼 예정인 미래 마감·일정 알림).
    /// owner 의 pending outbox 를 fire_at 오름차순으로 돌려준다. 빈손은 정상(`[]`).
    func upcomingNotifications(limit: Int) async throws -> [UpcomingNotificationDTO]

    /// `POST /api/v1/recall/upcoming/{event_id}/reschedule` — 예정 알림 시각 조정(프리셋·DatePicker 공용, 204).
    /// `fireAt` 은 미래여야 한다(과거면 서버가 422). 최초 1회 모찌 원안이 `originalFireAt` 으로 보존된다.
    func rescheduleUpcoming(eventID: UUID, fireAt: Date) async throws

    /// `POST /api/v1/recall/upcoming/{event_id}/veto` — 이 항목 알림 전체 끄기(204).
    /// 대상 pending skip + 그 plan 영구 cancel → 다음 단계 알림도 안 온다.
    func vetoUpcoming(eventID: UUID) async throws

    /// `GET /api/v1/recall/history?limit=` — 알림 페이지 "지난 알림"(모찌가 이미 보낸 알림).
    /// owner 의 sent outbox 를 sent_at 내림차순으로 돌려준다. 빈손은 정상(`[]`). 읽기 전용.
    func sentNotifications(limit: Int) async throws -> [SentNotificationDTO]
}

/// 알림 페이지 "지난 알림" 1건 — 백엔드 `SentNotificationEntry` 미러. 모찌가 이미 보낸 알림(읽기 전용).
/// `sentAt` 발송 시각, `openedAt` 열어본 시각(없으면 nil=안 열어봄), `dismissedAt` 무시한 시각.
/// 계약상 optional(`openedAt`/`dismissedAt`/`itemID`/`intentID`)은 nil 강등.
public struct SentNotificationDTO: Sendable, Hashable, Codable, Identifiable {
    /// 알림 event 키 (= outbox.event_id).
    public let eventID: UUID
    /// 받은 알림 종류 전부("deadline" | "nudge" | "recall" 등).
    public let kind: String
    /// 발송 시각.
    public let sentAt: Date
    /// 열어본 시각 — nil 이면 안 열어봄.
    public let openedAt: Date?
    /// swipe-away 로 무시한 시각 — nil 이면 미무시.
    public let dismissedAt: Date?
    public let title: String
    public let body: String
    /// 원본 mochiItem PK (없으면 nil).
    public let itemID: UUID?
    /// 원본 intent instance PK (없으면 nil).
    public let intentID: UUID?

    public var id: UUID { eventID }

    public init(
        eventID: UUID,
        kind: String,
        sentAt: Date,
        openedAt: Date? = nil,
        dismissedAt: Date? = nil,
        title: String,
        body: String,
        itemID: UUID? = nil,
        intentID: UUID? = nil
    ) {
        self.eventID = eventID
        self.kind = kind
        self.sentAt = sentAt
        self.openedAt = openedAt
        self.dismissedAt = dismissedAt
        self.title = title
        self.body = body
        self.itemID = itemID
        self.intentID = intentID
    }

    private enum CodingKeys: String, CodingKey {
        case eventID = "eventId"
        case kind, sentAt, openedAt, dismissedAt, title, body
        case itemID = "itemId"
        case intentID = "intentId"
    }
}

/// 홈 "예정된 알림" 1건 — 백엔드 `UpcomingNotificationEntry` 미러. 모찌가 보낼 예정인 미래 알림(마감/일정).
/// `eventID` 가 veto/reschedule 타겟 키(=outbox.event_id). `fireAt` 은 현재 유효 발송 예정 시각,
/// `originalFireAt` 은 사용자가 옮겼으면 모찌 원안(없으면 nil=미조정). 계약상 optional 은 nil 강등.
public struct UpcomingNotificationDTO: Sendable, Hashable, Codable, Identifiable {
    /// veto/reschedule 타겟 키 (= outbox.event_id).
    public let eventID: UUID
    /// "deadline"(마감 backoff) | "nudge"(다가올 일정) | "spaced"(예약 회수, "다시 보기").
    public let kind: String
    /// 현재 유효 발송 예정 시각(사용자가 옮겼으면 옮긴 값).
    public let fireAt: Date
    public let title: String
    public let body: String
    /// 사용자가 옮겼을 때의 모찌 원안 — "원래 X시 → 옮김" 보조 표기용. nil = 미조정.
    public let originalFireAt: Date?
    /// 원본 mochiItem PK (없으면 nil).
    public let itemID: UUID?
    /// 원본 intent instance PK (없으면 nil).
    public let intentID: UUID?

    public var id: UUID { eventID }

    public init(
        eventID: UUID,
        kind: String,
        fireAt: Date,
        title: String,
        body: String,
        originalFireAt: Date? = nil,
        itemID: UUID? = nil,
        intentID: UUID? = nil
    ) {
        self.eventID = eventID
        self.kind = kind
        self.fireAt = fireAt
        self.title = title
        self.body = body
        self.originalFireAt = originalFireAt
        self.itemID = itemID
        self.intentID = intentID
    }

    private enum CodingKeys: String, CodingKey {
        case eventID = "eventId"
        case kind, fireAt, title, body
        case originalFireAt = "originalFireAt"
        case itemID = "itemId"
        case intentID = "intentId"
    }
}

/// 알림/회수 반응 — 백엔드 `ReactionKind` 와 1:1. 액션 ↔ 서버 상태전이 매핑(ux-ui §4 codex-7):
/// 탭/열기/기억남=`opened`, 알림 swipe-away=`dismissed`, "그만 보기"=`stop`(영구, plan cancelled).
public enum RecallReaction: String, Sendable, Codable {
    /// 알림 탭·상세 진입·"기억났어요"(행동 양성 신호). 학습 우선 신호(ux-ui §6).
    case opened
    /// 알림을 열지 않고 swipe-away 한 soft 부정(cooldown). **OS 알림 dismiss 신호**라 앱 내
    /// 화면에는 대응 제스처가 없다(back-navigation 은 이미 opened). 캡처하려면
    /// `UNNotificationCategory` + customDismissAction 등록이 필요 — 알림 인프라 후속 스코프.
    case dismissed
    /// "이 기억 그만"(영구 부정 → plan cancelled, codex-7 1:1). destructive 액션.
    case stop
}

/// 능동 회수 1건 — 백엔드 `RecallFeedEntry` 미러. 홈 한 칸·자세히 목록·알림 landing 공용.
/// UI 전용(색/아이콘/그라데이션)은 제외 — iOS 가 `reason` → 매핑한다.
public struct RecallFeedEntryDTO: Sendable, Hashable, Codable, Identifiable {
    /// 원본 mochiItem 의 server PK(상세 진입·원본 보기 대상).
    public let itemID: UUID
    /// 상세 섹션 형태("knowledge" 등). 트랙 A/B 에선 "knowledge".
    public let kind: String
    /// "왜 지금 떠올렸나"(분류 아님). "fadingValue" 등 — iOS 가 색/아이콘/라벨로 매핑.
    public let reason: String
    public let title: String
    public let oneline: String
    /// 출처 표기(예: "medium · Hybrid Search").
    public let source: String
    public let savedAt: Date
    /// 모찌가 정리한 핵심 줄들(원본 안 봐도 떠올림). 없으면 빈 배열.
    public let gist: [String]
    /// 관련 기억(트랙 C) — 탭 시 그 항목 상세로. 없으면 빈 배열.
    public let related: [RelatedItemDTO]
    public let relatedCount: Int
    /// 최근 sent 알림의 event_id(반응 추적·landing fallback 키). 없으면 nil.
    public let recallEventID: UUID?

    public var id: UUID { itemID }

    public init(
        itemID: UUID,
        kind: String,
        reason: String,
        title: String,
        oneline: String,
        source: String,
        savedAt: Date,
        gist: [String] = [],
        related: [RelatedItemDTO] = [],
        relatedCount: Int,
        recallEventID: UUID? = nil
    ) {
        self.itemID = itemID
        self.kind = kind
        self.reason = reason
        self.title = title
        self.oneline = oneline
        self.source = source
        self.savedAt = savedAt
        self.gist = gist
        self.related = related
        self.relatedCount = relatedCount
        self.recallEventID = recallEventID
    }

    private enum CodingKeys: String, CodingKey {
        case itemID = "itemId"
        case kind, reason, title, oneline, source
        case savedAt = "savedAt"
        case gist, related
        case relatedCount = "relatedCount"
        case recallEventID = "recallEventID"
    }
}

/// 관련 기억 1건(트랙 C "관련 N개") — 백엔드 `RelatedItem` 미러. 탭 시 `itemID` 상세로 push.
public struct RelatedItemDTO: Sendable, Hashable, Codable, Identifiable {
    public let itemID: UUID
    public let title: String
    public let oneline: String

    public var id: UUID { itemID }

    public init(itemID: UUID, title: String, oneline: String) {
        self.itemID = itemID
        self.title = title
        self.oneline = oneline
    }

    private enum CodingKeys: String, CodingKey {
        case itemID = "itemId"
        case title, oneline
    }
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

/// 상세를 연 직전 화면(navigation origin) — `logItemAccess` 의 `source`.
/// origin 이 의도를 인코딩한다(검색=의도적 회수, 채팅=모찌가 찾아줌, recall/notification=모찌 push).
/// rawValue 는 백엔드 `AccessSource` enum 과 1:1(계약 정본). 새 origin 은 백엔드 enum 에 먼저 추가.
public enum ItemAccessSource: String, Sendable, Codable {
    case home
    case search
    case chat
    case recall
    case notification
    case calendar
    case category
    case favorites
    case digest
    /// 상세 안의 "비슷한 기록" 카드로 들어간 재귀 진입(세션 내 연관 탐색).
    case related
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
    /// 채팅 일정 proposal 이 propose-시점에 도출한 item 메타 — confirmedInstances 경로에서만 채워진다
    /// (instance 재분석 아님 — §5.2 는 outbox 재분석만 생략, category/summary 는 채운다).
    public let category: String?
    public let summary: String?
    /// 분석 전용 ephemeral OCR(화면 transcript). 업로드 경로가 정책에 따라 채운다(originalUpload 일 때만).
    /// 서버는 분석 컨텍스트로만 쓰고 추론 후 삭제한다(영속/노출/인덱스 없음 — PRIVACY §1.1).
    public let analysisOcrText: String?

    public init(
        channel: IngestChannel,
        url: URL? = nil,
        text: String? = nil,
        userMemo: String? = nil,
        imageRefs: [ImageRefDTO] = [],
        confirmedInstances: [ConfirmedInstanceIngestDTO]? = nil,
        category: String? = nil,
        summary: String? = nil,
        analysisOcrText: String? = nil
    ) {
        self.channel = channel
        self.url = url
        self.text = text
        self.userMemo = userMemo
        self.imageRefs = imageRefs
        self.confirmedInstances = confirmedInstances
        self.category = category
        self.summary = summary
        self.analysisOcrText = analysisOcrText
    }

    private enum CodingKeys: String, CodingKey {
        case channel, url, text, category, summary
        case userMemo = "userMemo"
        case imageRefs = "imageRefs"
        case confirmedInstances = "confirmedInstances"
        case analysisOcrText = "analysisOcrText"
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
    /// Agent 가 찾아준 참고 링크 — entities(kind=reference_url) 서버 projection. 없으면 빈 배열.
    public let referenceLinks: [ReferenceLinkDTO]
    /// 기록이 가리킨 장소 — entities(kind=place) 서버 projection. 장소성 없으면 nil.
    public let place: PlaceDTO?
    public let importance: Int
    /// 사용자가 준 "중요" 즐겨찾기 신호 — 서버 동기화 상태. 기본 false.
    public let isFavorite: Bool
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
        case isFavorite = "isFavorite"
        case referenceLinks = "referenceLinks"
        case place
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
        referenceLinks: [ReferenceLinkDTO] = [],
        place: PlaceDTO? = nil,
        importance: Int,
        isFavorite: Bool = false,
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
        self.referenceLinks = referenceLinks
        self.place = place
        self.importance = importance
        self.isFavorite = isFavorite
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
        referenceLinks = try c.decodeIfPresent([ReferenceLinkDTO].self, forKey: .referenceLinks) ?? []
        place = try c.decodeIfPresent(PlaceDTO.self, forKey: .place)
        importance = try c.decode(Int.self, forKey: .importance)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
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

/// 장소 응답 — `place` 필드. 서버 PlaceResponse 미러 (좌표 WGS84).
public struct PlaceDTO: Sendable, Hashable, Codable {
    public let name: String
    public let lat: Double
    public let lng: Double
    public let category: String?
    public let address: String?
    public let roadAddress: String?
    public let mapUrl: String?
    /// Google Places 보강 (별점·리뷰수·매장사진) — 서버가 좌표 매칭됐을 때만 내려준다.
    public let rating: Double?
    public let ratingCount: Int?
    public let imageUrl: String?

    public init(
        name: String,
        lat: Double,
        lng: Double,
        category: String? = nil,
        address: String? = nil,
        roadAddress: String? = nil,
        mapUrl: String? = nil,
        rating: Double? = nil,
        ratingCount: Int? = nil,
        imageUrl: String? = nil
    ) {
        self.name = name
        self.lat = lat
        self.lng = lng
        self.category = category
        self.address = address
        self.roadAddress = roadAddress
        self.mapUrl = mapUrl
        self.rating = rating
        self.ratingCount = ratingCount
        self.imageUrl = imageUrl
    }

    private enum CodingKeys: String, CodingKey {
        case name, lat, lng, category, address, rating
        case roadAddress = "roadAddress"
        case mapUrl = "mapUrl"
        case ratingCount = "ratingCount"
        case imageUrl = "imageUrl"
    }
}

/// 참고 링크 응답 — `referenceLinks` 배열 원소. 서버 ReferenceLinkResponse 미러.
public struct ReferenceLinkDTO: Sendable, Hashable, Codable {
    public let url: String
    public let title: String
    public let label: String
    public let role: String
    public let provider: String
    public let rankProfile: String
    public let source: String?
    public let usefulness: Int?
    public let subtitle: String?
    public let priceText: String?

    public init(
        url: String,
        title: String,
        label: String,
        role: String,
        provider: String,
        rankProfile: String,
        source: String? = nil,
        usefulness: Int? = nil,
        subtitle: String? = nil,
        priceText: String? = nil
    ) {
        self.url = url
        self.title = title
        self.label = label
        self.role = role
        self.provider = provider
        self.rankProfile = rankProfile
        self.source = source
        self.usefulness = usefulness
        self.subtitle = subtitle
        self.priceText = priceText
    }

    private enum CodingKeys: String, CodingKey {
        case url, title, label, role, provider, source, usefulness, subtitle, priceText
        case rankProfile = "rankProfile"
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

/// 이번 달 정리 — 모찌 한마디 + 정규화된 카테고리 묶음.
public struct MonthlyDigestDTO: Sendable, Hashable, Codable {
    public let greeting: String
    public let groups: [Group]
    /// false 면 그 달 항목이 적어 LLM 미호출한 정적 폴백(클라가 캐시 정책에 활용).
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
