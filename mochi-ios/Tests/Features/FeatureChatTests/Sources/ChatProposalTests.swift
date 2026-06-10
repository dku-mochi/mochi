import ComposableArchitecture
import CoreAgentClient
import CoreDomain
import CoreNetworking
import CorePersistence
import XCTest

@testable import FeatureChat

/// proposal 카드 상태머신 + 확정 경로 — pending→confirming→confirmed/expired/failed/cancelled.
@MainActor
final class ChatProposalTests: XCTestCase {
    private let messageID = UUID(1)
    private let serverItemID = UUID(2)

    private func makeState(_ proposal: ChatProposal) -> ChatFeature.State {
        var state = ChatFeature.State()
        var assistant = ChatFeature.ChatMessage(id: messageID, role: .assistant, text: "답변")
        assistant.proposals = [ChatFeature.ProposalCard(proposal: proposal)]
        state.messages = [assistant]
        return state
    }

    private func deleteProposal() -> ChatProposal {
        ChatProposal(
            id: UUID(10), title: "이 기록을 지울까요?", detail: nil,
            action: .deleteItem(mochiItemID: serverItemID)
        )
    }

    // MARK: - 분기 ① 확정 성공

    func test_confirm_delete_success_transitions_to_confirmed() async {
        let api = StubAPIClient()
        let store = TestStore(initialState: makeState(deleteProposal())) {
            ChatFeature()
        } withDependencies: {
            $0.mochiAPIClient = api
            $0.mochiItemRepository = InMemoryMochiItemRepository()
        }

        await store.send(.proposalConfirmTapped(messageID: messageID, proposalID: UUID(10))) {
            $0.messages[id: self.messageID]?.proposals[id: UUID(10)]?.status = .confirming
        }
        await store.receive(\.proposalResolved) {
            $0.messages[id: self.messageID]?.proposals[id: UUID(10)]?.status = .confirmed
        }
        let deleted = await api.deletedServerIDs
        XCTAssertEqual(deleted, [serverItemID])
    }

    // MARK: - 분기 ② 404 = 카드 만료

    func test_confirm_on_missing_item_transitions_to_expired() async {
        let api = StubAPIClient()
        await api.setDeleteError(
            APIErrorEnvelope(code: "mochi_item.not_found", message: "gone", requestID: "r", retryAfter: nil)
        )
        let store = TestStore(initialState: makeState(deleteProposal())) {
            ChatFeature()
        } withDependencies: {
            $0.mochiAPIClient = api
            $0.mochiItemRepository = InMemoryMochiItemRepository()
        }

        await store.send(.proposalConfirmTapped(messageID: messageID, proposalID: UUID(10))) {
            $0.messages[id: self.messageID]?.proposals[id: UUID(10)]?.status = .confirming
        }
        await store.receive(\.proposalResolved) {
            $0.messages[id: self.messageID]?.proposals[id: UUID(10)]?.status = .expired
        }
    }

    // MARK: - 분기 ③ 알림 권한 거부 = failed + 설정 안내

    func test_reminder_permission_denied_transitions_to_failed_with_permission_flag() async {
        let reminder = ChatProposal(
            id: UUID(11), title: "알림을 맞출까요?", detail: nil,
            action: .reminder(.init(fireAt: Date(timeIntervalSinceNow: 3600), title: "우유 사기"))
        )
        let store = TestStore(initialState: makeState(reminder)) {
            ChatFeature()
        } withDependencies: {
            $0.reminderScheduler = DenyingReminderScheduler()
        }

        await store.send(.proposalConfirmTapped(messageID: messageID, proposalID: UUID(11))) {
            $0.messages[id: self.messageID]?.proposals[id: UUID(11)]?.status = .confirming
        }
        await store.receive(\.proposalResolved) {
            $0.messages[id: self.messageID]?.proposals[id: UUID(11)]?.status =
                .failed(reason: "알림 권한이 꺼져 있어요", needsNotificationPermission: true)
        }
    }

