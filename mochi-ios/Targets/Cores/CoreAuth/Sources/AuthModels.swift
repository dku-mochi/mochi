import Foundation

/// 백엔드 `/auth/*` 응답과 매칭되는 DTO.
///
/// camelCase alias 는 ``snake_case`` 와 ``camelCase`` 모두 받는 Pydantic ``populate_by_name=True`` 설정에 의존.
/// 본 iOS 클라이언트는 camelCase 만 송수신한다.

public struct AuthUser: Equatable, Sendable, Hashable, Codable {
    public let id: UUID
    public let email: String
    public let displayName: String
    public let locale: String
    public let onboardingCompletedAt: Date?

    public init(
        id: UUID,
        email: String,
        displayName: String,
        locale: String,
        onboardingCompletedAt: Date?
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.locale = locale
        self.onboardingCompletedAt = onboardingCompletedAt
    }
}

public struct AuthTokens: Equatable, Sendable, Hashable, Codable {
    public let accessToken: String
    public let accessTokenExpiresAt: Date
    public let refreshToken: String
    public let refreshTokenExpiresAt: Date
    public let tokenType: String

    public init(
        accessToken: String,
        accessTokenExpiresAt: Date,
        refreshToken: String,
        refreshTokenExpiresAt: Date,
        tokenType: String = "Bearer"
    ) {
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshToken = refreshToken
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.tokenType = tokenType
    }
}

public struct AuthSession: Equatable, Sendable, Hashable, Codable {
    public let user: AuthUser
    public let tokens: AuthTokens
    public let isNewUser: Bool

    public init(user: AuthUser, tokens: AuthTokens, isNewUser: Bool) {
        self.user = user
        self.tokens = tokens
        self.isNewUser = isNewUser
    }
}

// MARK: - Request bodies

public struct AppleSignInBody: Encodable, Sendable {
    public let identityToken: String
    public let rawNonce: String?
    public let fullName: String?
    public let deviceLabel: String?

    public init(identityToken: String, rawNonce: String?, fullName: String?, deviceLabel: String?) {
        self.identityToken = identityToken
        self.rawNonce = rawNonce
        self.fullName = fullName
        self.deviceLabel = deviceLabel
    }
}

public struct GoogleSignInBody: Encodable, Sendable {
    public let idToken: String
    public let deviceLabel: String?

    public init(idToken: String, deviceLabel: String?) {
        self.idToken = idToken
        self.deviceLabel = deviceLabel
    }
}

public struct RefreshBody: Encodable, Sendable {
    public let refreshToken: String
    public let deviceLabel: String?

    public init(refreshToken: String, deviceLabel: String?) {
        self.refreshToken = refreshToken
        self.deviceLabel = deviceLabel
    }
}

public struct LogoutBody: Encodable, Sendable {
    public let refreshToken: String
    public init(refreshToken: String) { self.refreshToken = refreshToken }
}

/// 백엔드 ``POST /auth/dev`` 의 요청 바디. local 환경 전용 임시 로그인.
public struct DevSignInBody: Encodable, Sendable {
    public let subject: String
    public let displayName: String?
    public let deviceLabel: String?

    public init(subject: String, displayName: String? = nil, deviceLabel: String? = nil) {
        self.subject = subject
        self.displayName = displayName
        self.deviceLabel = deviceLabel
    }
}

// MARK: - Apple raw credential

/// AuthenticationServices 의 ASAuthorizationAppleIDCredential 에서 추출한 raw 자료.
///
/// ``fullName`` 은 첫 인가에만 의미 있다 (Apple 정책). 두 번째부터는 nil.
public struct AppleRawCredential: Sendable, Equatable {
    public let identityToken: String
    public let rawNonce: String
    public let fullName: String?
    public let userIdentifier: String

    public init(identityToken: String, rawNonce: String, fullName: String?, userIdentifier: String) {
        self.identityToken = identityToken
        self.rawNonce = rawNonce
        self.fullName = fullName
        self.userIdentifier = userIdentifier
    }
}

public struct GoogleRawCredential: Sendable, Equatable {
    public let idToken: String
    public let userIdentifier: String
    public let email: String?
    public let displayName: String?

    public init(idToken: String, userIdentifier: String, email: String?, displayName: String?) {
        self.idToken = idToken
        self.userIdentifier = userIdentifier
        self.email = email
        self.displayName = displayName
    }
}
