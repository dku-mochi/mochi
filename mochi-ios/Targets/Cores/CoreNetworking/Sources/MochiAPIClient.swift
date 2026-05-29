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

    /// `POST /api/v1/mochi_items/back-tap` — 백탭 ingestion. 클라이언트가 GCS 에 올린 objectKey 를 보내면
    /// 백엔드가 `.screenshot` mochiItem 을 `ingested` 로 적재한다 (분석 전). 4-Intent 후보·confidence 는
    /// worker 가 비동기로 채우고, iOS 는 폴링(`getMochiItem`)으로 반영한다.
    /// Idempotency-Key 는 mochiItem id 그대로 사용 — 멱등 재요청 시 같은 item 반환.
    func ingestBackTapMochiItem(
        objectKey: String,
        sha256: String,
        mimeType: String,
        byteSize: Int,
        userMemo: String?,
        idempotencyKey: String
    ) async throws -> MochiItemDTO

    /// `GET /api/v1/mochi_items/{id}` — owner-scoped mochiItem 조회.
    func getMochiItem(id: UUID) async throws -> MochiItemDTO

    /// `POST /api/v1/search` — 자연어 질의 → Hybrid Search RAG.
    func search(query: String, scope: SearchScope) async throws -> SearchResponse
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
    public let intent: Intent?
    /// primary 를 제외한 보조 의도 (applicability 내림차순). metadata-only 분석 결과의 후보 재구성에 사용.
    public let secondaryIntents: [Intent]
    /// Intent → 적용 강도 (0.0–1.0). 후보에 등장하지 않은 intent 는 키에 없다.
    public let intentApplicability: [String: Double]
    public let summary: String?
    public let importance: Int
    public let confidence: Double
    /// LLM use case 후보 (홈 "헷갈려요" 카드·Live Activity 버튼의 원천). 분석 전엔 빈 배열.
    public let candidates: [IntentCandidateDTO]
    public let lifecycleKind: String
    public let syncKind: String
    public let imageRefs: [ImageRefDTO]
    public let capturedAt: Date
    public let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, channel, url, text, intent, summary, importance, confidence, candidates
        case secondaryIntents = "secondaryIntents"
        case intentApplicability = "intentApplicability"
        case userMemo = "userMemo"
        case lifecycleKind = "lifecycleKind"
        case syncKind = "syncKind"
        case imageRefs = "imageRefs"
        case capturedAt = "capturedAt"
        case createdAt = "createdAt"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        channel = try c.decode(IngestChannel.self, forKey: .channel)
        url = try c.decodeIfPresent(URL.self, forKey: .url)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        userMemo = try c.decodeIfPresent(String.self, forKey: .userMemo)
        intent = try c.decodeIfPresent(Intent.self, forKey: .intent)
        secondaryIntents = try c.decodeIfPresent([Intent].self, forKey: .secondaryIntents) ?? []
        intentApplicability = try c.decodeIfPresent([String: Double].self, forKey: .intentApplicability) ?? [:]
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        importance = try c.decode(Int.self, forKey: .importance)
        confidence = try c.decode(Double.self, forKey: .confidence)
        candidates = try c.decodeIfPresent([IntentCandidateDTO].self, forKey: .candidates) ?? []
        lifecycleKind = try c.decode(String.self, forKey: .lifecycleKind)
        syncKind = try c.decode(String.self, forKey: .syncKind)
        imageRefs = try c.decodeIfPresent([ImageRefDTO].self, forKey: .imageRefs) ?? []
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

public struct IntentCandidateDTO: Sendable, Hashable, Codable {
    public let label: String
    public let intent: Intent
    public let applicability: Double
    public let reasoning: String
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
