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
        /// 약관 미동의 상태에서 로그인 탭 시, 동의 모달을 띄울 대상 provider. nil = 모달 닫힘.
        public var consentProvider: AuthProviderKind?
        @Presents public var alert: AlertState<Action.Alert>?

        public init(
            inFlightProvider: AuthProviderKind? = nil,
            consentProvider: AuthProviderKind? = nil,
            alert: AlertState<Action.Alert>? = nil
        ) {
            self.inFlightProvider = inFlightProvider
            self.consentProvider = consentProvider
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
        /// 동의 모달에서 "동의하고 계속" — 동의를 저장하고 대기 중 provider 로 로그인을 이어 진행.
        case consentAgreed
        /// 동의 모달이 닫힘(취소·드래그 dismiss).
        case consentDismissed
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
                // 약관 명시 동의 게이트 — apple/google 은 동의 후에만 진행(한국 개인정보보호법: 묵시적
                // "동의 간주"는 명확한 동의로 인정받기 어려움). dev(DEBUG 전용)는 게이트 면제.
                guard provider == .dev || Self.hasAgreedToLegal else {
                    state.consentProvider = provider
                    return .none
                }
                state.consentProvider = nil
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

            case .consentAgreed:
                Self.hasAgreedToLegal = true
                guard let provider = state.consentProvider else { return .none }
                state.consentProvider = nil
                // 동의 모달 dismiss 와 로그인 시트(Apple/Google) present 가 겹치면 "presenting while
                // dismissing" 으로 로그인 시트가 안 뜰 수 있다. 시트 닫힘 애니메이션 후 진행한다.
                // (동의는 이미 저장됐으니 재진입 시 게이트를 통과해 실제 로그인으로 이어진다.)
                return .run { send in
                    try? await Task.sleep(for: .milliseconds(350))
                    await send(.signInTapped(provider))
                }

            case .consentDismissed:
                state.consentProvider = nil
                return .none

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

    // MARK: - 약관 동의 (기기 단위 1회)

    private static let legalConsentKey = "app.mochi.legalConsentAccepted"

    /// 이용약관·개인정보처리방침 명시 동의 여부. 한국 개인정보보호법상 "동의 간주"(묵시적)는 약해,
    /// 최초 로그인 전 동의 모달에서 명시적으로 받고 여기 저장한다(`UserDefaults` — 온보딩 완료 플래그와 동일 패턴).
    static var hasAgreedToLegal: Bool {
        get { UserDefaults.standard.bool(forKey: legalConsentKey) }
        set { UserDefaults.standard.set(newValue, forKey: legalConsentKey) }
    }
}
