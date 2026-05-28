import Foundation
import CoreNetworking

/// 인증 흐름의 단일 조정자.
///
/// **역할:**
/// - Apple/Google 시트 → 백엔드 sign-in → ``AuthSessionStore`` 업데이트
/// - 토큰 만료 시 refresh → 회전된 새 토큰 저장
/// - 로그아웃 → 백엔드 revoke 알림 + 로컬 토큰 삭제
/// - ``URLSessionMochiAPIClient`` 가 의존하는 ``AuthTokenProvider`` 도 함께 구현 — 모든 보호 호출이 자동으로 인증 헤더를 받는다.
public final class AuthCoordinator: AuthTokenProvider, @unchecked Sendable {
    private let store: AuthSessionStore
    private let api: any AuthAPIClient
    private let apple: any AppleAuthClient
    private let google: any GoogleAuthClient
    /// 동시 다발적인 refresh 요청을 1회로 합치는 lock + 단일 in-flight 작업 슬롯.
    /// Task 는 struct 라 ObjectIdentifier 가 안 되므로, install 시점에 UUID 를 같이 발급해 식별한다.
    private let refreshLock = NSLock()
    private var pendingRefresh: Task<AuthTokens, Error>?
    private var pendingRefreshID: UUID?

    public init(
        store: AuthSessionStore,
        api: any AuthAPIClient,
        apple: any AppleAuthClient,
        google: any GoogleAuthClient
    ) {
        self.store = store
        self.api = api
        self.apple = apple
        self.google = google
    }

    // MARK: - Public API

    public func currentSession() async -> AuthSession? {
        await store.current()
    }

    @MainActor
    public func signInWithApple() async throws -> AuthSession {
        let credential = try await apple.authorize()
        let session = try await api.signInWithApple(
            AppleSignInBody(
                identityToken: credential.identityToken,
                rawNonce: credential.rawNonce,
                fullName: credential.fullName,
                deviceLabel: Self.deviceLabel()
            )
        )
        try await store.update(session)
        return session
    }

    @MainActor
    public func signInWithGoogle() async throws -> AuthSession {
        let credential = try await google.authorize()
        let session = try await api.signInWithGoogle(
            GoogleSignInBody(
                idToken: credential.idToken,
                deviceLabel: Self.deviceLabel()
            )
        )
        try await store.update(session)
        return session
    }

    /// 백엔드 ``/auth/dev`` 호출 — local 환경 전용 임시 로그인.
    ///
    /// Apple/Google 시스템 시트 없이 ``subject`` 만으로 access/refresh JWT 를 발급받는다.
    /// 같은 subject 는 항상 같은 user 로 멱등 매핑된다 (백엔드 SHA-256 derivation).
    @MainActor
    public func signInAsDev(subject: String) async throws -> AuthSession {
        let session = try await api.signInAsDev(
            DevSignInBody(
                subject: subject,
                displayName: nil,
                deviceLabel: Self.deviceLabel()
            )
        )
        try await store.update(session)
        return session
    }

    public func signOut() async {
        if let session = await store.current() {
            // 베스트 에포트 — 네트워크 실패해도 로컬은 비운다.
            _ = try? await api.logout(LogoutBody(refreshToken: session.tokens.refreshToken))
        }
        try? await store.clear()
    }

    // MARK: - AuthTokenProvider

    public func bearerToken() async -> String? {
        if let token = await store.accessTokenIfValid() { return token }
        // 만료/없음 → refresh 시도
        do {
            let tokens = try await refreshIfNeeded()
            return tokens.accessToken
        } catch {
            return nil
        }
    }

    /// 401 응답 후 호출 — refresh 가 성공하면 새 access token 을 반환. 실패하면 throw.
    ///
    /// **단일 비행 보장 (codex review P1):** "snapshot → setPending" 두 단계가 분리되어 있으면
    /// 두 보호 요청이 동시에 만료를 보고 각자 refresh 를 시작해 rotating refresh token 한 장으로
    /// 두 번 호출 → 서버가 두 번째 호출을 reuse_detected 로 거부 → 정상 사용자도 로그아웃.
    /// 모든 lookup-or-install 을 하나의 lock scope 에서 처리해 race 를 닫는다.
    @discardableResult
    public func refreshIfNeeded() async throws -> AuthTokens {
        let task = installOrJoinRefreshTask()
        return try await task.value
    }

    private func installOrJoinRefreshTask() -> Task<AuthTokens, Error> {
        refreshLock.lock()
        if let inFlight = pendingRefresh {
            refreshLock.unlock()
            return inFlight
        }
        let identity = UUID()
        let task = Task<AuthTokens, Error> { [api, store] in
            guard let session = await store.current() else {
                throw AuthError.backendRejected(
                    code: "auth.refresh_not_found",
                    message: "No session"
                )
            }
            do {
                let tokens = try await api.refresh(
                    RefreshBody(
                        refreshToken: session.tokens.refreshToken,
                        deviceLabel: Self.deviceLabel()
                    )
                )
                try await store.updateTokens(tokens)
                return tokens
            } catch let error as AuthError {
                // refresh 실패 = 세션 종료. 로컬 토큰을 비워 다음 호출이 로그인 화면으로 가도록.
                if case .backendRejected = error {
                    try? await store.clear()
                }
                throw error
            }
        }
        pendingRefresh = task
        pendingRefreshID = identity
        refreshLock.unlock()

        // 작업 완료 시 같은 id 일 때만 비운다 — 두 번째 회전이 같은 슬롯을 덮어쓰면 새 작업을 보존.
        Task { [weak self] in
            _ = await task.result
            self?.clearPendingIfMatches(identity)
        }
        return task
    }

    private func clearPendingIfMatches(_ identity: UUID) {
        refreshLock.lock(); defer { refreshLock.unlock() }
        if pendingRefreshID == identity {
            pendingRefresh = nil
            pendingRefreshID = nil
        }
    }

    /// 진단용 라벨 — UIDevice 는 main isolation 이라 비동기 컨텍스트에서 끌어쓰기 까다롭다.
    /// 단순히 OS 정보 (sysctl 없이) 만 노출.
    private static let deviceLabelString: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        return "iOS \(version)"
    }()

    private static func deviceLabel() -> String { deviceLabelString }
}
