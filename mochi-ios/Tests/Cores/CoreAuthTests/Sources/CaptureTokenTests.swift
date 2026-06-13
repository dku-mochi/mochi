import XCTest
@testable import CoreAuth

/// capture token 발급·보관 흐름의 단위 테스트.
///
/// 중점:
/// - ``AuthCoordinator/ensureCaptureToken()`` 의 4분기 — 발급 / 스킵(유효) /
///   재발급(계정 불일치 — cross-account 오염 방지 불변식) / 재발급(만료 임박)
/// - ``AuthCoordinator/signOut()`` 이 capture token 을 logout 바디에 동봉하고 로컬을 비우는지
final class CaptureTokenTests: XCTestCase {
    // MARK: - Fakes

    /// 호출 기록 + 카운터 기반 발급 응답을 주는 fake.
    final class FakeAuthAPIClient: AuthAPIClient, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var issueCalls: [CaptureTokenBody] = []
        private(set) var logoutBodies: [LogoutBody] = []
        private var counter = 0
        var issueError: Error?

        func issueCaptureToken(
            _ body: CaptureTokenBody,
            accessToken: String
        ) async throws -> CaptureTokenIssued {
            lock.lock(); defer { lock.unlock() }
            if let issueError { throw issueError }
            issueCalls.append(body)
            counter += 1
            return CaptureTokenIssued(
                captureToken: "mct_test-\(counter)",
                captureTokenExpiresAt: Date().addingTimeInterval(180 * 24 * 3600)
            )
        }

        func logout(_ body: LogoutBody) async throws {
            lock.lock(); defer { lock.unlock() }
            logoutBodies.append(body)
        }

