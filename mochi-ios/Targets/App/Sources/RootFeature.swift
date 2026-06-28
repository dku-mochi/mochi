import Foundation
import ComposableArchitecture
import CoreAuth
import CoreNetworking
import CorePersistence
import FeatureAuth
import FeatureDetail
import FeatureInbox
import FeatureSearch
import FeatureSettings
import FeatureOnboarding

/// 앱 최상위 reducer — 인증 단계 ↔ 메인 탭 전환 + 온보딩 presentation 을 담당.
///
/// **세션 부재**: ``LoginFeature`` 가 활성화되어 ``LoginView`` 가 보임.
/// **세션 존재**: ``MainTabFeature`` 가 활성화되어 ``RootView`` 가 보임.
@Reducer
struct RootFeature: Sendable {
    @ObservableState
    struct State: Equatable, Sendable {
        var phase: Phase
        var login: LoginFeature.State
        var main: MainTabFeature.State
        @Presents var onboarding: OnboardingFeature.State?
        /// 미인증·리졸빙 단계에 도착해 큐잉된 알림 라우트 — `.authenticated` 전이 시 flush (콜드 스타트 딥링크 유실 방지).
        /// 단일 슬롯(last-wins): 인증 전 여러 번 탭하면 마지막 의도만 연다(알림 탭은 보통 마지막이 의도).
        var pendingNotificationRoute: NotificationRoute? = nil

        init(
            phase: Phase = .resolving,
            login: LoginFeature.State = .init(),
            main: MainTabFeature.State = .init(),
            onboarding: OnboardingFeature.State? = nil
        ) {
            self.phase = phase
            self.login = login
            self.main = main
            self.onboarding = onboarding
        }
    }

    enum Phase: Equatable, Sendable {
        /// 부팅 직후 — Keychain 에서 세션 로드 결과 대기
        case resolving
        case unauthenticated
        case authenticated(AuthSession)
    }

    /// 알림 탭으로 받았으나 인증 전(리졸빙/로그인)이라 즉시 처리 못 한 라우트. `.authenticated` 전이 시 flush.
    enum NotificationRoute: Equatable, Sendable {
        case detail(serverID: UUID)
        case recallLanding(recallEventID: UUID)
    }

    enum Action: Sendable {
        case appLaunched
        case appBecameActive
        case sessionResolved(AuthSession?)
        /// 분석완료 알림 탭 — 해당 항목 상세를 연다. 인자는 server PK(server→local 역매핑은 MainTab 이 수행).
        case notificationTapped(UUID)
        /// 능동 회수 알림 탭 — ③ 회수 상세로 직행한다. recallEventID 로 단건 entry 를 서버 fetch 해
        /// 렌더(빈 상세 금지). landing 은 회수 목록·상세로 착지(ux-decision §4·§5).
        case recallNotificationTapped(recallEventID: UUID)
        /// foreground 완료 푸시 수신(탭 아님) — 폴링 tick 을 기다리지 않고 그 항목을 즉시 reconcile 한다.
        /// 인자는 server PK. 반영은 observeChanges 로 열린 상세·홈에 전파(별도 화면 전환 없음).
        case analysisPushReceived(UUID)
        case login(LoginFeature.Action)
        case main(MainTabFeature.Action)
        case requestSignOut
        case onboarding(PresentationAction<OnboardingFeature.Action>)
    }

    @Dependency(\.authCoordinator) var authCoordinator
    @Dependency(\.syncTrigger) var syncTrigger
    @Dependency(\.pushAuthorization) var pushAuthorization
    @Dependency(\.mochiItemRepository) var mochiItemRepository

