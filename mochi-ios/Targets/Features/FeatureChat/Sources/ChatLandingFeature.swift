import ComposableArchitecture
import Foundation

/// 채팅 탭 랜딩 — 대화를 시작하는 진입점만 담당하는 가벼운 화면.
///
/// 대화 자체는 ``ChatFeature`` 가 NavigationStack push 풀스크린으로 연다(2026-06-10 구조 전환).
/// 랜딩은 인사·추천 칩·입력바 모양 버튼·지난 대화 시트만 들고, 어떤 진입이든
/// `delegate(.conversationRequested(Entry))` 로 상위(MainTab)에 push 를 요청한다.
@Reducer
public struct ChatLandingFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        @Presents public var history: ChatHistoryFeature.State?

        public init() {}
    }

    public enum Action: Sendable {
        /// 입력바 모양 버튼 탭 — 빈 대화로 push (활성 세션 복원은 ChatFeature 몫).
        case composerTapped
        /// 추천 칩 탭 — 해당 문구를 첫 메시지로 새 대화 push.
        case chipTapped(String)
        case historyButtonTapped
        case history(PresentationAction<ChatHistoryFeature.Action>)
        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Equatable, Sendable {
            /// 상위(MainTab)가 ``ChatFeature`` 를 path 에 push 한다.
            case conversationRequested(ChatFeature.Entry)
        }
    }

    @Dependency(\.chatSessionStore) var sessionStore

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .composerTapped:
                return .send(.delegate(.conversationRequested(.blank)))

            case let .chipTapped(question):
                return .send(.delegate(.conversationRequested(.firstMessage(question))))

            case .historyButtonTapped:
                state.history = ChatHistoryFeature.State()
                return .none

            case let .history(.presented(.delegate(.conversationSelected(conversationID)))):
                state.history = nil
                return .send(.delegate(.conversationRequested(.resume(conversationID))))

            case let .history(.presented(.deleteSwiped(deletedID))):
                // 활성 세션의 대화를 지웠으면 포인터도 정리 — 남기면 다음 blank 진입이
                // 죽은 대화 스냅샷을 한 번 헛조회한다 (404 폴백으로 자가치유는 되지만).
                if sessionStore.load()?.conversationID == deletedID {
                    sessionStore.clear()
                }
                return .none

            case .history:
                return .none

            case .delegate:
                return .none
            }
        }
        .ifLet(\.$history, action: \.history) { ChatHistoryFeature() }
    }
}
