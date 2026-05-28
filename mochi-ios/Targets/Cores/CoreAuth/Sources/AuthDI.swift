import Dependencies
import Foundation
import CoreNetworking

/// CoreAuth 의 단일 ``Dependency`` 진입점.
///
/// liveValue 는 ``AppDependencies.bootstrap()`` 에서 ``LiveAuthCoordinator`` 로 prepareDependencies.
/// testValue / previewValue 는 ``UnconfiguredAuthCoordinator`` 로 두어, 라이브 구현이 누락되면
/// 명시적인 에러로 즉시 표면화한다.
public enum AuthCoordinatorKey: DependencyKey {
    public static let liveValue: AuthCoordinator = UnconfiguredAuthCoordinator.shared
    public static let testValue: AuthCoordinator = UnconfiguredAuthCoordinator.shared
    public static let previewValue: AuthCoordinator = UnconfiguredAuthCoordinator.shared
}

public extension DependencyValues {
    var authCoordinator: AuthCoordinator {
        get { self[AuthCoordinatorKey.self] }
        set { self[AuthCoordinatorKey.self] = newValue }
    }
}

/// 라이브 구현이 미주입된 상태에서 호출이 일어나면 즉시 명시적 에러를 내는 sentinel.
///
/// ``AuthCoordinator`` 는 final 이라 상속할 수 없으므로, 같은 클래스를 ``NotConfigured*`` 종속물로 구성해 두어
/// 어떤 메서드를 호출하든 명시적 에러가 발생하도록 한다.
public enum UnconfiguredAuthCoordinator {
    public static let shared: AuthCoordinator = AuthCoordinator(
        store: AuthSessionStore(store: InMemoryTokenStore()),
        api: NotConfiguredAuthAPIClient(),
        apple: NotConfiguredAppleAuthClient(),
        google: NotConfiguredGoogleAuthClient()
    )
}

struct NotConfiguredAuthAPIClient: AuthAPIClient {
    private let error = AuthError.unknown(message: "AuthAPIClient not wired")
    func signInWithApple(_ body: AppleSignInBody) async throws -> AuthSession { throw error }
    func signInWithGoogle(_ body: GoogleSignInBody) async throws -> AuthSession { throw error }
    func signInAsDev(_ body: DevSignInBody) async throws -> AuthSession { throw error }
    func refresh(_ body: RefreshBody) async throws -> AuthTokens { throw error }
    func logout(_ body: LogoutBody) async throws { throw error }
    func getMe(accessToken: String) async throws -> AuthUser { throw error }
}

struct NotConfiguredAppleAuthClient: AppleAuthClient {
    @MainActor func authorize() async throws -> AppleRawCredential {
        throw AuthError.unknown(message: "AppleAuthClient not wired")
    }
}

struct NotConfiguredGoogleAuthClient: GoogleAuthClient {
    @MainActor func authorize() async throws -> GoogleRawCredential {
        throw AuthError.unknown(message: "GoogleAuthClient not wired")
    }
    @MainActor func handle(url: URL) -> Bool { false }
    @MainActor func restorePreviousSignIn() async -> GoogleRawCredential? { nil }
}