        func signInWithApple(_ body: AppleSignInBody) async throws -> AuthSession {
            throw AuthError.unknown(message: "unused")
        }
        func signInWithGoogle(_ body: GoogleSignInBody) async throws -> AuthSession {
            throw AuthError.unknown(message: "unused")
        }
        func signInAsDev(_ body: DevSignInBody) async throws -> AuthSession {
            throw AuthError.unknown(message: "unused")
        }
        func refresh(_ body: RefreshBody) async throws -> AuthTokens {
            throw AuthError.unknown(message: "unused")
        }
        func getMe(accessToken: String) async throws -> AuthUser {
            throw AuthError.unknown(message: "unused")
        }
    }

    struct StubAppleAuthClient: AppleAuthClient {
        @MainActor func authorize() async throws -> AppleRawCredential {
            throw AuthError.unknown(message: "unused")
        }
    }

    struct StubGoogleAuthClient: GoogleAuthClient {
        @MainActor func authorize() async throws -> GoogleRawCredential {
            throw AuthError.unknown(message: "unused")
        }
        @MainActor func handle(url: URL) -> Bool { false }
        @MainActor func restorePreviousSignIn() async -> GoogleRawCredential? { nil }
    }

    // MARK: - Helpers

    private let userID = UUID()

    private func makeSession(userID: UUID? = nil) -> AuthSession {
        AuthSession(
            user: AuthUser(
                id: userID ?? self.userID,
                email: "u@mochi.app",
                displayName: "u",
                locale: "ko-KR",
                onboardingCompletedAt: nil
            ),
            tokens: AuthTokens(
                accessToken: "access-valid",
                accessTokenExpiresAt: Date().addingTimeInterval(3600),
                refreshToken: "refresh-valid",
                refreshTokenExpiresAt: Date().addingTimeInterval(30 * 24 * 3600)
            ),
            isNewUser: false
        )
    }

    private func makeCoordinator(
        session: AuthSession?,
        captureStore: InMemoryCaptureTokenStore,
        api: FakeAuthAPIClient
    ) -> AuthCoordinator {
        AuthCoordinator(
            store: AuthSessionStore(store: InMemoryTokenStore(initial: session)),
            api: api,
            apple: StubAppleAuthClient(),
            google: StubGoogleAuthClient(),
            captureStore: captureStore
        )
    }

    // MARK: - ensureCaptureToken

    func test_ensure_issues_and_saves_when_no_record() async throws {
        let api = FakeAuthAPIClient()
        let captureStore = InMemoryCaptureTokenStore()
        let coordinator = makeCoordinator(session: makeSession(), captureStore: captureStore, api: api)

        await coordinator.ensureCaptureToken()

        XCTAssertEqual(api.issueCalls.count, 1)
        let record = try XCTUnwrap(captureStore.load())
        XCTAssertEqual(record.token, "mct_test-1")
        XCTAssertEqual(record.userID, userID)
    }

    func test_ensure_skips_when_valid_record_for_same_user() async throws {
        let api = FakeAuthAPIClient()
        let captureStore = InMemoryCaptureTokenStore(
            initial: CaptureTokenRecord(
                token: "mct_existing",
                expiresAt: Date().addingTimeInterval(180 * 24 * 3600),
                userID: userID
            )
        )
        let coordinator = makeCoordinator(session: makeSession(), captureStore: captureStore, api: api)

        await coordinator.ensureCaptureToken()

        XCTAssertEqual(api.issueCalls.count, 0)
        XCTAssertEqual(try captureStore.load()?.token, "mct_existing")
    }

    func test_ensure_reissues_when_record_belongs_to_other_user() async throws {
        // 로그아웃 없는 계정 전환 — 이전 계정 토큰이 남으면 이전 계정 명의로 업로드된다.
        let api = FakeAuthAPIClient()
        let captureStore = InMemoryCaptureTokenStore(
            initial: CaptureTokenRecord(
                token: "mct_other-user",
                expiresAt: Date().addingTimeInterval(180 * 24 * 3600),
                userID: UUID()
            )
        )
        let coordinator = makeCoordinator(session: makeSession(), captureStore: captureStore, api: api)

        await coordinator.ensureCaptureToken()

        XCTAssertEqual(api.issueCalls.count, 1)
        let record = try XCTUnwrap(captureStore.load())
        XCTAssertEqual(record.userID, userID)
        XCTAssertNotEqual(record.token, "mct_other-user")
    }

    func test_ensure_reissues_when_expiring_within_lead_time() async throws {
        // 잔여 < 30일 → 선제 재발급 (sliding 의 로컬 최소 보장이 닳기 전에 갱신).
        let api = FakeAuthAPIClient()
        let captureStore = InMemoryCaptureTokenStore(
            initial: CaptureTokenRecord(
                token: "mct_stale",
                expiresAt: Date().addingTimeInterval(10 * 24 * 3600),
                userID: userID
            )
        )
        let coordinator = makeCoordinator(session: makeSession(), captureStore: captureStore, api: api)

        await coordinator.ensureCaptureToken()

        XCTAssertEqual(api.issueCalls.count, 1)
        XCTAssertNotEqual(try captureStore.load()?.token, "mct_stale")
    }

    func test_ensure_noop_without_session() async throws {
        let api = FakeAuthAPIClient()
        let captureStore = InMemoryCaptureTokenStore()
        let coordinator = makeCoordinator(session: nil, captureStore: captureStore, api: api)

        await coordinator.ensureCaptureToken()

        XCTAssertEqual(api.issueCalls.count, 0)
        XCTAssertNil(try captureStore.load())
    }

    func test_ensure_keeps_same_user_record_when_issue_fails() async throws {
        // best-effort — **같은 계정의** 레코드는 발급 실패 시 지우지 않는다 (ShareExt 가 계속 쓸 수 있게).
        let api = FakeAuthAPIClient()
        api.issueError = AuthError.network(message: "offline")
        let stale = CaptureTokenRecord(
            token: "mct_stale",
            expiresAt: Date().addingTimeInterval(10 * 24 * 3600),
            userID: userID
        )
        let captureStore = InMemoryCaptureTokenStore(initial: stale)
        let coordinator = makeCoordinator(session: makeSession(), captureStore: captureStore, api: api)

        await coordinator.ensureCaptureToken()

        XCTAssertEqual(try captureStore.load(), stale)
    }

    func test_ensure_clears_other_user_record_even_when_issue_fails() async throws {
        // cross-account 오염 차단 (codex review P1) — 다른 계정의 레코드는 재발급 시도 *전에*
        // 폐기한다. 발급이 실패해도 이전 계정 토큰이 남아선 안 된다.
        let api = FakeAuthAPIClient()
        api.issueError = AuthError.network(message: "offline")
        let captureStore = InMemoryCaptureTokenStore(
            initial: CaptureTokenRecord(
                token: "mct_other-user",
                expiresAt: Date().addingTimeInterval(180 * 24 * 3600),
                userID: UUID()
            )
        )
        let coordinator = makeCoordinator(session: makeSession(), captureStore: captureStore, api: api)

        await coordinator.ensureCaptureToken()

        XCTAssertNil(try captureStore.load())
    }

    // MARK: - signOut

    func test_signout_bundles_capture_token_and_clears_store() async throws {
        let api = FakeAuthAPIClient()
        let captureStore = InMemoryCaptureTokenStore(
            initial: CaptureTokenRecord(
                token: "mct_to-revoke",
                expiresAt: Date().addingTimeInterval(180 * 24 * 3600),
                userID: userID
            )
        )
        let coordinator = makeCoordinator(session: makeSession(), captureStore: captureStore, api: api)

        await coordinator.signOut()

        XCTAssertEqual(api.logoutBodies.count, 1)
        XCTAssertEqual(api.logoutBodies.first?.captureToken, "mct_to-revoke")
        XCTAssertNil(try captureStore.load())
    }

    func test_signout_without_capture_token_sends_nil() async throws {
        let api = FakeAuthAPIClient()
        let captureStore = InMemoryCaptureTokenStore()
        let coordinator = makeCoordinator(session: makeSession(), captureStore: captureStore, api: api)

        await coordinator.signOut()

        XCTAssertEqual(api.logoutBodies.count, 1)
        XCTAssertNil(api.logoutBodies.first?.captureToken)
    }
}
