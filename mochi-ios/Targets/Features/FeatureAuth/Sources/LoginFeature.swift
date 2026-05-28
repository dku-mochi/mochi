import ComposableArchitecture
import CoreAuth
import Foundation

/// 로그인 화면의 TCA Reducer.
///
/// **흐름:**
/// 1. View 가 Apple/Google 탭 → ``signInTapped(.apple)`` 또는 ``signInTapped(.google)`` 디스패치
/// 2. Reducer 가 ``inFlightProvider = provider`` 로 진행 중 상태를 마킹 → 버튼 비활성화
/// 3. ``.run`` effect 가 ``AuthCoordinator.signInWith*`` 호출 → 성공시 ``.signedIn`` 액션
/// 4. 부모 (RootFeature) 가 ``Delegate.signedIn`` 을 받아 메인 화면으로 분기
///
/// **취소 처리:** ``AuthError.canceled`` 는 alert 없이 조용히 무시 — UX 표준.
@Reducer
public struct LoginFeature: Sendable {

    public init() {}

    @ObservableState
    public struct State: Equatable, Sendable {
        public var inFlightProvider: AuthProviderKind?
        @Presents public var alert: AlertState<Action.Alert>?

        public init(inFlightProvider: AuthProviderKind? = nil, alert: AlertState<Action.Alert>? = nil) {
            self.inFlightProvider = inFlightProvider
            self.alert = alert
        }

        public var isBusy: Bool { inFlightProvider != nil }
    }

    public enum AuthProviderKind: String, Equatable, Sendable, CaseIterable {
        case apple
        case google
        /// 로컬 백엔드 (``environment=local``) 전용 임시 로그인. ``LoginView`` 의 DEBUG 빌드에서만 노출.
        case dev
    }

    public enum Action: Sendable {
        case signInTapped(AuthProviderKind)
        case signInFailed(AuthProviderKind, message: String)
        case alert(PresentationAction<Alert>)
        case delegate(Delegate)

        public enum Alert: Equatable, Sendable {}
        public enum Delegate: Equatable, Sendable {
            case signedIn(AuthSession)
        }
    }

    @Dependency(\.authCoordinator) var authCoordinator

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .signInTapped(provider):
                guard state.inFlightProvider == nil else { return .none }
                state.inFlightProvider = provider
                return .run { [authCoordinator] send in
                    do {
                        let session: AuthSession = switch provider {
                        case .apple:  try await authCoordinator.signInWithApple()
                        case .google: try await authCoordinator.signInWithGoogle()
                        case .dev:    try await authCoordinator.signInAsDev(subject: "jun")
                        }
                        await send(.delegate(.signedIn(session)))
                    } catch let error as AuthError {
                        if case .canceled = error {
                            // 사용자가 시트를 직접 닫음 — UX 알림 없이 조용히 종료.
                            await send(.signInFailed(provider, message: ""))
                        } else {
                            await send(.signInFailed(provider, message: error.userMessage))
                        }
                    } catch {
                        await send(.signInFailed(provider, message: error.localizedDescription))
                    }
                }

            case let .signInFailed(_, message):
                state.inFlightProvider = nil
                if !message.isEmpty {
                    state.alert = AlertState {
                        TextState("로그인에 실패했어요")
                    } actions: {
                        ButtonState(role: .cancel) { TextState("확인") }
                    } message: {
                        TextState(message)
                    }
                }
                return .none

            case .alert, .delegate:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }
}
