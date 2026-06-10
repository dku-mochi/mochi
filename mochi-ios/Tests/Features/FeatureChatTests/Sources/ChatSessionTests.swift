import ComposableArchitecture
import CoreAgentClient
import CoreNetworking
import XCTest

@testable import FeatureChat

/// 세션 관리 — 비활성 30분 자동분리·스냅샷 fold·히스토리 재개.
@MainActor
final class ChatSessionTests: XCTestCase {
    private let conversationID = UUID(1)

    private func snapshot(messages: [ChatSnapshotMessageDTO]) -> ChatSnapshotDTO {
        ChatSnapshotDTO(
            conversation: ChatConversationDTO(
                id: conversationID, title: "질문", createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            ),
            messages: messages
        )
    }

    private struct StubChatAPIClient: ChatAPIClient {
        var snapshot: ChatSnapshotDTO?
        func listConversations(limit: Int) async throws -> [ChatConversationDTO] { [] }
        func conversationSnapshot(id: UUID) async throws -> ChatSnapshotDTO {
            guard let snapshot else {
                throw APIErrorEnvelope(
                    code: "conversation.not_found", message: "gone", requestID: "r", retryAfter: nil
                )
            }
            return snapshot
        }
        func deleteConversation(id: UUID) async throws {}
    }

    // MARK: - fold: 서버 행 → 렌더 단위

    func test_fold_absorbs_tool_rows_into_next_assistant_and_drops_orphans() throws {
        let userID = UUID(10), assistantID = UUID(11)
        let proposalPayload = try JSONSerialization.data(withJSONObject: [
            "text": "우유 사기", "display": ["title": "기록해둘까요?"],
        ])
        let rows: [ChatSnapshotMessageDTO] = [
            .init(id: userID, role: "user", content: "질문"),
            .init(
                id: UUID(12), role: "tool", content: nil,
                toolName: "search_items", toolLabel: "기록을 뒤지고 있어요", toolSummary: "3개를 찾았어요"
            ),
            .init(
                id: assistantID, role: "assistant", content: "답이에요",
                citations: [.init(index: 1, mochiItemID: UUID(13), title: "제목", snippet: nil)],
                proposals: [.init(id: UUID(14), type: "create_memo", payloadJSON: proposalPayload)]
            ),
            // 다음 턴 — 실패한 run: tool 행만 있고 assistant 없음 → 버린다.
            .init(id: UUID(15), role: "user", content: "두번째"),
            .init(id: UUID(16), role: "tool", content: nil, toolName: "search_items", toolLabel: "뒤지는 중"),
        ]

        let folded = ChatFeature.fold(rows)

        XCTAssertEqual(folded.count, 3)   // user + assistant + user (고아 tool 행은 미렌더)
        let assistant = folded[id: assistantID]!
        XCTAssertEqual(assistant.toolSteps.count, 1)
        XCTAssertEqual(assistant.toolSteps[0].summary, "3개를 찾았어요")
        XCTAssertEqual(assistant.citations.count, 1)
        XCTAssertEqual(assistant.proposals.count, 1)
        XCTAssertEqual(assistant.proposals[0].status, .pending)
        XCTAssertEqual(assistant.proposals[0].proposal.kind, .createMemo)
    }

    // MARK: - 30분 자동분리

    func test_appeared_within_30min_resumes_previous_session() async {
        let now = Date(timeIntervalSince1970: 100_000)
        let store = TestStore(initialState: ChatFeature.State()) {
            ChatFeature()
        } withDependencies: {
            $0.date = .constant(now)
            $0.chatSessionStore = ChatSessionStore(
                load: { [id = conversationID] in .init(conversationID: id, lastActivityAt: now.addingTimeInterval(-60)) },
                save: { _, _ in }, clear: {}
            )
            $0.chatAPIClient = StubChatAPIClient(
                snapshot: snapshot(messages: [.init(id: UUID(20), role: "user", content: "이전 질문")])
            )
        }

        await store.send(.appeared)
        await store.receive(\.snapshotLoaded) {
            $0.conversationID = self.conversationID
            $0.messages = [.init(id: UUID(20), role: .user, text: "이전 질문")]
        }
    }

    func test_appeared_after_30min_starts_fresh_and_clears_persisted() async {
        let now = Date(timeIntervalSince1970: 100_000)
        let cleared = LockIsolated(false)
        let store = TestStore(initialState: ChatFeature.State()) {
            ChatFeature()
        } withDependencies: {
            $0.date = .constant(now)
            $0.chatSessionStore = ChatSessionStore(
                load: { [id = conversationID] in
                    .init(conversationID: id, lastActivityAt: now.addingTimeInterval(-31 * 60))
                },
                save: { _, _ in },
                clear: { cleared.setValue(true) }
            )
        }

        await store.send(.appeared)   // 상태 변화 없음 — 새 대화 그대로
        XCTAssertTrue(cleared.value)
    }

