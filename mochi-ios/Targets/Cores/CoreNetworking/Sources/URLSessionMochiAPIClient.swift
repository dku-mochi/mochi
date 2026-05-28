import Foundation
import CoreDomain

/// URLSession 기반 라이브 ``MochiAPIClient`` 구현.
///
/// **계약 보장:**
/// - 모든 요청에 `X-Mochi-Request-ID` 생성·송신
/// - `POST /captures` 는 `Idempotency-Key` 헤더 강제
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
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    public func ingestCapture(_ request: CaptureIngestRequest, idempotencyKey: String) async throws -> CaptureDTO {
        try await perform(
            method: "POST",
            path: "/api/v1/captures",
            body: request,
            extraHeaders: ["Idempotency-Key": idempotencyKey]
        )
    }

    public func getCapture(id: UUID) async throws -> CaptureDTO {
        try await perform(method: "GET", path: "/api/v1/captures/\(id.uuidString)", body: Optional<Empty>.none)
    }

    public func search(query: String, scope: SearchScope) async throws -> SearchResponse {
        let body = SearchRequestBody(query: query, scope: scope)
        return try await perform(method: "POST", path: "/api/v1/search", body: body)
    }

    // MARK: - Private

    private struct Empty: Encodable {}
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
