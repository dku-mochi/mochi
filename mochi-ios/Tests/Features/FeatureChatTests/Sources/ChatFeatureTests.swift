import ComposableArchitecture
import CoreAgentClient
import XCTest

@testable import FeatureChat

@MainActor
final class ChatFeatureTests: XCTestCase {
    /// 스크립트 주입 가능한 스텁 — 이벤트 시퀀스를 즉시 흘린다.
    private struct ScriptedChatStreamClient: ChatStreamClient {
        let events: [ChatStreamEvent]
        let failure: Error?

        init(events: [ChatStreamEvent], failure: Error? = nil) {
            self.events = events
            self.failure = failure
        }

        func send(conversationID: UUID, text: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
            AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish(throwing: failure)
            }
        }
    }

    private enum StubError: Error { case boom }

    func test_empty_draft_does_not_send() async {
        let store = TestStore(initialState: ChatFeature.State()) { ChatFeature() }
        await store.send(.sendTapped)   // 변경 없음
    }

    func test_send_streams_full_event_sequence_into_assistant_message() async {
        let citation = ChatCitation(
            index: 1,
            mochiItemID: UUID(0),
            title: "한강 카페",
            snippet: "통창 뷰"
        )
        let doneID = UUID(9)
        let events: [ChatStreamEvent] = [
            .toolStarted(name: "search_items", label: "기록을 뒤지고 있어요"),
            .toolFinished(name: "search_items", summary: "기록 3개를 찾았어요"),
            .messageDelta("좋은 "),
            .messageDelta("곳이 있어요"),
            .citation(citation),
            .done(messageID: doneID),
        ]
        let store = TestStore(initialState: ChatFeature.State()) {
            ChatFeature()
        } withDependencies: {
            $0.chatStreamClient = ScriptedChatStreamClient(events: events)
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(\.binding.draft, "오늘 데이트 어디서 갈까?")
        await store.send(.sendTapped)
        await store.finish()
        await store.skipReceivedActions()

        let state = store.state
        // conversationID(0) + user(1) + assistant(2)
        XCTAssertNotNil(state.conversationID)
        XCTAssertEqual(state.messages.count, 2)
        XCTAssertEqual(state.messages[0].role, .user)
        XCTAssertEqual(state.messages[0].text, "오늘 데이트 어디서 갈까?")

        let assistant = state.messages[1]
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(assistant.text, "좋은 곳이 있어요")
        XCTAssertEqual(assistant.toolSteps.count, 1)
        XCTAssertEqual(assistant.toolSteps[0].summary, "기록 3개를 찾았어요")
        XCTAssertNil(assistant.activeToolLabel)
        XCTAssertEqual(assistant.citations, [citation])
        XCTAssertFalse(assistant.isStreaming)
        XCTAssertEqual(state.runPhase, .idle)
        XCTAssertEqual(state.draft, "")
    }

    func test_stream_failure_removes_empty_bubble_and_sets_failed_phase() async {
        let store = TestStore(initialState: ChatFeature.State()) {
            ChatFeature()
        } withDependencies: {
            $0.chatStreamClient = ScriptedChatStreamClient(events: [], failure: StubError.boom)
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.chipTapped("이번주 공부 기록 알려줘"))
        await store.finish()
        await store.skipReceivedActions()

        // 빈 assistant 버블은 남기지 않는다 — user 메시지만.
        XCTAssertEqual(store.state.messages.count, 1)
        XCTAssertEqual(store.state.messages[0].role, .user)
        guard case .failed = store.state.runPhase else {
            return XCTFail("runPhase 가 failed 가 아님: \(store.state.runPhase)")
        }
    }

    func test_start_conversation_always_begins_fresh() async {
        var initial = ChatFeature.State()
        initial.conversationID = UUID(7)
        initial.messages = [
            .init(id: UUID(1), role: .user, text: "이전 질문"),
            .init(id: UUID(2), role: .assistant, text: "이전 답변"),
        ]
        let store = TestStore(initialState: initial) {
            ChatFeature()
        } withDependencies: {
            $0.chatStreamClient = ScriptedChatStreamClient(events: [.done(messageID: UUID(8))])
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.startConversation(firstMessage: "민수랑 언제 만나기로 했지?"))
        await store.finish()
        await store.skipReceivedActions()

        // 기존 대화는 버려지고 새 conversationID + 첫 user 메시지로 시작.
        XCTAssertNotEqual(store.state.conversationID, UUID(7))
        XCTAssertEqual(store.state.messages[0].text, "민수랑 언제 만나기로 했지?")
    }

    func test_new_conversation_resets_state() async {
        var initial = ChatFeature.State()
        initial.conversationID = UUID(7)
        initial.messages = [.init(id: UUID(1), role: .user, text: "질문")]
        initial.draft = "쓰다 만 글"
        let store = TestStore(initialState: initial) { ChatFeature() }

        await store.send(.newConversationTapped) {
            $0.conversationID = nil
            $0.messages = []
            $0.draft = ""
            $0.runPhase = .idle
        }
    }

    func test_send_blocked_while_streaming() async {
        var initial = ChatFeature.State()
        initial.runPhase = .streaming
        initial.draft = "두 번째 질문"
        let store = TestStore(initialState: initial) { ChatFeature() }

        await store.send(.sendTapped)   // 변경 없음 — 진행 중엔 전송 불가
    }
}
