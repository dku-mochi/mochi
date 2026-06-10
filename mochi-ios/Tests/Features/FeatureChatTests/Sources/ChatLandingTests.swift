import ComposableArchitecture
import CoreNetworking
import XCTest

@testable import FeatureChat

/// 랜딩 — 모든 진입이 delegate(.conversationRequested) 로 상위 push 요청으로 수렴한다.
@MainActor
final class ChatLandingTests: XCTestCase {
    func test_composer_tap_requests_blank_conversation() async {
        let store = TestStore(initialState: ChatLandingFeature.State()) { ChatLandingFeature() }

        await store.send(.composerTapped)
        await store.receive(\.delegate.conversationRequested, .blank)
    }

    func test_chip_tap_requests_first_message_conversation() async {
        let store = TestStore(initialState: ChatLandingFeature.State()) { ChatLandingFeature() }

        await store.send(.chipTapped("오늘 데이트 어디서 갈까?"))
        await store.receive(
            \.delegate.conversationRequested, .firstMessage("오늘 데이트 어디서 갈까?")
        )
    }

    func test_history_selection_dismisses_sheet_and_requests_resume() async {
        let conversationID = UUID(3)
        var initial = ChatLandingFeature.State()
        initial.history = ChatHistoryFeature.State()
        let store = TestStore(initialState: initial) { ChatLandingFeature() }

        await store.send(.history(.presented(.delegate(.conversationSelected(conversationID))))) {
            $0.history = nil
        }
        await store.receive(\.delegate.conversationRequested, .resume(conversationID))
    }

    func test_history_delete_of_active_session_clears_pointer() async {
        // 활성 세션의 대화를 시트에서 삭제 — 포인터를 남기면 다음 blank 진입이
        // 죽은 대화 스냅샷을 헛조회한다.
        struct StubChatAPIClient: ChatAPIClient {
            func listConversations(limit: Int) async throws -> [ChatConversationDTO] { [] }
            func conversationSnapshot(id: UUID) async throws -> ChatSnapshotDTO {
                throw APIErrorEnvelope(code: "x", message: "x", requestID: "r", retryAfter: nil)
            }
            func deleteConversation(id: UUID) async throws {}
            func setProposalStatus(
                conversationID: UUID, proposalID: UUID, status: ChatProposalStatusUpdate
            ) async throws {}
        }

        let activeID = UUID(5)
        let cleared = LockIsolated(false)
        var initial = ChatLandingFeature.State()
        initial.history = ChatHistoryFeature.State()
        let store = TestStore(initialState: initial) {
            ChatLandingFeature()
        } withDependencies: {
            $0.chatAPIClient = StubChatAPIClient()
            $0.chatSessionStore = ChatSessionStore(
                load: { .init(conversationID: activeID, lastActivityAt: .distantPast) },
                save: { _, _ in },
                clear: { cleared.setValue(true) }
            )
        }

        await store.send(.history(.presented(.deleteSwiped(activeID))))
        await store.finish()
        XCTAssertTrue(cleared.value)
    }
}
