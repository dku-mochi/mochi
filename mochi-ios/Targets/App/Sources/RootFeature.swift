import Foundation
import ComposableArchitecture
import CoreAuth
import CorePersistence
import FeatureAuth
import FeatureMochiItem
import FeatureDetail
import FeatureInbox
import FeatureSearch
import FeatureSettings
import FeatureOnboarding

/// 앱 최상위 reducer — 인증 단계 ↔ 메인 탭 전환 + 백탭 메모 모달 presentation 을 담당.
///
/// **세션 부재**: ``LoginFeature`` 가 활성화되어 ``LoginView`` 가 보임.
/// **세션 존재**: ``MainTabFeature`` 가 활성화되어 ``RootView`` 가 보임.
///
/// **백탭 메모 모달 (2026-05-25 snippet pivot)**: 백탭의 캡쳐/메모 선택은 외부 앱 위의
/// snippet 카드가 담당하고, 메모 분기만 모찌 앱을 깨운다.
/// ``OpenBackTapMemoIntent.perform()`` 가 `pending-backtap/<captureID>.memo` marker 를 떨군 뒤
/// 모찌를 foreground 로 띄우면, 본 reducer 가 `.appBecameActive` 시점에 marker 를 발견해
/// ``BackTapModalFeature`` 를 메모 phase 로 띄운다.
///
/// **PNG 잔재 처리**: snippet 시스템 dismiss (사용자 외부 탭 / timeout) 시 ``CommitBackTapCaptureIntent``
/// · ``OpenBackTapMemoIntent`` 어느 것도 실행되지 않을 수 있어 PNG 잔재 가능. 본 reducer 가
/// scan 시점에 stale `.png` 를 모두 폐기 (snippet 흐름에서 PNG 는 commit 직후에만 의미).
///
/// **미인증**: 모달은 인증된 상태에서만 띄우고 marker 는 폐기하지 않는다 — 로그인 후 다음
/// active 시점에 다시 검사.
@Reducer
struct RootFeature: Sendable {
    @ObservableState
    struct State: Equatable, Sendable {
        var phase: Phase
        var login: LoginFeature.State
        var main: MainTabFeature.State
        @Presents var backTapModal: BackTapModalFeature.State?
        @Presents var onboarding: OnboardingFeature.State?
        /// 미인증·리졸빙 단계에 도착해 큐잉된 알림 라우트 — `.authenticated` 전이 시 flush (콜드 스타트 딥링크 유실 방지).
        /// 단일 슬롯(last-wins): 인증 전 여러 번 탭하면 마지막 의도만 연다(알림 탭은 보통 마지막이 의도).
        var pendingNotificationRoute: NotificationRoute? = nil

        init(
            phase: Phase = .resolving,
            login: LoginFeature.State = .init(),
            main: MainTabFeature.State = .init(),
            backTapModal: BackTapModalFeature.State? = nil,
            onboarding: OnboardingFeature.State? = nil
        ) {
            self.phase = phase
            self.login = login
            self.main = main
            self.backTapModal = backTapModal
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
        case pendingMemoDiscovered(UUID)
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
        case backTapModal(PresentationAction<BackTapModalFeature.Action>)
        case onboarding(PresentationAction<OnboardingFeature.Action>)
    }

    @Dependency(\.authCoordinator) var authCoordinator
    @Dependency(\.syncTrigger) var syncTrigger
    @Dependency(\.pushAuthorization) var pushAuthorization