    var body: some ReducerOf<Self> {
        Scope(state: \.login, action: \.login) { LoginFeature() }
        Scope(state: \.main,  action: \.main)  { MainTabFeature() }

        Reduce { state, action in
            switch action {
            case .appLaunched:
                if !Self.hasCompletedOnboarding {
                    state.onboarding = OnboardingFeature.State()
                }
                return .run { [authCoordinator] send in
                    let session = await authCoordinator.currentSession()
                    await send(.sessionResolved(session))
                }

            case .appBecameActive:
                return .none

            case let .sessionResolved(session):
                state.phase = session.map(Phase.authenticated) ?? .unauthenticated
                guard session != nil else { return .none }
                // 세션 복원(자동 로그인) 직후 서버→로컬 복구 — 재설치 후 사라진 기록을 끌어온다.
                let pull = Effect<Action>.run { [syncTrigger] _ in await syncTrigger.pullRemote() }
                // ShareExt 직접 전송용 capture token 보장 — 부재·계정 불일치·만료 임박이면
                // 재발급 (로그인 경로는 coordinator 가 내부에서 처리, 여기는 복원 경로).
                let ensureCapture = Effect<Action>.run { [authCoordinator] _ in
                    await authCoordinator.ensureCaptureToken()
                }
                // 인증 확정 후에만 푸시 권한 팝업 — 온보딩 중이면 완료 시점(.onboarding finished)으로 미룬다.
                let push = state.onboarding == nil ? Self.requestPush(pushAuthorization) : Effect<Action>.none
                // 콜드 스타트에 큐잉된 알림 라우트를 이제(MainTab 마운트·auth 준비) 흘린다.
                let route = Self.flushPendingNotificationRoute(&state)
                return .merge(pull, ensureCapture, push, route)

            case let .notificationTapped(serverID):
                // 알림 탭 → 홈 탭 + 해당 항목 상세 present. 단 인증 전(리졸빙/로그인 화면)에 도착하면
                // MainTab 이 아직 마운트되지 않아 zoom present 가 유실되고(ZoomDetailPresentation
                // host.view.window == nil 가드) pullRemote(재설치 항목 회수)도 auth 미준비라 못 돈다 —
                // 큐잉했다가 `.authenticated` 전이에서 flush 한다(콜드 스타트 딥링크 유실 수정).
                guard case .authenticated = state.phase else {
                    state.pendingNotificationRoute = .detail(serverID: serverID)
                    return .none
                }
                state.main.selectedTab = .home
                return .send(.main(.openDetailFromNotification(serverID: serverID, hero: nil, source: .notification)))

            case let .recallNotificationTapped(recallEventID):
                // 회수 알림 탭 → 홈 탭 + ③ 회수 상세 직행. 인증 전 도착은 동일하게 큐잉한다 —
                // recallLanding 은 네트워크 fetch 라 auth 미준비면 401 로 빈손이 된다(콜드 스타트 수정).
                guard case .authenticated = state.phase else {
                    state.pendingNotificationRoute = .recallLanding(recallEventID: recallEventID)
                    return .none
                }
                state.main.selectedTab = .home
                return .send(.main(.openRecallLandingFromNotification(recallEventID: recallEventID)))

            case let .analysisPushReceived(serverID):
                // foreground 완료 푸시 — 화면 전환 없이 그 항목만 즉시 가져온다. 열린 상세(observeChanges)
                // 와 홈/검색이 따라서 갱신된다. 폴링은 fallback 으로 그대로 둔다(항목별 폴링은 반영되면 자동 종료).
                return .run { [syncTrigger] _ in await syncTrigger.reconcile(serverID: serverID) }

            case let .login(.delegate(.signedIn(session))):
                state.phase = .authenticated(session)
                state.login = .init()
                // 새 로그인 직후 서버→로컬 복구 — 재설치 후 같은 계정의 기록을 끌어온다.
                let pull = Effect<Action>.run { [syncTrigger] _ in await syncTrigger.pullRemote() }
                // 로그인 직후 푸시 권한 팝업 — 온보딩 중이면 완료 시점으로 미룬다.
                let push = state.onboarding == nil ? Self.requestPush(pushAuthorization) : Effect<Action>.none
                // 로그인 화면에서 알림을 탭해 큐잉된 라우트가 있으면 인증 직후 흘린다.
                let route = Self.flushPendingNotificationRoute(&state)
                return .merge(pull, push, route)

            case .requestSignOut:
                return .run { [authCoordinator, mochiItemRepository] send in
                    await authCoordinator.signOut()
                    // 계정 전환 시 이전 사용자 데이터 잔존 방지 — 로컬 Realm + 캡처 이미지를 비운다.
                    // Realm 은 단일 파일·사용자 미분리라 로그아웃 때 비우지 않으면 재로그인 후 이전 계정
                    // 기록이 그대로 남아 새 계정 데이터와 혼재된다(프라이버시 사고). signOut 으로 토큰을
                    // 먼저 무효화한 뒤 지우므로, 진행 중이던 pull 이 있어도 401 로 멈춰 재오염되지 않는다.
                    try? await mochiItemRepository.deleteAll()
                    AppGroup.clearCapturedImages()
                    await send(.sessionResolved(nil))
                }

            case .main(.delegate(.logoutRequested)):
                return .send(.requestSignOut)

            case .main(.delegate(.onboardingRequested)):
                state.onboarding = OnboardingFeature.State()
                return .none

            case .onboarding(.presented(.delegate(.finished))):
                Self.hasCompletedOnboarding = true
                state.onboarding = nil
                // 온보딩(회수 가치 설명)을 막 마친 인증 사용자에게 푸시 권한 요청 — 가치 경험 직후가 거부율 최저.
                guard case .authenticated = state.phase else { return .none }
                return Self.requestPush(pushAuthorization)

            case .onboarding(.dismiss):
                state.onboarding = nil
                return .none

            case .onboarding, .login, .main:
                return .none
            }
        }
        .ifLet(\.$onboarding, action: \.onboarding) { OnboardingFeature() }
    }

    private static var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: onboardingCompletedKey) }
        set { UserDefaults.standard.set(newValue, forKey: onboardingCompletedKey) }
    }

    /// 큐잉된 알림 라우트를 흘린다 — `.authenticated` 인 경우에만. MainTab 마운트·auth 준비 후 호출해
    /// 콜드 스타트 딥링크가 유실되지 않게 한다. server→local 역매핑·fetch·재시도는 MainTab effect 담당.
    private static func flushPendingNotificationRoute(_ state: inout State) -> Effect<Action> {
        guard case .authenticated = state.phase, let route = state.pendingNotificationRoute else {
            return .none
        }
        state.pendingNotificationRoute = nil
        state.main.selectedTab = .home
        switch route {
        case let .detail(serverID):
            return .send(.main(.openDetailFromNotification(serverID: serverID, hero: nil, source: .notification)))
        case let .recallLanding(recallEventID):
            return .send(.main(.openRecallLandingFromNotification(recallEventID: recallEventID)))
        }
    }

    /// 인증 시점 푸시 권한 팝업 요청 효과. requester 는 reducer 의 `@Dependency` 에서 캡처해 넘긴다.
    private static func requestPush(_ requester: any PushAuthorizationRequesting) -> Effect<Action> {
        .run { _ in await requester.requestIfNeeded() }
    }

    private static let onboardingCompletedKey = "app.mochi.onboardingCompleted"
}
