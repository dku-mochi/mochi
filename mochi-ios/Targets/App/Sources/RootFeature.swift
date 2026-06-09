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

    enum Action: Sendable {
        case appLaunched
        case appBecameActive
        case sessionResolved(AuthSession?)
        case pendingMemoDiscovered(UUID)
        /// 분석완료 알림 탭 — 홈 버킷으로 라우팅(상세 딥링크는 server→local id 매핑 필요, 후속).
        case notificationTapped(UUID)
        case login(LoginFeature.Action)
        case main(MainTabFeature.Action)
        case requestSignOut
        case backTapModal(PresentationAction<BackTapModalFeature.Action>)
        case onboarding(PresentationAction<OnboardingFeature.Action>)
    }

    @Dependency(\.authCoordinator) var authCoordinator
    @Dependency(\.syncTrigger) var syncTrigger

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
                if state.backTapModal == nil, state.onboarding == nil {
                    return .merge(pull, Self.checkPendingMemo())
                }
                return pull

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

            case .notificationTapped:
                // 알림 탭 → 홈 탭으로. 항목 최신화는 scenePhase active reconcile(폴링/SSE 재구독)이 맡는다.
                state.main.selectedTab = .home
                return .none

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
                if state.backTapModal == nil {
                    return .merge(pull, Self.checkPendingMemo())
                }
                return pull

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
                if case .authenticated = state.phase, state.backTapModal == nil {
                    return Self.checkPendingMemo()
                }
                return .none

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
