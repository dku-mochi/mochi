import Foundation

/// Sign in with Google 흐름의 추상 진입점.
///
/// **Live 구현이 ``LiveGoogleAuthClient`` 가 App 타겟에 있는 이유:**
/// GoogleSignIn-iOS 의 Package.swift 는 ``AppAuthCore`` 를 product 의존성에 명시하지 않고
/// ``AppAuth`` 만 link 한다. 그래서 GoogleSignIn 을 하위 framework (CoreAuth) 에서 import 하면
/// AppAuthCore 의 ObjC 클래스(``OIDAuthState`` 등) 가 undefined symbol 로 남는다
/// (google/GoogleSignIn-iOS#408, tuist/tuist#6360 의 알려진 트레이드오프).
///
/// 그래서 **App 타겟 (최상위 binary) 에서만 GoogleSignIn 을 link** 하고, CoreAuth 는 protocol 만
/// 제공한다. ``AppDependencies.bootstrap()`` 가 App 타겟의 ``LiveGoogleAuthClient`` 를 주입한다.
public protocol GoogleAuthClient: Sendable {
    @MainActor func authorize() async throws -> GoogleRawCredential

    /// `application(_:open:options:)` 또는 SceneDelegate openURLContexts 에서 호출.
    @MainActor @discardableResult
    func handle(url: URL) -> Bool

    /// 앱 부팅 시 호출 — 이전 세션을 복원할 수 있으면 ID Token 까지 추출. 실패시 nil 반환.
    @MainActor func restorePreviousSignIn() async -> GoogleRawCredential?
}
