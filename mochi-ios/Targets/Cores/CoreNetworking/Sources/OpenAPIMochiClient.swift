import Foundation
import CoreDomain
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// `swift-openapi-generator` 가 `openapi.json` 에서 생성한 ``Client`` 를 ``MochiAPIClient`` 로 감싸는 어댑터.
///
/// 요청/응답 스키마는 `openapi.json`(백엔드 단일 원천에서 `make openapi` 로 생성) → `CodeGen/generate.sh`
/// 로 생성된 ``Client``/``Components`` 를 그대로 위임한다 — 계약 drift 가 구조적으로 불가능하다(⓪-tier).
///
/// - **날짜**: 백엔드의 microsecond/naive datetime 을 ``MochiDateTranscoder`` 로 디코드.
/// - **인증/추적**: ``AuthMiddleware`` 가 `Authorization: Bearer` + `X-Mochi-Request-ID` 주입.
/// - **Idempotency-Key**: 각 op 의 헤더 파라미터로 주입.
/// - **``putCaptureImage``**: GCS 직접 PUT 이라 생성 대상이 아니며 URLSession 으로 직접 수행.
public final class OpenAPIMochiClient: MochiAPIClient, @unchecked Sendable {
    private let client: Client
    private let session: URLSession

    public init(
        baseURL: URL,
        tokenProvider: any AuthTokenProvider,
        session: URLSession = .shared
    ) {
        self.session = session
        self.client = Client(
            serverURL: baseURL,
            configuration: Configuration(dateTranscoder: MochiDateTranscoder()),
            transport: URLSessionTransport(),
            middlewares: [AuthMiddleware(tokenProvider: tokenProvider)]
        )
    }

    public func ingestMochiItem(
        _ request: MochiItemIngestRequest,
        idempotencyKey: String
    ) async throws -> MochiItemDTO {
        let body = Components.Schemas.MochiItemCreateRequest(
            channel: .init(rawValue: request.channel.rawValue) ?? .unknown,
            url: request.url?.absoluteString,
            text: request.text,
            userMemo: request.userMemo,
            imageRefs: request.imageRefs.map(Self.mapImageRefToRequest)
        )
        let output = try await client.create_mochi_item_api_v1_mochi_items_post(
            .init(headers: .init(Idempotency_hyphen_Key: idempotencyKey), body: .json(body))
        )
        switch output {
        case let .created(response): return try Self.mapMochiItem(try response.body.json)        case let .undocumented(status, payload): throw await Self.error(status: status, payload: payload)
        }
    }

    public func presignCaptureUpload(sha256: String, mimeType: String) async throws -> PresignUploadDTO {
        let output = try await client.presign_capture_upload_api_v1_mochi_items_presign_post(
            .init(body: .json(.init(sha256: sha256, mimeType: mimeType)))
        )
        switch output {
        case let .ok(response):
            let dto = try response.body.json
            guard let uploadURL = URL(string: dto.uploadURL) else {
                throw Self.clientError("client.invalid_url", dto.uploadURL)
            }
            return PresignUploadDTO(objectKey: dto.objectKey, uploadURL: uploadURL, expiresAt: dto.expiresAt)        case let .undocumented(status, payload): throw await Self.error(status: status, payload: payload)
        }
    }

    public func putCaptureImage(uploadURL: URL, data: Data, mimeType: String) async throws {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIErrorEnvelope(code: "client.invalid_response", message: "Non-HTTP response", requestID: "n/a", retryAfter: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIErrorEnvelope(
                code: "client.gcs_put_\(http.statusCode)",
                message: String(data: responseData, encoding: .utf8) ?? "",
                requestID: "gcs",
                retryAfter: nil
            )
        }
    }

    public func ingestBackTapMochiItem(
        objectKey: String,
        sha256: String,
        mimeType: String,
        byteSize: Int,
        userMemo: String?,
        idempotencyKey: String
    ) async throws -> MochiItemDTO {
        let body = Components.Schemas.BackTapMochiItemRequest(
            objectKey: objectKey,
            sha256: sha256,
            mimeType: mimeType,
            byteSize: byteSize,
            userMemo: userMemo
        )
        let output = try await client.create_back_tap_mochi_item_api_v1_mochi_items_back_tap_post(
            .init(headers: .init(Idempotency_hyphen_Key: idempotencyKey), body: .json(body))
        )
        switch output {
        case let .created(response): return try Self.mapMochiItem(try response.body.json)        case let .undocumented(status, payload): throw await Self.error(status: status, payload: payload)
        }
    }

    public func getMochiItem(id: UUID) async throws -> MochiItemDTO {
        let output = try await client.get_mochi_item_api_v1_mochi_items__mochi_item_id__get(
            .init(path: .init(mochi_item_id: id.uuidString))
        )
        switch output {
        case let .ok(response): return try Self.mapMochiItem(try response.body.json)        case let .undocumented(status, payload): throw await Self.error(status: status, payload: payload)
        }
    }

    public func search(query: String, scope: SearchScope) async throws -> SearchResponse {
        let body = Components.Schemas.SearchRequest(query: query, scope: .init(rawValue: scope.rawValue))
        let output = try await client.search_api_v1_search_post(.init(body: .json(body)))
        switch output {
        case let .ok(response):
            let dto = try response.body.json
            return SearchResponse(
                answer: dto.answer,
                citations: try dto.citations.map(Self.mapCitation),
                totalTokens: dto.totalTokens ?? 0,
                agentRunID: dto.agentRunId.flatMap { UUID(uuidString: $0) }
            )        case let .undocumented(status, payload): throw await Self.error(status: status, payload: payload)
        }
    }

    // MARK: - 스키마 → DTO 매핑