    // MARK: - 분기 ④ 취소 (+ 비-pending 재탭 무시)

    func test_cancel_and_double_tap_guard() async {
        let store = TestStore(initialState: makeState(deleteProposal())) { ChatFeature() }

        await store.send(.proposalCancelTapped(messageID: messageID, proposalID: UUID(10))) {
            $0.messages[id: self.messageID]?.proposals[id: UUID(10)]?.status = .cancelled
        }
        // 취소된 카드는 확정 불가 — 상태 변화·effect 없음.
        await store.send(.proposalConfirmTapped(messageID: messageID, proposalID: UUID(10)))
    }

    // MARK: - 확정/취소가 서버에 영속된다 (스냅샷 복귀 시 pending 부활 방지 — 2026-06-10 버그)

    func test_confirm_persists_status_to_server() async {
        struct RecordingChatClient: ChatAPIClient {
            let recorded: LockIsolated<[(UUID, UUID, ChatProposalStatusUpdate)]>
            func listConversations(limit: Int) async throws -> [ChatConversationDTO] { [] }
            func conversationSnapshot(id: UUID) async throws -> ChatSnapshotDTO {
                throw APIErrorEnvelope(code: "x", message: "x", requestID: "r", retryAfter: nil)
            }
            func deleteConversation(id: UUID) async throws {}
            func setProposalStatus(
                conversationID: UUID, proposalID: UUID, status: ChatProposalStatusUpdate
            ) async throws {
                recorded.withValue { $0.append((conversationID, proposalID, status)) }
            }
        }

        let recorded = LockIsolated<[(UUID, UUID, ChatProposalStatusUpdate)]>([])
        var initial = makeState(deleteProposal())
        initial.conversationID = UUID(3)
        let store = TestStore(initialState: initial) {
            ChatFeature()
        } withDependencies: {
            $0.mochiAPIClient = StubAPIClient()
            $0.mochiItemRepository = InMemoryMochiItemRepository()
            $0.chatAPIClient = RecordingChatClient(recorded: recorded)
        }

        await store.send(.proposalConfirmTapped(messageID: messageID, proposalID: UUID(10))) {
            $0.messages[id: self.messageID]?.proposals[id: UUID(10)]?.status = .confirming
        }
        await store.receive(\.proposalResolved) {
            $0.messages[id: self.messageID]?.proposals[id: UUID(10)]?.status = .confirmed
        }
        await store.finish()

        XCTAssertEqual(recorded.value.count, 1)
        XCTAssertEqual(recorded.value.first?.0, UUID(3))
        XCTAssertEqual(recorded.value.first?.1, UUID(10))
        XCTAssertEqual(recorded.value.first?.2, .confirmed)
    }

    // MARK: - 메모 확정 = 로컬 upsert(channel .chat) + sync

    func test_confirm_memo_upserts_local_chat_item_and_triggers_sync() async {
        let repository = InMemoryMochiItemRepository()
        let sync = SpySyncTrigger()
        let memo = ChatProposal(
            id: UUID(12), title: "이 내용을 기록해둘까요?", detail: nil,
            action: .createMemo(text: "내일 우유 사야 해")
        )
        let store = TestStore(initialState: makeState(memo)) {
            ChatFeature()
        } withDependencies: {
            $0.mochiItemRepository = repository
            $0.syncTrigger = sync
            $0.uuid = .incrementing
        }

        await store.send(.proposalConfirmTapped(messageID: messageID, proposalID: UUID(12))) {
            $0.messages[id: self.messageID]?.proposals[id: UUID(12)]?.status = .confirming
        }
        await store.receive(\.proposalResolved) {
            $0.messages[id: self.messageID]?.proposals[id: UUID(12)]?.status = .confirmed
        }

        let saved = try? await repository.listRecent(limit: 10)
        XCTAssertEqual(saved?.count, 1)
        XCTAssertEqual(saved?.first?.source.channel, .chat)
        XCTAssertEqual(saved?.first?.source.text, "내일 우유 사야 해")
        let ranOnce = await sync.runOnceCount
        XCTAssertEqual(ranOnce, 1)
    }
}

