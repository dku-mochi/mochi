import ComposableArchitecture
import Foundation

/// 가입 직후 노출되는 4단계 튜토리얼.
///
/// 시안 (`docs/PRODUCT.md §8.3`) 의 4 페이지를 순서대로 보여주고, 마지막 페이지에서
/// 사용자가 "다음" 을 누르면 ``Delegate.finished`` 를 발행해 부모 (App 또는 RootFeature)
/// 가 메인 흐름으로 전이하도록 한다.
///
/// 백탭 페이지의 "단축어 등록하기" 는 ``Action.openShortcutsApp`` 으로 위임되어
/// View 가 `Environment(\.openURL)` 로 `shortcuts://` 를 호출한다 (Reducer 가 URL 을
/// 직접 열지 않는 이유: TCA effect 에서 UIApplication 접근은 테스트가 어렵다).
@Reducer
public struct OnboardingFeature: Sendable {

    public init() {}

    @ObservableState
    public struct State: Equatable, Sendable {
        public var currentPage: Int
        /// 마지막 페이지의 CTA 가 눌리면 true. 부모 View 가 `onChange` 로 감시해
        /// 메인 흐름으로 전이한다. `delegate(.finished)` 와 동일 사건을 이중으로 표현하는 이유:
        /// TCA View 에서 action 자체를 직접 구독하기 어려우므로 observable state 로도 노출.
        public var isFinished: Bool

        public init(currentPage: Int = 0, isFinished: Bool = false) {
            self.currentPage = currentPage
            self.isFinished = isFinished
        }

        public var isLastPage: Bool { currentPage >= OnboardingPage.allCases.count - 1 }

        public var currentSpec: OnboardingPage { OnboardingPage.allCases[currentPage] }
    }

    public enum Action: Sendable {
        case nextTapped
        case pageChanged(Int)
        case registerShortcutTapped
        case delegate(Delegate)

        public enum Delegate: Equatable, Sendable {
            case finished
            /// View 가 `shortcuts://` 를 열도록 신호. URL 자체는 View 가 결정.
            case openShortcutsApp
        }
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .nextTapped:
                if state.isLastPage {
                    state.isFinished = true
                    return .send(.delegate(.finished))
                }
                state.currentPage += 1
                return .none

            case let .pageChanged(index):
                let clamped = max(0, min(index, OnboardingPage.allCases.count - 1))
                state.currentPage = clamped
                return .none

            case .registerShortcutTapped:
                return .send(.delegate(.openShortcutsApp))

            case .delegate:
                return .none
            }
        }
    }
}
