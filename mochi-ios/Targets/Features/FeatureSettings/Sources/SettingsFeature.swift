import Foundation
import ComposableArchitecture
import CoreDomain

@Reducer
public struct SettingsFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        public var serverEndpoint: String = "https://api.mochi.local/api/v1"
        public var calendarSyncEnabled: Bool = true
        public var reminderSyncEnabled: Bool = true
        public init() {}
    }

    public enum Action: BindableAction, Sendable {
        case binding(BindingAction<State>)
        case onboardingButtonTapped
        case logoutButtonTapped
        case delegate(Delegate)

        public enum Delegate: Equatable, Sendable {
            case onboardingRequested
            /// 로그아웃 요청 — 실제 세션 해제(토큰 revoke + 로컬 clear)는 상위
            /// ``RootFeature.requestSignOut`` 이 수행한다. 여기선 신호만 올린다.
            case logoutRequested
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { _, action in
            switch action {
            case .onboardingButtonTapped:
                return .send(.delegate(.onboardingRequested))
            case .logoutButtonTapped:
                return .send(.delegate(.logoutRequested))
            case .binding, .delegate:
                return .none
            }
        }
    }
}
