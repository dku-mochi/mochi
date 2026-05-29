import Foundation
import CoreDomain

/// URLSession 기반 라이브 ``MochiAPIClient`` 구현.
///
/// **계약 보장:**
/// - 모든 요청에 `X-Mochi-Request-ID` 생성·송신
/// - `POST /mochi_items` 는 `Idempotency-Key` 헤더 강제
/// - `Authorization: Bearer <token>` 은 ``AuthTokenProvider`` 가 주입
/// - 응답이 2xx 이면 디코드, 아니면 ``APIErrorEnvelope`` 으로 디코드 후 throw
///
/// 정식 OpenAPI generator (swift-openapi-generator) 으로 교체 전까지는 이 어댑터가 라이브 구현이다.
public final class URLSessionMochiAPIClient: MochiAPIClient, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: any AuthTokenProvider
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        baseURL: URL,
        tokenProvider: any AuthTokenProvider,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        // 백엔드 (FastAPI + Pydantic) 는 ``datetime.utcnow().isoformat()`` 으로 보내는데 microsecond
        // (6 digits) fractional seconds 가 붙는다 — 예: "2026-05-26T19:27:44.244325".
        // Swift 기본 ``.iso8601`` 은 fractional 자체를 거부, ``ISO8601DateFormatter`` +
        // ``.withFractionalSeconds`` 도 milliseconds (3 digits) 만 지원해 microsecond 응답을 throw.
        // → ``.custom`` 으로 여러 형식을 순차 시도.
        dec.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            for d in Self.tryParseDate(str) { return d }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date format: \(str)"
            )
        }
        self.decoder = dec
    }

    /// 백엔드의 다양한 datetime 변형을 차례로 시도해 첫 성공한 ``Date`` 를 yield.
    /// ISO8601 with microsecond / millisecond / no-fractional / with-offset / no-offset 모두 커버.
    private static func tryParseDate(_ str: String) -> [Date] {
        var results: [Date] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: str) { results.append(d) }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: str) { results.append(d) }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        // microseconds (FastAPI utcnow().isoformat() — naive, no offset).
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss",
        ]
        for f in formats {
            df.dateFormat = f
            if let d = df.date(from: str) { results.append(d) }
        }
        return results
    }

    public func ingestMochiItem(_ request: MochiItemIngestRequest, idempotencyKey: String) async throws -> MochiItemDTO {
        try await perform(
            method: "POST",
            path: "/api/v1/mochi_items",
            body: request,
            extraHeaders: ["Idempotency-Key": idempotencyKey]
        )
    }

    public func presignCaptureUpload(sha256: String, mimeType: String) async throws -> PresignUploadDTO {
        try await perform(
            method: "POST",
            path: "/api/v1/mochi_items/presign",
            body: PresignRequestBody(sha256: sha256, mimeType: mimeType)
        )
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
        try await perform(
            method: "POST",
            path: "/api/v1/mochi_items/back-tap",
            body: BackTapRequestBody(
                objectKey: objectKey,
                sha256: sha256,
                mimeType: mimeType,
                byteSize: byteSize,
                userMemo: userMemo
            ),
            extraHeaders: ["Idempotency-Key": idempotencyKey]
        )
    }

    public func getMochiItem(id: UUID) async throws -> MochiItemDTO {
        try await perform(method: "GET", path: "/api/v1/mochi_items/\(id.uuidString)", body: Optional<Empty>.none)
    }

    public func search(query: String, scope: SearchScope) async throws -> SearchResponse {
        let body = SearchRequestBody(query: query, scope: scope)
        return try await perform(method: "POST", path: "/api/v1/search", body: body)
    }

    // MARK: - Private

    private struct Empty: Encodable {}
    private struct PresignRequestBody: Encodable {
        let sha256: String
        let mimeType: String
    }
    private struct BackTapRequestBody: Encodable {
        let objectKey: String
        let sha256: String
        let mimeType: String
        let byteSize: Int
        let userMemo: String?
    }
    private struct SearchRequestBody: Encodable {
        let query: String
        let scope: SearchScope
    }

    private func perform<Body: Encodable, Response: Decodable>(
        method: String,
        path: String,
        body: Body?,
        extraHeaders: [String: String] = [:]
    ) async throws -> Response {
        var url = baseURL
        url.append(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Mochi-Request-ID")
        if let token = await tokenProvider.bearerToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in extraHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if let body {
            request.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIErrorEnvelope(code: "client.invalid_response", message: "Non-HTTP response", requestID: "n/a", retryAfter: nil)
        }
        if (200..<300).contains(http.statusCode) {
            return try decoder.decode(Response.self, from: data)
        }
        if let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data) {
            throw envelope
        }
        throw APIErrorEnvelope(
            code: "client.http_\(http.statusCode)",
            message: String(data: data, encoding: .utf8) ?? "",
            requestID: http.value(forHTTPHeaderField: "X-Mochi-Request-ID") ?? "unknown",
            retryAfter: nil
        )
    }
}

/// 로컬·키체인에서 토큰을 가져오는 추상화. 메인 앱은 키체인 구현을, 테스트는 stub 을 주입한다.
public protocol AuthTokenProvider: Sendable {
    func bearerToken() async -> String?
}

public struct DevAuthTokenProvider: AuthTokenProvider {
    public let subject: String
    public init(subject: String) { self.subject = subject }
    public func bearerToken() async -> String? { "dev:\(subject)" }
}
