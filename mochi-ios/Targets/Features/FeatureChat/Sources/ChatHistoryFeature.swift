import ComposableArchitecture
import CoreNetworking
import Foundation

/// 지난 대화 시트 — 목록·스와이프 삭제·탭 재개.
///
/// 세션 리스트를 탭 진입점으로 두지 않는 대신(메신저 감각 우선) 여기로 접어둔다.
/// 제목은 서버가 만든 첫 질문 40자 truncate — 클라이언트 요약 없음.
@Reducer
public struct ChatHistoryFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        public var conversations: IdentifiedArrayOf<ChatConversationDTO> = []
        public var isLoading = false
        public var loadFailed = false

        public init() {}
    }

    public enum Action: Sendable {
        case task
        case loaded([ChatConversationDTO])
        case loadFailed
        case deleteSwiped(UUID)
        case conversationTapped(UUID)
        case delegate(Delegate)

        public enum Delegate: Equatable, Sendable {
            /// 부모(ChatFeature)가 스냅샷을 불러 대화를 재개한다.
            case conversationSelected(UUID)
        }
    }

    @Dependency(\.chatAPIClient) var chatAPIClient

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                state.isLoading = true
                state.loadFailed = false
                return .run { send in
                    do {
                        let conversations = try await chatAPIClient.listConversations(limit: 50)
                        await send(.loaded(conversations))
                    } catch {
                        await send(.loadFailed)
                    }
                }

            case let .loaded(conversations):
                state.isLoading = false
                state.conversations = IdentifiedArray(uniqueElements: conversations)
                return .none

            case .loadFailed:
                state.isLoading = false
                state.loadFailed = true
                return .none

            case let .deleteSwiped(id):
                // 낙관 제거 — soft delete 라 서버 실패해도 다음 목록 로드에서 되살아날 뿐.
                state.conversations.remove(id: id)
                return .run { _ in
                    try? await chatAPIClient.deleteConversation(id: id)
                }

            case let .conversationTapped(id):
                return .send(.delegate(.conversationSelected(id)))

            case .delegate:
                return .none
            }
        }
    }
}
