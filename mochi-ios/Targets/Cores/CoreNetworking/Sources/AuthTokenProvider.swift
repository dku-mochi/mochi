import Foundation

/// 로컬·키체인에서 토큰을 가져오는 추상화. 메인 앱은 키체인 구현을, 테스트는 stub 을 주입한다.
///
/// ``OpenAPIMochiClient`` 의 ``AuthMiddleware`` 가 매 요청마다 이 provider 로부터 access token 을
/// 가져와 `Authorization: Bearer` 헤더에 주입한다.
public protocol AuthTokenProvider: Sendable {
    func bearerToken() async -> String?
}

public struct DevAuthTokenProvider: AuthTokenProvider {
    public let subject: String
    public init(subject: String) { self.subject = subject }
    public func bearerToken() async -> String? { "dev:\(subject)" }
}
