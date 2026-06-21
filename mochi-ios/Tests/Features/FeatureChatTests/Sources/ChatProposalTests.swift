import ComposableArchitecture
import CoreAgentClient
import CoreDomain
import CoreIntegrations
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

    /// pull↔upload 경합이 남긴 복제 쌍(origin 행 + server-id PK 행)에서 확정 삭제가 **두 행 모두**
    /// 지우는지 — 한 행만 지우면 남은 쪽이 영구 고아(서버에선 이미 삭제돼 pull/dedup 이 다시는
    /// 안 만짐)로 홈에 계속 보인다 (2026-06-11 사용자 리포트: 채팅 삭제 카드가 반영 안 됨).
    func test_confirm_delete_removes_all_local_mirror_rows() async throws {
        let repository = InMemoryMochiItemRepository()
        let originID = UUID(20)
        try await repository.upsert(
            MochiItem(
                source: IngestSource(id: originID, channel: .screenshot),
                syncState: .uploaded(serverID: serverItemID, at: Date())
            )
        )
        try await repository.upsert(
            MochiItem(
                source: IngestSource(id: serverItemID, channel: .screenshot),
                syncState: .uploaded(serverID: serverItemID, at: Date())
            )
        )

        let store = TestStore(initialState: makeState(deleteProposal())) {
            ChatFeature()
        } withDependencies: {
            $0.mochiAPIClient = StubAPIClient()
            $0.mochiItemRepository = repository
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.proposalConfirmTapped(messageID: messageID, proposalID: UUID(10)))
        await store.finish()

        let remaining = try await repository.listRecent(limit: 10)
        XCTAssertTrue(remaining.isEmpty, "로컬 미러 행이 남음: \(remaining.map(\.id))")
    }

    // MARK: - 분기 ② 404 = 카드 만료

    func test_confirm_on_missing_item_transitions_to_expired() async throws {
        let api = StubAPIClient()
        await api.setDeleteError(
            APIErrorEnvelope(code: "mochi_item.not_found", message: "gone", requestID: "r", retryAfter: nil)
        )
        // 서버에선 이미 사라진 기록의 고아 미러 — 만료 카드로 보내더라도 로컬은 거둬야 한다.
        let repository = InMemoryMochiItemRepository()
        try await repository.upsert(
            MochiItem(
                source: IngestSource(id: UUID(21), channel: .screenshot),
                syncState: .uploaded(serverID: serverItemID, at: Date())
            )
        )
        let store = TestStore(initialState: makeState(deleteProposal())) {
            ChatFeature()
        } withDependencies: {
            $0.mochiAPIClient = api
            $0.mochiItemRepository = repository
        }

        await store.send(.proposalConfirmTapped(messageID: messageID, proposalID: UUID(10))) {
            $0.messages[id: self.messageID]?.proposals[id: UUID(10)]?.status = .confirming
        }
        await store.receive(\.proposalResolved) {
            $0.messages[id: self.messageID]?.proposals[id: UUID(10)]?.status = .expired
        }
        let remaining = try await repository.listRecent(limit: 10)
        XCTAssertTrue(remaining.isEmpty, "만료 경로에서 고아 미러가 남음: \(remaining.map(\.id))")
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

    // MARK: - 수정 확정 = PATCH 응답을 로컬 미러에 merge (날짜 변경 캘린더 미반영 — 2026-06-10 버그)

    func test_confirm_update_merges_server_response_into_local_mirror() async {
        let repository = InMemoryMochiItemRepository()
        let instanceID = UUID(20)
        // 로컬 미러 — pull 로 복구된 항목(로컬 PK == 서버 id), 일정 날짜 6/12.
        let local = MochiItem(
            source: IngestSource(id: serverItemID, channel: .chat, text: "원래 메모"),
            analysis: MochiItemAnalysis(
                summary: "원래 요약",
                instances: [
                    IntentInstance(
                        id: instanceID, intentType: .schedule,
                        payload: IntentPayload(date: "2026-06-12")
                    )
                ],
                entities: [], actionCandidates: [], tags: [],
                importance: .medium, modelVersion: "test", analyzedAt: Date(timeIntervalSince1970: 0)
            ),
            lifecycleState: .analyzed,
            syncState: .uploaded(serverID: serverItemID, at: Date(timeIntervalSince1970: 0))
        )
        try? await repository.upsert(local)

        // 서버 PATCH 응답 — 날짜가 6/15 로 병합된 정본.
        let api = StubAPIClient()
        await api.setUpdateResult(
            MochiItemDTO(
                id: serverItemID, channel: .chat, url: nil, text: "원래 메모", userMemo: nil,
                summary: "원래 요약", category: nil, importance: 2,
                intentInstances: [
                    IntentInstanceDTO(
                        id: instanceID, intentType: .schedule,
                        payload: IntentPayloadDTO(date: "2026-06-15"),
                        label: nil, reasoning: nil, lifecycleKind: "active", lifecycleArchiveReason: nil
                    )
                ],
                needsReview: false, reviewOptions: [], lifecycleKind: "analyzed", syncKind: "synced",
                imageRefs: [], capturedAt: Date(timeIntervalSince1970: 0),
                createdAt: Date(timeIntervalSince1970: 0)
            )
        )

        let update = ChatProposal(
            id: UUID(13), title: "날짜를 바꿀까요?", detail: nil,
            action: .updateItem(
                .init(
                    mochiItemID: serverItemID,
                    instanceChanges: [.init(instanceID: instanceID, payload: ["date": "2026-06-15"])]
                )
            )
        )
        let store = TestStore(initialState: makeState(update)) {
            ChatFeature()
        } withDependencies: {
            $0.mochiAPIClient = api
            $0.mochiItemRepository = repository
            $0.syncTrigger = SpySyncTrigger()
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        }

        await store.send(.proposalConfirmTapped(messageID: messageID, proposalID: UUID(13))) {
            $0.messages[id: self.messageID]?.proposals[id: UUID(13)]?.status = .confirming
        }
        await store.receive(\.proposalResolved) {
            $0.messages[id: self.messageID]?.proposals[id: UUID(13)]?.status = .confirmed
        }

        // 캘린더는 로컬 Realm 구동 — merge 된 날짜가 로컬에서 바로 보여야 한다.
        let saved = try? await repository.find(id: serverItemID)
        XCTAssertEqual(saved?.analysis?.instances.first?.payload.date, "2026-06-15")
        XCTAssertEqual(saved?.source.text, "원래 메모")   // 콘텐츠 보존
    }

    // MARK: - 일정 확정 = 시스템 캘린더(EKEvent)·미리알림(EKReminder) 등록 (2026-06-10 요청)

    private func schedulePayloadDTO() -> MochiItemDTO {
        MochiItemDTO(
            id: UUID(30), channel: .chat, url: nil, text: "팀 회식", userMemo: nil,
            summary: nil, category: nil, importance: 2, intentInstances: [],
            needsReview: false, reviewOptions: [], lifecycleKind: "analyzed", syncKind: "synced",
            imageRefs: [], capturedAt: Date(timeIntervalSince1970: 0),
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func scheduleProposal() -> ChatProposal {
        ChatProposal(
            id: UUID(14), title: "일정을 등록할까요?", detail: nil,
            action: .createSchedule(
                .init(
                    text: "팀 회식",
                    instances: [
                        .init(
                            intentType: "schedule",
                            payload: ["title": "팀 회식", "date": "2026-06-12", "time": "19:00"]
                        ),
                        .init(intentType: "schedule", payload: ["title": "워크숍", "date": "2026-06-20"]),
                        .init(intentType: "todo", payload: ["title": "선물 사기", "deadline": "2026-06-14"]),
                    ]
                )
            )
        )
    }

    func test_confirm_schedule_registers_system_calendar_and_reminders() async {
        let api = StubAPIClient()
        await api.setIngestResult(schedulePayloadDTO())
        let syncer = SpyCalendarSyncer()
        let store = TestStore(initialState: makeState(scheduleProposal())) {
            ChatFeature()
        } withDependencies: {
            $0.mochiAPIClient = api
            $0.syncTrigger = SpySyncTrigger()
            $0.calendarSyncer = syncer
        }

        await store.send(.proposalConfirmTapped(messageID: messageID, proposalID: UUID(14))) {
            $0.messages[id: self.messageID]?.proposals[id: UUID(14)]?.status = .confirming
        }
        await store.receive(\.proposalResolved) {
            $0.messages[id: self.messageID]?.proposals[id: UUID(14)]?.status = .confirmed
        }

        let events = await syncer.events
        XCTAssertEqual(events.map { $0.title }, ["팀 회식", "워크숍"])
        XCTAssertEqual(events.map { $0.allDay }, [false, true])   // time 있으면 시각, 없으면 종일
        let reminders = await syncer.reminders
        XCTAssertEqual(reminders.map { $0.title }, ["선물 사기"])
        XCTAssertNotNil(reminders.first?.due)
    }

    func test_scheduleEnd_parses_range_and_degrades_invalid_to_nil() {
        let (start, _) = SystemCalendarRegistrar.scheduleStart(from: ["date": "2026-06-12"])!
        // 기간 일정: end_date(+end_time) → EKEvent 종료 시각.
        XCTAssertEqual(
            SystemCalendarRegistrar.scheduleEnd(from: ["end_date": "2026-06-14", "end_time": "18:00"], start: start),
            PayloadDate.parse("2026-06-14 18:00")
        )
        XCTAssertEqual(
            SystemCalendarRegistrar.scheduleEnd(from: ["end_date": "2026-06-14"], start: start),
            PayloadDate.parse("2026-06-14")
        )
        // end 없음·역전 데이터는 nil — 점 일정의 기존 기본값(종일=start, 시각=+1h)을 따른다.
        XCTAssertNil(SystemCalendarRegistrar.scheduleEnd(from: [:], start: start))
        XCTAssertNil(SystemCalendarRegistrar.scheduleEnd(from: ["end_date": "2026-06-10"], start: start))
    }

    func test_confirm_schedule_permission_denied_fails_with_settings_nudge() async {
        let api = StubAPIClient()
        await api.setIngestResult(schedulePayloadDTO())
        let syncer = SpyCalendarSyncer()
        await syncer.setDenyAccess()
        let store = TestStore(initialState: makeState(scheduleProposal())) {
            ChatFeature()
        } withDependencies: {
            $0.mochiAPIClient = api
            $0.syncTrigger = SpySyncTrigger()
            $0.calendarSyncer = syncer
        }

        await store.send(.proposalConfirmTapped(messageID: messageID, proposalID: UUID(14))) {
            $0.messages[id: self.messageID]?.proposals[id: UUID(14)]?.status = .confirming
        }
        await store.receive(\.proposalResolved) {
            $0.messages[id: self.messageID]?.proposals[id: UUID(14)]?.status =
                .failed(reason: "캘린더·미리알림 권한이 꺼져 있어요", needsNotificationPermission: true)
        }
        // 권한 거부 시 아무것도 만들지 않는다 — 재확정 시 중복 등록 방지.
        let events = await syncer.events
        let reminders = await syncer.reminders
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(reminders.isEmpty)
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
    private var updateResult: MochiItemDTO?
    private var ingestResult: MochiItemDTO?

    func setDeleteError(_ error: APIErrorEnvelope) { deleteError = error }
    func setUpdateResult(_ dto: MochiItemDTO) { updateResult = dto }
    func setIngestResult(_ dto: MochiItemDTO) { ingestResult = dto }

    func deleteMochiItem(mochiServerID: UUID) async throws {
        if let deleteError { throw deleteError }
        deletedServerIDs.append(mochiServerID)
    }

    // 미사용 표면 — 호출되면 테스트가 즉시 드러나게 NotConfigured 에 위임.
    private let unimplemented = NotConfiguredAPIClient()
    func setFavorite(mochiServerID: UUID, isFavorite: Bool) async throws -> MochiItemDTO {
        try await unimplemented.setFavorite(mochiServerID: mochiServerID, isFavorite: isFavorite)
    }
    func logItemAccess(mochiServerID: UUID, source: ItemAccessSource) async throws {
        try await unimplemented.logItemAccess(mochiServerID: mochiServerID, source: source)
    }
    func ingestMochiItem(_ request: MochiItemIngestRequest, idempotencyKey: String) async throws -> MochiItemDTO {
        guard let ingestResult else {
            return try await unimplemented.ingestMochiItem(request, idempotencyKey: idempotencyKey)
        }
        return ingestResult
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
    func similarItems(serverID: UUID, limit: Int) async throws -> [SimilarItemRef] {
        try await unimplemented.similarItems(serverID: serverID, limit: limit)
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
    func updateMochiItem(
        mochiServerID: UUID, _ request: MochiItemUpdateRequestDTO
    ) async throws -> MochiItemDTO {
        guard let updateResult else {
            return try await unimplemented.updateMochiItem(mochiServerID: mochiServerID, request)
        }
        return updateResult
    }
    func upcomingActionables() async throws -> [UpcomingActionableDTO] {
        try await unimplemented.upcomingActionables()
    }
    func monthlyDigest(monthStart: Date) async throws -> MonthlyDigestDTO {
        try await unimplemented.monthlyDigest(monthStart: monthStart)
    }
    func recallFeed(limit: Int) async throws -> [RecallFeedEntryDTO] {
        try await unimplemented.recallFeed(limit: limit)
    }
    func recallLanding(eventID: UUID) async throws -> RecallFeedEntryDTO {
        try await unimplemented.recallLanding(eventID: eventID)
    }
    func recordRecallReaction(eventID: UUID, reaction: RecallReaction) async throws {
        try await unimplemented.recordRecallReaction(eventID: eventID, reaction: reaction)
    }
    func upcomingNotifications(limit: Int) async throws -> [UpcomingNotificationDTO] {
        try await unimplemented.upcomingNotifications(limit: limit)
    }
    func rescheduleUpcoming(eventID: UUID, fireAt: Date) async throws {
        try await unimplemented.rescheduleUpcoming(eventID: eventID, fireAt: fireAt)
    }
    func vetoUpcoming(eventID: UUID) async throws {
        try await unimplemented.vetoUpcoming(eventID: eventID)
    }
    func sentNotifications(limit: Int) async throws -> [SentNotificationDTO] {
        try await unimplemented.sentNotifications(limit: limit)
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
    func reconcile(serverID: UUID) async {}
}

/// 시스템 캘린더·미리알림 등록 기록 스파이 — EventKit 은 절대 부르지 않는다.
private actor SpyCalendarSyncer: CalendarSyncing {
    var events: [(title: String, start: Date, allDay: Bool)] = []
    var reminders: [(title: String, due: Date?)] = []
    private var denyAccess = false

    func setDenyAccess() { denyAccess = true }

    func requestEventAccess() async throws {
        if denyAccess { throw CalendarSyncError.accessDenied }
    }
    func requestReminderAccess() async throws {
        if denyAccess { throw CalendarSyncError.accessDenied }
    }
    func createEvent(title: String, start: Date, end: Date?, allDay: Bool) async throws -> String {
        events.append((title, start, allDay))
        return "event-\(events.count)"
    }
    func createReminder(title: String, due: Date?) async throws -> String {
        reminders.append((title, due))
        return "reminder-\(reminders.count)"
    }
}
