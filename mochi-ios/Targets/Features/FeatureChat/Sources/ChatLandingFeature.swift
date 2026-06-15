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
        /// 30분 내 진행 중이던 대화 — 있으면 랜딩에 "이어하기" 카드를 노출한다.
        /// 입력바 탭(blank)도 자동복원하지만 그 진입점이 안 보여서, 명시 카드로 드러낸다.
        public var resumable: ChatSessionStore.PersistedSession?

        public init() {}
    }

    public enum Action: Sendable {
        /// 화면 등장 — 활성 세션을 다시 읽어 이어하기 카드 노출 여부를 갱신한다.
        case onAppear
        /// 이어하기 카드 탭 — 진행 중이던 대화 snapshot 으로 push.
        case resumeTapped
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
    @Dependency(\.date) var date

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                // ChatFeature 의 blank 자동복원과 같은 30분 윈도우 — 그 안일 때만 "이어하기" 노출.
                if let session = sessionStore.load(),
                   date.now.timeIntervalSince(session.lastActivityAt) < ChatFeature.sessionMaxIdleSeconds {
                    state.resumable = session
                } else {
                    state.resumable = nil
                }
                return .none

            case .resumeTapped:
                guard let id = state.resumable?.conversationID else { return .none }
                return .send(.delegate(.conversationRequested(.resume(id))))

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
                if state.resumable?.conversationID == deletedID {
                    state.resumable = nil
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
