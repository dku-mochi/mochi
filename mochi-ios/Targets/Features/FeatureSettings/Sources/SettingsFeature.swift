import Foundation
import ComposableArchitecture
import CoreDomain
import CorePersistence

@Reducer
public struct SettingsFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        public var serverEndpoint: String = "https://api.mochi.local/api/v1"
        public var calendarSyncEnabled: Bool = true
        public var reminderSyncEnabled: Bool = true
        /// "전체 동기화" 진행 중 — 버튼에 스피너 표시 + 중복 탭 차단.
        public var isSyncing: Bool = false
        public init() {}
    }

    public enum Action: BindableAction, Sendable {
        case binding(BindingAction<State>)
        case onboardingButtonTapped
        case logoutButtonTapped
        /// 사용자가 "전체 동기화" 탭 — 서버→로컬 복구를 수동 트리거(재설치 복구의 보조 수단).
        case syncAllTapped
        case syncCompleted
        case delegate(Delegate)

        public enum Delegate: Equatable, Sendable {
            case onboardingRequested
            /// 로그아웃 요청 — 실제 세션 해제(토큰 revoke + 로컬 clear)는 상위
            /// ``RootFeature.requestSignOut`` 이 수행한다. 여기선 신호만 올린다.
            case logoutRequested
        }
    }

    @Dependency(\.syncTrigger) var syncTrigger

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .onboardingButtonTapped:
                return .send(.delegate(.onboardingRequested))
            case .logoutButtonTapped:
                return .send(.delegate(.logoutRequested))
            case .syncAllTapped:
                guard !state.isSyncing else { return .none }
                state.isSyncing = true
                return .run { send in
                    await syncTrigger.pullRemote()
                    await send(.syncCompleted)
                }
            case .syncCompleted:
                state.isSyncing = false
                return .none
            case .binding, .delegate:
                return .none
            }
        }
    }
}
