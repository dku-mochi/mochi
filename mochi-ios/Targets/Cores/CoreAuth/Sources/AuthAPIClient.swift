import Foundation
import CoreNetworking

/// 백엔드 `/auth/*` + `/users/me` 만 다루는 좁은 클라이언트.
///
/// ``MochiAPIClient`` 와는 분리한 이유:
/// - 인증 엔드포인트는 access token 검증 대상이 아니다 (혹은 일부만 그렇다)
/// - 이 클라이언트는 401 → refresh → retry 인터셉터를 **사용하지 않는다** — 그 인터셉터가 내부적으로 이 클라이언트를 호출하기 때문 (재귀 차단)
public protocol AuthAPIClient: Sendable {
    func signInWithApple(_ body: AppleSignInBody) async throws -> AuthSession
    func signInWithGoogle(_ body: GoogleSignInBody) async throws -> AuthSession
    /// 백엔드 ``POST /auth/dev``. ``environment=local`` 외 환경에선 503 envelope 반환.
    func signInAsDev(_ body: DevSignInBody) async throws -> AuthSession
    func refresh(_ body: RefreshBody) async throws -> AuthTokens
    func logout(_ body: LogoutBody) async throws
    func getMe(accessToken: String) async throws -> AuthUser
}

public final class URLSessionAuthAPIClient: AuthAPIClient, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        self.encoder = e
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.decoder = d
    }

    public func signInWithApple(_ body: AppleSignInBody) async throws -> AuthSession {
        try await perform(method: "POST", path: "/api/v1/auth/apple", body: body)
    }

    public func signInWithGoogle(_ body: GoogleSignInBody) async throws -> AuthSession {
        try await perform(method: "POST", path: "/api/v1/auth/google", body: body)
    }

    public func signInAsDev(_ body: DevSignInBody) async throws -> AuthSession {
        try await perform(method: "POST", path: "/api/v1/auth/dev", body: body)
    }

    public func refresh(_ body: RefreshBody) async throws -> AuthTokens {
        try await perform(method: "POST", path: "/api/v1/auth/refresh", body: body)
    }

    public func logout(_ body: LogoutBody) async throws {
        let _: EmptyResponse = try await perform(
            method: "POST",
            path: "/api/v1/auth/logout",
            body: body,
            allowEmpty: true
        )
    }

    public func getMe(accessToken: String) async throws -> AuthUser {
        try await perform(
            method: "GET",
            path: "/api/v1/users/me",
            body: Optional<EmptyBody>.none,
            extraHeaders: ["Authorization": "Bearer \(accessToken)"]
        )
    }

    // MARK: - Private

    private struct EmptyBody: Encodable {}
    private struct EmptyResponse: Decodable {}

    private func perform<Body: Encodable, Response: Decodable>(
        method: String,
        path: String,
        body: Body?,
        extraHeaders: [String: String] = [:],
        allowEmpty: Bool = false
    ) async throws -> Response {
        var url = baseURL
        url.append(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Mochi-Request-ID")
        for (k, v) in extraHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if let body {
            request.httpBody = try encoder.encode(body)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthError.network(message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.network(message: "Non-HTTP response")
        }
        if (200..<300).contains(http.statusCode) {
            if allowEmpty, data.isEmpty {
                // 빈 응답 → EmptyResponse(). Response 가 그게 아니면 decode 시도.
                if let empty = EmptyResponse() as? Response {
                    return empty
                }
            }
            do {
                return try decoder.decode(Response.self, from: data)
            } catch {
                throw AuthError.decoding(message: String(describing: error))
            }
        }

        if let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data) {
            throw AuthError.from(envelope)
        }
        throw AuthError.unknown(
            message: "HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")"
        )
    }
}