    var body: some ReducerOf<Self> {
        Scope(state: \.login, action: \.login) { LoginFeature() }
        Scope(state: \.main,  action: \.main)  { MainTabFeature() }

        Reduce { state, action in
            switch action {
            case .appLaunched:
                if !Self.hasCompletedOnboarding {
                    state.onboarding = OnboardingFeature.State()
                }
                return .merge(
                    .run { [authCoordinator] send in
                        let session = await authCoordinator.currentSession()
                        await send(.sessionResolved(session))
                    },
                    Self.sweepStalePNGs()
                )

            case .appBecameActive:
                let sweep = Self.sweepStalePNGs()
                if case .authenticated = state.phase, state.backTapModal == nil, state.onboarding == nil {
                    return .merge(sweep, Self.checkPendingMemo())
                }
                return sweep

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
                if state.backTapModal == nil, state.onboarding == nil {
                    return .merge(pull, ensureCapture, Self.checkPendingMemo(), push, route)
                }
                return .merge(pull, ensureCapture, push, route)

            case let .pendingMemoDiscovered(captureID):
                // 활성 모달이 같은 captureID 면 (concurrent discovery — sessionResolved +
                // appBecameActive 가 거의 동시 발사된 경우) 무시. 이미 처리 중.
                if state.backTapModal?.captureID == captureID {
                    return .none
                }
                // 활성 모달이 다른 captureID 라면 새 marker 는 다음 dismiss 후 다시 검사.
                guard state.backTapModal == nil else { return .none }
                state.backTapModal = .init(captureID: captureID)
                return .none

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
                return .send(.main(.openDetailFromNotification(serverID: serverID, hero: nil)))

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

            case .backTapModal(.presented(.delegate(.dismiss))):
                state.backTapModal = nil
                return .none

            case .backTapModal(.dismiss):
                // 외부 강제 dismiss 안전망. 자식 reducer 가 폐기 책임을 다하지 못한 채 모달이
                // 사라지는 경로 (시스템 강제, 부모가 nil 할당 등) 에서도 marker 누수가 없도록.
                // 정상 분기 (저장 / 취소) 는 자식이 이미 폐기하므로 이중 삭제는 try? 로 무해.
                if let backTap = state.backTapModal {
                    let url = AppGroup.pendingBackTapDirectoryURL
                        .appendingPathComponent(
                            AppGroup.pendingBackTapMemoFilename(captureID: backTap.captureID.uuidString)
                        )
                    try? FileManager.default.removeItem(at: url)
                }
                return .none

            case let .login(.delegate(.signedIn(session))):
                state.phase = .authenticated(session)
                state.login = .init()
                // 새 로그인 직후 서버→로컬 복구 — 재설치 후 같은 계정의 기록을 끌어온다.
                let pull = Effect<Action>.run { [syncTrigger] _ in await syncTrigger.pullRemote() }
                // 로그인 직후 푸시 권한 팝업 — 온보딩 중이면 완료 시점으로 미룬다.
                let push = state.onboarding == nil ? Self.requestPush(pushAuthorization) : Effect<Action>.none
                // 로그인 화면에서 알림을 탭해 큐잉된 라우트가 있으면 인증 직후 흘린다.
                let route = Self.flushPendingNotificationRoute(&state)
                if state.backTapModal == nil {
                    return .merge(pull, Self.checkPendingMemo(), push, route)
                }
                return .merge(pull, push, route)

            case .requestSignOut:
                return .run { [authCoordinator] send in
                    await authCoordinator.signOut()
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
                let push = Self.requestPush(pushAuthorization)
                if state.backTapModal == nil {
                    return .merge(Self.checkPendingMemo(), push)
                }
                return push

            case .onboarding(.dismiss):
                state.onboarding = nil
                return .none

            case .backTapModal, .onboarding, .login, .main:
                return .none
            }
        }
        .ifLet(\.$backTapModal, action: \.backTapModal) { BackTapModalFeature() }
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
            return .send(.main(.openDetailFromNotification(serverID: serverID, hero: nil)))
        case let .recallLanding(recallEventID):
            return .send(.main(.openRecallLandingFromNotification(recallEventID: recallEventID)))
        }
    }

    /// 인증 시점 푸시 권한 팝업 요청 효과. requester 는 reducer 의 `@Dependency` 에서 캡처해 넘긴다.
    private static func requestPush(_ requester: any PushAuthorizationRequesting) -> Effect<Action> {
        .run { _ in await requester.requestIfNeeded() }
    }

    /// pending-backtap 디렉터리에서 `.memo` marker 가장 최근 한 장을 탐지해 captureID 발사.
    /// 잔재 marker (여러 장 누적) 는 가장 최신 한 장만 사용하고 나머지는 stale 로 폐기.
    private static func checkPendingMemo() -> Effect<Action> {
        .run { send in
            let dir = AppGroup.pendingBackTapDirectoryURL
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            let markers = files.filter { $0.pathExtension == "memo" }
            guard !markers.isEmpty else { return }
            let sorted = markers.sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
            for stale in sorted.dropFirst() {
                try? FileManager.default.removeItem(at: stale)
            }
            guard let latest = sorted.first else { return }
            // 파일명에서 captureID 추출. `<UUID>.memo` 컨벤션이라 deletingPathExtension().lastPathComponent.
            let base = latest.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: base) else {
                // 비정상 파일명. 폐기하고 종료.
                try? FileManager.default.removeItem(at: latest)
                return
            }
            await send(.pendingMemoDiscovered(id))
        }
    }

    /// pending-backtap 디렉터리의 **stale** `.png` 잔재만 폐기 (TTL 10분).
    ///
    /// snippet 흐름에서 PNG 는 commit 직후 (캡쳐 분기) 또는 marker stash 직전 (메모 분기) 에만 의미를
    /// 가진다. 양 commit intent 중 어느 것도 실행되지 않은 채 시간이 지난 PNG 는 stale — 청소 대상.
    ///
    /// **TTL 의 race-guard 역할**: snippet 카드가 외부 앱 위에 떠 있는 동안 모찌 본체가 어떤 이유로
    /// active 가 되면 (`.appBecameActive` 발사) 이 함수가 호출된다. TTL 없이 모든 `.png` 를 삭제하면
    /// **활성 snippet 의 PNG 까지 폐기**되어 사용자가 "캡쳐" 탭한 시점에
    /// `CommitBackTapCaptureIntent` 가 파일을 못 읽고 silent data loss 가 발생한다. 10분 TTL 로
    /// 최근 PNG 는 보호. 캡쳐 자체가 자주 일어나는 행위가 아니라 더 짧게 잡을 이유 없음.
    private static func sweepStalePNGs() -> Effect<Action> {
        .run { _ in
            let dir = AppGroup.pendingBackTapDirectoryURL
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            let staleThreshold = Date().addingTimeInterval(-Self.pendingPNGTTLSeconds)
            for url in files where url.pathExtension == "png" {
                let modDate = (try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                // 활성 PNG (snippet 이 들고 있을 가능성) 는 보호 — race-guard.
                guard modDate < staleThreshold else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// `sweepStalePNGs` 의 TTL. 이보다 새 PNG 는 활성 snippet 의 stash 일 가능성이 있어 보호.
    private static let pendingPNGTTLSeconds: TimeInterval = 600
    private static let onboardingCompletedKey = "app.mochi.onboardingCompleted"
}