    func test_deleted_conversation_snapshot_falls_back_to_fresh() async {
        let now = Date(timeIntervalSince1970: 100_000)
        let cleared = LockIsolated(false)
        let store = TestStore(initialState: ChatFeature.State()) {
            ChatFeature()
        } withDependencies: {
            $0.date = .constant(now)
            $0.chatSessionStore = ChatSessionStore(
                load: { [id = conversationID] in .init(conversationID: id, lastActivityAt: now) },
                save: { _, _ in },
                clear: { cleared.setValue(true) }
            )
            $0.chatAPIClient = StubChatAPIClient(snapshot: nil)   // 404
        }

        await store.send(.appeared)
        await store.receive(\.snapshotLoadFailed)
        XCTAssertTrue(cleared.value)
        XCTAssertNil(store.state.conversationID)
    }

    // MARK: - 포그라운드 복귀 — running 이면 2초 폴링 (PR-5)

    func test_scene_activated_polls_snapshot_until_run_completes() async {
        /// 1회차: run 진행 중(user 행만) → 2회차: 완주(assistant 행 등장).
        actor SequencedClient: ChatAPIClient {
            let snapshots: [ChatSnapshotDTO]
            private var calls = 0
            init(snapshots: [ChatSnapshotDTO]) { self.snapshots = snapshots }
            func listConversations(limit: Int) async throws -> [ChatConversationDTO] { [] }
            func conversationSnapshot(id: UUID) async throws -> ChatSnapshotDTO {
                defer { calls = min(calls + 1, snapshots.count - 1) }
                return snapshots[calls]
            }
            func deleteConversation(id: UUID) async throws {}
        }

        let running = snapshot(messages: [
            .init(id: UUID(30), role: "user", content: "질문", runStatus: "running")
        ])
        let completed = snapshot(messages: [
            .init(id: UUID(30), role: "user", content: "질문", runStatus: "completed"),
            .init(id: UUID(31), role: "assistant", content: "돌아왔더니 답이 와 있다"),
        ])

        let testClock = TestClock()
        var initial = ChatFeature.State()
        initial.conversationID = conversationID
        initial.messages = [.init(id: UUID(30), role: .user, text: "질문")]
        let store = TestStore(initialState: initial) {
            ChatFeature()
        } withDependencies: {
            $0.chatAPIClient = SequencedClient(snapshots: [running, completed])
            $0.chatSessionStore = .noop
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.continuousClock = testClock
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.sceneActivated)
        await store.receive(\.snapshotLoaded)            // 1회차 — 아직 running
        await testClock.advance(by: .seconds(2))         // 폴링 간격
        await store.receive(\.snapshotLoaded)            // 2회차 — 완주 스냅샷, 폴링 종료
        await store.finish()

        XCTAssertEqual(store.state.messages.count, 2)
        XCTAssertEqual(store.state.messages[id: UUID(31)]?.text, "돌아왔더니 답이 와 있다")
    }

    // MARK: - 히스토리 재개 + 스와이프 삭제

    func test_history_selection_loads_snapshot_and_dismisses_sheet() async {
        var initial = ChatFeature.State()
        initial.history = ChatHistoryFeature.State()
        let store = TestStore(initialState: initial) {
            ChatFeature()
        } withDependencies: {
            $0.chatAPIClient = StubChatAPIClient(
                snapshot: snapshot(messages: [.init(id: UUID(21), role: "user", content: "재개")])
            )
            $0.chatSessionStore = .noop
            $0.date = .constant(Date(timeIntervalSince1970: 0))
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.history(.presented(.delegate(.conversationSelected(conversationID)))))
        await store.finish()
        await store.skipReceivedActions()

        XCTAssertNil(store.state.history)
        XCTAssertEqual(store.state.conversationID, conversationID)
        XCTAssertEqual(store.state.messages.first?.text, "재개")
    }

    func test_history_swipe_delete_removes_row_and_calls_api() async {
        let deleted = LockIsolated<[UUID]>([])
        struct RecordingClient: ChatAPIClient {
            let deleted: LockIsolated<[UUID]>
            func listConversations(limit: Int) async throws -> [ChatConversationDTO] { [] }
            func conversationSnapshot(id: UUID) async throws -> ChatSnapshotDTO {
                throw APIErrorEnvelope(code: "x", message: "x", requestID: "r", retryAfter: nil)
            }
            func deleteConversation(id: UUID) async throws { deleted.withValue { $0.append(id) } }
        }

        var initial = ChatHistoryFeature.State()
        initial.conversations = [
            ChatConversationDTO(id: conversationID, title: "질문", createdAt: .distantPast, updatedAt: .distantPast)
        ]
        let store = TestStore(initialState: initial) {
            ChatHistoryFeature()
        } withDependencies: {
            $0.chatAPIClient = RecordingClient(deleted: deleted)
        }

        await store.send(.deleteSwiped(conversationID)) {
            $0.conversations = []
        }
        await store.finish()
        XCTAssertEqual(deleted.value, [conversationID])
    }
}