    /// 생성 `MochiItemResponse` → ``MochiItemDTO``. 필수 `id` 는 파싱 실패 시 throw 하지만,
    /// optional `url`(아래)·`SearchResponse.agentRunID` 는 계약상 nilable 이라 파싱 실패 시 nil
    /// 강등한다 — 정상 경로에선 백엔드가 유효 UUID/URL 만 보낸다.
    private static func mapMochiItem(_ r: Components.Schemas.MochiItemResponse) throws -> MochiItemDTO {
        guard let id = UUID(uuidString: r.id) else {
            throw clientError("client.invalid_uuid", r.id)
        }
        return MochiItemDTO(
            id: id,
            channel: IngestChannel(rawValue: r.channel.rawValue) ?? .unknown,
            url: r.url.flatMap { URL(string: $0) },
            text: r.text,
            userMemo: r.userMemo,
            intent: Intent(rawValue: r.intent.rawValue),
            secondaryIntents: (r.secondaryIntents ?? []).compactMap { Intent(rawValue: $0.rawValue) },
            intentApplicability: r.intentApplicability?.additionalProperties ?? [:],
            summary: r.summary,
            importance: r.importance,
            confidence: r.confidence,
            candidates: (r.candidates ?? []).map(mapCandidate),
            lifecycleKind: r.lifecycleKind,
            syncKind: r.syncKind,
            imageRefs: (r.imageRefs ?? []).map(mapImageRefFromResponse),
            capturedAt: r.capturedAt,
            createdAt: r.createdAt
        )
    }

    private static func mapCandidate(_ c: Components.Schemas.IntentCandidateResponse) -> IntentCandidateDTO {
        IntentCandidateDTO(
            label: c.label,
            intent: Intent(rawValue: c.intent.rawValue) ?? .memo,
            applicability: c.applicability,
            reasoning: c.reasoning ?? ""
        )
    }

    private static func mapImageRefFromResponse(_ r: Components.Schemas.ImageRefResponse) -> ImageRefDTO {
        ImageRefDTO(objectKey: r.objectKey, mimeType: r.mimeType, byteSize: r.byteSize, sha256: r.sha256)
    }

    private static func mapImageRefToRequest(_ r: ImageRefDTO) -> Components.Schemas.ImageRefDTO {
        .init(objectKey: r.objectKey, mimeType: r.mimeType, byteSize: r.byteSize, sha256: r.sha256)
    }

    private static func mapCitation(_ c: Components.Schemas.CitationDTO) throws -> SearchResponse.Citation {
        guard let id = UUID(uuidString: c.mochiItemId) else {
            throw clientError("client.invalid_uuid", c.mochiItemId)
        }
        return SearchResponse.Citation(mochiItemID: id, snippet: c.snippet, score: c.score)
    }

    // MARK: - 에러 변환 (호출부의 `catch APIErrorEnvelope` 보존)

    private static func clientError(_ code: String, _ detail: String) -> APIErrorEnvelope {
        APIErrorEnvelope(code: code, message: detail, requestID: "n/a", retryAfter: nil)
    }

    /// openapi 에 문서화되지 않은(주로 4xx/5xx 에러 envelope) 응답을 ``APIErrorEnvelope`` 로 변환.
    private static func error(status: Int, payload: OpenAPIRuntime.UndocumentedPayload) async -> APIErrorEnvelope {
        guard let httpBody = payload.body else {
            return APIErrorEnvelope(code: "client.http_\(status)", message: "", requestID: "unknown", retryAfter: nil)
        }
        let data = try? await Data(collecting: httpBody, upTo: 1_048_576)
        if let data, let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
            return envelope
        }
        return APIErrorEnvelope(
            code: "client.http_\(status)",
            message: data.flatMap { String(data: $0, encoding: .utf8) } ?? "",
            requestID: "unknown",
            retryAfter: nil
        )
    }
}

// MARK: - 날짜 transcoder

/// 백엔드(FastAPI)의 microsecond/naive datetime 변형을 차례로 시도해 디코드한다.
/// 수기 ``URLSessionMochiAPIClient`` 의 `tryParseDate` 로직을 그대로 이식 — 기본 ISO8601 은
/// microsecond fractional seconds 를 거부하므로 커스텀 transcoder 가 필수다.
struct MochiDateTranscoder: DateTranscoder {
    func encode(_ date: Date) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func decode(_ string: String) throws -> Date {
        for date in Self.candidates(string) { return date }
        throw DateDecodingError(value: string)
    }

    private static func candidates(_ str: String) -> [Date] {
        var results: [Date] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: str) { results.append(d) }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: str) { results.append(d) }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss",
        ]
        for format in formats {
            df.dateFormat = format
            if let d = df.date(from: str) { results.append(d) }
        }
        return results
    }
}

private struct DateDecodingError: Error, CustomStringConvertible {
    let value: String
    var description: String { "Unrecognized date format: \(value)" }
}

// MARK: - 인증/추적 미들웨어

/// 모든 요청에 `Authorization: Bearer <token>` 과 `X-Mochi-Request-ID` 를 주입한다.
/// 토큰은 ``AuthTokenProvider`` 에서 async 로 가져온다 (수기 클라이언트와 동일 계약).
struct AuthMiddleware: ClientMiddleware {
    let tokenProvider: any AuthTokenProvider

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if let token = await tokenProvider.bearerToken() {
            request.headerFields[.authorization] = "Bearer \(token)"
        }
        if let requestIDField = HTTPField.Name("X-Mochi-Request-ID") {
            request.headerFields[requestIDField] = UUID().uuidString
        }
        return try await next(request, body, baseURL)
    }
}