// MARK: - Stubs

/// 필요한 메서드만 기록·제어하고 나머지는 NotConfigured 에러로 던지는 스텁.
private actor StubAPIClient: MochiAPIClient {
    var deletedServerIDs: [UUID] = []
    private var deleteError: APIErrorEnvelope?

    func setDeleteError(_ error: APIErrorEnvelope) { deleteError = error }

    func deleteMochiItem(mochiServerID: UUID) async throws {
        if let deleteError { throw deleteError }
        deletedServerIDs.append(mochiServerID)
    }

    // 미사용 표면 — 호출되면 테스트가 즉시 드러나게 NotConfigured 에 위임.
    private let unimplemented = NotConfiguredAPIClient()
    func ingestMochiItem(_ request: MochiItemIngestRequest, idempotencyKey: String) async throws -> MochiItemDTO {
        try await unimplemented.ingestMochiItem(request, idempotencyKey: idempotencyKey)
    }
    func presignCaptureUpload(sha256: String, mimeType: String) async throws -> PresignUploadDTO {
        try await unimplemented.presignCaptureUpload(sha256: sha256, mimeType: mimeType)
    }
    func putCaptureImage(uploadURL: URL, data: Data, mimeType: String) async throws {
        try await unimplemented.putCaptureImage(uploadURL: uploadURL, data: data, mimeType: mimeType)
    }
    func getMochiItem(id: UUID) async throws -> MochiItemDTO {
        try await unimplemented.getMochiItem(id: id)
    }
    func listMochiItems(limit: Int) async throws -> [MochiItemDTO] {
        try await unimplemented.listMochiItems(limit: limit)
    }
    func presignCaptureDownload(objectKey: String) async throws -> URL {
        try await unimplemented.presignCaptureDownload(objectKey: objectKey)
    }
    func search(query: String, scope: SearchScope) async throws -> SearchResponse {
        try await unimplemented.search(query: query, scope: scope)
    }
    func registerPushToken(token: String, kind: PushTokenKind, environment: PushEnvironment, mochiItemID: UUID?) async throws {
        try await unimplemented.registerPushToken(token: token, kind: kind, environment: environment, mochiItemID: mochiItemID)
    }
    func reanalyzeMochiItem(id: UUID, userHint: String) async throws {
        try await unimplemented.reanalyzeMochiItem(id: id, userHint: userHint)
    }
    func updateInstanceLifecycle(mochiServerID: UUID, instanceID: UUID, to newState: InstanceLifecycle) async throws -> MochiItemDTO {
        try await unimplemented.updateInstanceLifecycle(mochiServerID: mochiServerID, instanceID: instanceID, to: newState)
    }
    func updateMochiItem(mochiServerID: UUID, _ request: MochiItemUpdateRequestDTO) async throws {
        try await unimplemented.updateMochiItem(mochiServerID: mochiServerID, request)
    }
    func upcomingActionables() async throws -> [UpcomingActionableDTO] {
        try await unimplemented.upcomingActionables()
    }
    func weeklyDigest(weekStart: Date) async throws -> WeeklyDigestDTO {
        try await unimplemented.weeklyDigest(weekStart: weekStart)
    }
}

private struct DenyingReminderScheduler: ReminderScheduler {
    func schedule(id: UUID, title: String, fireAt: Date, relatedMochiItemID: UUID?) async throws {
        throw ReminderSchedulingError.permissionDenied
    }
}

private actor SpySyncTrigger: SyncTrigger {
    var runOnceCount = 0
    var pullRemoteCount = 0
    func runOnce() async { runOnceCount += 1 }
    func pullRemote() async { pullRemoteCount += 1 }
}
