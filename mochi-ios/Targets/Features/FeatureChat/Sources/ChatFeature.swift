import ComposableArchitecture
import CoreAgentClient
import CoreDomain
import CoreNetworking
import CorePersistence
import Foundation

/// 채팅 탭 — 기록 기반 질문·요청 대화 (검색이 아니라 "내 기억에게 묻는" 표면).
///
/// 탭 진입 = 곧장 대화 화면(세션 리스트 아님 — 짧은 과업형 대화라 재개 빈도가 낮다).
/// conversationID 는 클라이언트가 생성, 서버가 첫 메시지에서 암묵 생성한다.
/// 스트림은 ``ChatStreamClient`` (POST-as-SSE) — 히스토리·세션 자동분리는 후속 PR.
@Reducer
public struct ChatFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        public var conversationID: UUID?
        public var messages: IdentifiedArrayOf<ChatMessage> = []
        public var draft: String = ""
        public var runPhase: RunPhase = .idle
        @Presents public var history: ChatHistoryFeature.State?

        public init() {}

        public var isEmpty: Bool { messages.isEmpty }
        public var isStreaming: Bool { runPhase == .streaming }
        public var canSubmit: Bool {
            !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && runPhase != .streaming
        }
    }

    public enum RunPhase: Equatable, Sendable {
        case idle
        case streaming
        case failed(String)
    }

    /// 화면 전용 메시지 모델 — 서버 Message 와 1:1 이 아니라, 한 turn 의 assistant 답변에
    /// 툴 진행·출처·proposal 을 흡수한 렌더 단위다(스냅샷 재조회 시 서버 행들을 이 형태로 접는다).
    public struct ChatMessage: Equatable, Sendable, Identifiable {
        public enum Role: Equatable, Sendable {
            case user
            case assistant
        }

        public let id: UUID
        public var role: Role
        public var text: String
        /// 완료된 툴 스텝 — 답변 위 접힌 "과정 보기" 의 데이터.
        public var toolSteps: [ToolStep] = []
        /// 지금 돌고 있는 툴의 동사형 카피 (예: "기록을 뒤지고 있어요"). 스트리밍 중에만.
        public var activeToolLabel: String?
        public var citations: [ChatCitation] = []
        public var proposals: IdentifiedArrayOf<ProposalCard> = []
        public var isStreaming: Bool = false

        public init(id: UUID, role: Role, text: String) {
            self.id = id
            self.role = role
            self.text = text
        }
    }

    /// proposal + 카드 상태머신. 쓰기는 전부 여기서만 — LLM 루프는 read-only (서버 설계).
    public struct ProposalCard: Equatable, Sendable, Identifiable {
        public var proposal: ChatProposal
        public var status: Status

        public var id: UUID { proposal.id }

        public init(proposal: ChatProposal, status: Status = .pending) {
            self.proposal = proposal
            self.status = status
        }

        public enum Status: Equatable, Sendable {
            case pending
            case confirming
            case confirmed
            case cancelled
            /// 확정 시점 404 — 카드 생성~확정 사이 대상이 사라짐(reanalyze delete-reinsert 포함).
            case expired
            case failed(reason: String, needsNotificationPermission: Bool)
        }
    }

    public struct ToolStep: Equatable, Sendable {
        public let name: String
        public let label: String
        public var summary: String?

        public init(name: String, label: String, summary: String? = nil) {
            self.name = name
            self.label = label
            self.summary = summary
        }
    }

    public enum Action: BindableAction, Sendable {
        case binding(BindingAction<State>)
        case sendTapped
        case chipTapped(String)
        /// 홈 입력바 라우팅 진입점 — 항상 새 대화의 첫 메시지로 (MainTab 이 send, 후속 PR 배선).
        case startConversation(firstMessage: String)
        case newConversationTapped
        case streamEvent(ChatStreamEvent)
        case streamFinished
        case streamFailed(String)
        /// 화면 진입(탭 전환 포함) — 비활성 30분 자동분리 판정 + 이전 세션 스냅샷 복귀.
        case appeared
        /// 백그라운드 → 포그라운드 복귀 — SSE 가 끊겼어도 run 은 서버에서 완주하므로
        /// 스냅샷을 다시 읽는다 ("돌아왔더니 답이 와 있다"). running 이면 2초 폴링.
        case sceneActivated
        case historyButtonTapped
        case history(PresentationAction<ChatHistoryFeature.Action>)
        case snapshotLoaded(conversationID: UUID, messages: IdentifiedArrayOf<ChatMessage>)
        case snapshotLoadFailed
        /// 근거 미니카드 탭 — 서버 id 를 로컬 항목으로 해석해 상위(MainTab)가 상세를 띄운다.
        case citationTapped(ChatCitation)
        case proposalConfirmTapped(messageID: UUID, proposalID: UUID)
        case proposalCancelTapped(messageID: UUID, proposalID: UUID)
        case proposalResolved(messageID: UUID, proposalID: UUID, status: ProposalCard.Status)
        case delegate(Delegate)

        public enum Delegate: Equatable, Sendable {
            /// 로컬 Realm id 로 해석 완료된 상세 진입 요청 (DetailFeature 는 로컬 id 로 로드한다).
            case openItemRequested(MochiItem.ID)
        }
    }

    @Dependency(\.chatStreamClient) var chatStreamClient
    @Dependency(\.chatAPIClient) var chatAPIClient
    @Dependency(\.chatSessionStore) var sessionStore
    @Dependency(\.mochiAPIClient) var apiClient
    @Dependency(\.mochiItemRepository) var repository
    @Dependency(\.syncTrigger) var syncTrigger
    @Dependency(\.reminderScheduler) var reminderScheduler
    @Dependency(\.date) var date
    @Dependency(\.uuid) var uuid
    @Dependency(\.continuousClock) var clock

    /// 비활성 자동분리 임계 — 30분 (journal 2026-06-10 플랜).
    static let sessionMaxIdleSeconds: TimeInterval = 30 * 60
    /// 복귀 폴링 상한 — run 60초 + stale 임계(90초) 여유. 2초 간격이라 최대 ~90초.
    static let maxSnapshotPolls = 45

    private enum CancelID { case stream, snapshotPoll }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .sendTapped:
                let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, state.runPhase != .streaming else { return .none }
                state.draft = ""
                return sendMessage(text, state: &state)

            case let .chipTapped(question):
                guard state.runPhase != .streaming else { return .none }
                return sendMessage(question, state: &state)

            case let .startConversation(firstMessage):
                // 홈에서 넘어온 첫 메시지 — 진행 중 스트림은 끊고 항상 새 대화로.
                state.conversationID = nil
                state.messages.removeAll()
                state.runPhase = .idle
                return sendMessage(firstMessage, state: &state)

            case .newConversationTapped:
                state.conversationID = nil
                state.messages.removeAll()
                state.draft = ""
                state.runPhase = .idle
                sessionStore.clear()
                return .merge(
                    .cancel(id: CancelID.stream),
                    .cancel(id: CancelID.snapshotPoll)
                )

            case .appeared:
                // 이미 대화가 떠 있으면 그대로 — 분리 판정은 빈 화면 진입에만.
                guard state.conversationID == nil, state.messages.isEmpty else { return .none }
                guard let persisted = sessionStore.load() else { return .none }
                guard date.now.timeIntervalSince(persisted.lastActivityAt) < Self.sessionMaxIdleSeconds else {
                    // 30분 지남 — 조용히 새 대화 (사용자가 세션을 관리하지 않는다).
                    sessionStore.clear()
                    return .none
                }
                return loadSnapshot(persisted.conversationID)

            case .sceneActivated:
                // 스트림이 살아 있으면(짧은 백그라운드) 건드리지 않는다 — 끊겼을 때만 서버 정본 재조회.
                guard let conversationID = state.conversationID, state.runPhase != .streaming
                else { return .none }
                return loadSnapshot(conversationID)

            case .historyButtonTapped:
                state.history = ChatHistoryFeature.State()
                return .none

            case let .history(.presented(.delegate(.conversationSelected(conversationID)))):
                state.history = nil
                return .merge(
                    .cancel(id: CancelID.stream),
                    loadSnapshot(conversationID)
                )

            case let .history(.presented(.deleteSwiped(deletedID))):
                // 지금 열려 있는 대화를 지웠으면 본 화면도 리셋 — 남겨두면 다음 전송이
                // soft-deleted PK 에 암묵 생성을 시도해 409 로 오수렴한다 (리뷰 P2).
                guard deletedID == state.conversationID else { return .none }
                state.conversationID = nil
                state.messages.removeAll()
                state.runPhase = .idle
                sessionStore.clear()
                return .merge(
                    .cancel(id: CancelID.stream),
                    .cancel(id: CancelID.snapshotPoll)
                )

            case .history:
                return .none

            case let .snapshotLoaded(conversationID, messages):
                // 폴링 effect 의 in-flight 결과가 새 턴 시작 직후 도착하는 좁은 경합 가드 —
                // 스트리밍 중인 버블을 스냅샷이 덮어쓰지 않는다 (리뷰 P2).
                guard state.runPhase != .streaming else { return .none }
                state.conversationID = conversationID
                state.messages = messages
                state.runPhase = .idle
                sessionStore.save(conversationID, date.now)
                return .none

            case .snapshotLoadFailed:
                // 404(삭제됨)·네트워크 실패 — 새 대화로 조용히 폴백.
                sessionStore.clear()
                return .none

            case let .streamEvent(event):
                reduce(event: event, into: &state)
                return .none

            case .streamFinished:
                finishStreaming(&state)
                state.runPhase = .idle
                if let conversationID = state.conversationID {
                    sessionStore.save(conversationID, date.now)   // 답변 수신도 활동
                }
                return .none

            case let .streamFailed(message):
                finishStreaming(&state)
                state.runPhase = .failed(message)
                return .none

            case let .citationTapped(citation):
                return .run { [repository, syncTrigger] send in
                    if let localID = await Self.resolveLocalID(
                        serverID: citation.mochiItemID, repository: repository, syncTrigger: syncTrigger
                    ) {
                        await send(.delegate(.openItemRequested(localID)))
                    }
                    // 미해석(서버에서 삭제된 출처 등) — 카드는 출처 스냅샷으로만 남는다.
                }

            case let .proposalConfirmTapped(messageID, proposalID):
                guard let card = state.messages[id: messageID]?.proposals[id: proposalID],
                      card.status == .pending
                else { return .none }
                state.messages[id: messageID]?.proposals[id: proposalID]?.status = .confirming
                return .run { send in
                    let status = await execute(card.proposal)
                    await send(
                        .proposalResolved(messageID: messageID, proposalID: proposalID, status: status)
                    )
                }

            case let .proposalCancelTapped(messageID, proposalID):
                guard state.messages[id: messageID]?.proposals[id: proposalID]?.status == .pending
                else { return .none }
                state.messages[id: messageID]?.proposals[id: proposalID]?.status = .cancelled
                return persistProposalStatus(state, proposalID: proposalID, status: .cancelled)

            case let .proposalResolved(messageID, proposalID, status):
                state.messages[id: messageID]?.proposals[id: proposalID]?.status = status
                // 확정 성공만 영속 — expired/failed 는 재확정 시 결정적으로 재현되는 일시 상태.
                guard status == .confirmed else { return .none }
                return persistProposalStatus(state, proposalID: proposalID, status: .confirmed)

            case .delegate:
                return .none
            }
        }
        .ifLet(\.$history, action: \.history) { ChatHistoryFeature() }
    }

    /// 카드 상태 서버 영속 — best-effort: 실패해도 로컬 상태는 이미 바뀌었고(행동 자체는
    /// 실행 완료), 다음 스냅샷에서 pending 으로 보이는 옛 증상으로 되돌아갈 뿐이라 막지 않는다.
    private func persistProposalStatus(
        _ state: State, proposalID: UUID, status: ChatProposalStatusUpdate
    ) -> Effect<Action> {
        guard let conversationID = state.conversationID else { return .none }
        return .run { _ in
            try? await chatAPIClient.setProposalStatus(
                conversationID: conversationID, proposalID: proposalID, status: status
            )
        }
    }

    // MARK: - 스냅샷 복귀 (히스토리 재개·자동분리 내 복귀 공용)

    /// 스냅샷 1회 조회 + 마지막 run 이 running 이면 2초 폴링 — run 은 서버에서 완주하므로
    /// (생성/전달 분리) 폴링은 유한하다(60초 상한 + stale 90초 lazy repair).
    private func loadSnapshot(_ conversationID: UUID) -> Effect<Action> {
        .run { send in
            for attempt in 0...Self.maxSnapshotPolls {
                let snapshot: ChatSnapshotDTO
                do {
                    snapshot = try await chatAPIClient.conversationSnapshot(id: conversationID)
                } catch {
                    await send(.snapshotLoadFailed)
                    return
                }
                await send(
                    .snapshotLoaded(
                        conversationID: conversationID,
                        messages: Self.fold(snapshot.messages)
                    )
                )
                let isRunning = snapshot.messages.last { $0.role == "user" }?.runStatus == "running"
                guard isRunning, attempt < Self.maxSnapshotPolls else { return }
                try await clock.sleep(for: .seconds(2))
            }
        }
        .cancellable(id: CancelID.snapshotPoll, cancelInFlight: true)
    }

    /// 서버 메시지 행(user/tool/assistant) → 렌더 단위 접기.
    /// tool 행들은 다음 assistant 행의 "과정 보기"로 흡수되고, assistant 없이 끝난 턴
    /// (실패 run)의 tool 행은 버린다 — 빈 껍데기 버블 금지(스트림 쪽과 동일 규칙).
    static func fold(_ rows: [ChatSnapshotMessageDTO]) -> IdentifiedArrayOf<ChatMessage> {
        var result: IdentifiedArrayOf<ChatMessage> = []
        var pendingSteps: [ToolStep] = []
        for row in rows {
            switch row.role {
            case "user":
                pendingSteps = []
                result.append(ChatMessage(id: row.id, role: .user, text: row.content ?? ""))
            case "tool":
                // label·summary 둘 다 비면(검증 실패 propose 등) "과정 보기"에 빈 줄만 남는다 — 버린다.
                guard row.toolLabel?.isEmpty == false || row.toolSummary?.isEmpty == false else { break }
                pendingSteps.append(
                    ToolStep(
                        name: row.toolName ?? "tool",
                        label: row.toolLabel ?? "",
                        summary: row.toolSummary
                    )
                )
            case "assistant":
                var message = ChatMessage(id: row.id, role: .assistant, text: row.content ?? "")
                message.toolSteps = pendingSteps
                pendingSteps = []
                message.citations = row.citations.map {
                    ChatCitation(
                        index: $0.index, mochiItemID: $0.mochiItemID, title: $0.title, snippet: $0.snippet
                    )
                }
                // 확정/취소는 서버 proposals.status 가 단일 원천 — 없으면 pending.
                // (영속은 확정 실행 성공 후 setProposalStatus 가 기록한다.)
                message.proposals = IdentifiedArray(
                    uniqueElements: row.proposals.compactMap { envelope -> ProposalCard? in
                        guard
                            let payload = (try? JSONSerialization.jsonObject(with: envelope.payloadJSON))
                                as? [String: Any],
                            let proposal = ChatProposal(id: envelope.id, type: envelope.type, payload: payload)
                        else { return nil }
                        let status: ProposalCard.Status = switch envelope.status {
                        case "confirmed": .confirmed
                        case "cancelled": .cancelled
                        default: .pending
                        }
                        return ProposalCard(proposal: proposal, status: status)
                    }
                )
                result.append(message)
            default:
                break
            }
        }
        return result
    }

    // MARK: - Proposal 확정 실행 (5경로 — propose.py 의 실행 경로 매핑과 1:1)

    /// 확정 탭 → REST/로컬 실행. 결과를 카드 상태로 변환한다 — 404 는 에러가 아니라
    /// "카드 만료"(생성~확정 사이 대상 소멸, reanalyze delete-reinsert known-drift 포함).
    private func execute(_ proposal: ChatProposal) async -> ProposalCard.Status {
        do {
            switch proposal.action {
            case let .deleteItem(mochiItemID):
                try await apiClient.deleteMochiItem(mochiServerID: mochiItemID)
                // 로컬 미러도 정리 — 남겨두면 홈/검색이 서버와 어긋난다 (DetailFeature 삭제와 동일).
                if let localID = await Self.lookupLocalID(serverID: mochiItemID, repository: repository) {
                    try? await repository.delete(id: localID)
                }

            case let .updateItem(payload):
                try await apiClient.updateMochiItem(
                    mochiServerID: payload.mochiItemID,
                    MochiItemUpdateRequestDTO(
                        text: payload.text,
                        userMemo: payload.userMemo,
                        summary: payload.summary,
                        instances: payload.instanceChanges.map {
                            InstanceChangeRequestDTO(
                                instanceID: $0.instanceID,
                                payload: $0.payload,
                                label: $0.label,
                                lifecycleKind: $0.lifecycleTo,
                                archiveReason: $0.archiveReason
                            )
                        }
                    )
                )
                // 서버가 정본 — 로컬 미러 갱신은 SSE/폴링·pull 의 몫이지만, 즉시성 위해 pull 1회.
                await syncTrigger.pullRemote()

            case let .createSchedule(payload):
                // 분석 생략 직행 생성 (§5.2 예외). proposal id 가 Idempotency-Key — 재탭 멱등.
                _ = try await apiClient.ingestMochiItem(
                    MochiItemIngestRequest(
                        channel: .chat,
                        text: payload.text,
                        confirmedInstances: payload.instances.map {
                            ConfirmedInstanceIngestDTO(intentType: $0.intentType, payload: $0.payload)
                        }
                    ),
                    idempotencyKey: proposal.id.uuidString
                )
                await syncTrigger.pullRemote()   // 캘린더·검색에 바로 보이게 로컬 미러 채움

            case let .createMemo(text):
                // 일반 캡처와 동일 경로: 로컬 upsert(.pendingUpload) → worker 가 ingest(분석 경유).
                // 로컬 id = proposal.id — 스냅샷 복귀 후 재확정해도 upsert 가 멱등 (리뷰 P2).
                let source = IngestSource(id: proposal.id, channel: .chat, text: text)
                try await repository.upsert(MochiItem(source: source))
                await syncTrigger.runOnce()

            case let .reminder(payload):
                try await reminderScheduler.schedule(
                    id: proposal.id,
                    title: payload.title,
                    fireAt: payload.fireAt,
                    relatedMochiItemID: payload.relatedMochiItemID
                )
            }
            return .confirmed
        } catch let error as APIErrorEnvelope where error.code.hasSuffix(".not_found") {
            return .expired
        } catch ReminderSchedulingError.permissionDenied {
            return .failed(reason: "알림 권한이 꺼져 있어요", needsNotificationPermission: true)
        } catch ReminderSchedulingError.invalidFireDate {
            return .failed(reason: "이미 지난 시간이에요", needsNotificationPermission: false)
        } catch {
            return .failed(reason: "잠시 후 다시 시도해주세요", needsNotificationPermission: false)
        }
    }

    /// 서버 id → 로컬 Realm id (조회만).
    /// 서버에서 pull 된 항목은 로컬 id == 서버 id, 로컬 생성 항목은 syncState 의 serverID 로 매칭.
    private static func lookupLocalID(
        serverID: UUID, repository: any MochiItemRepository
    ) async -> MochiItem.ID? {
        if let direct = try? await repository.find(id: serverID), direct != nil { return serverID }
        let all = (try? await repository.listRecent(limit: 2000)) ?? []
        return all.first {
            if case let .uploaded(id, _) = $0.syncState { return id == serverID }
            return false
        }?.id
    }

    /// ``lookupLocalID`` + 미발견 시(이 기기에 아직 없음) pullRemote 후 1회 재시도.
    private static func resolveLocalID(
        serverID: UUID, repository: any MochiItemRepository, syncTrigger: any SyncTrigger
    ) async -> MochiItem.ID? {
        if let found = await lookupLocalID(serverID: serverID, repository: repository) { return found }
        await syncTrigger.pullRemote()
        return await lookupLocalID(serverID: serverID, repository: repository)
    }

    // MARK: - Helpers

    private func sendMessage(_ text: String, state: inout State) -> Effect<Action> {
        let conversationID = state.conversationID ?? uuid()
        state.conversationID = conversationID
        state.runPhase = .streaming
        sessionStore.save(conversationID, date.now)   // 활동 시각 갱신 — 자동분리 기준점
        state.messages.append(ChatMessage(id: uuid(), role: .user, text: text))
        var assistant = ChatMessage(id: uuid(), role: .assistant, text: "")
        assistant.isStreaming = true
        state.messages.append(assistant)
        return .merge(
            .cancel(id: CancelID.snapshotPoll),   // 새 턴 시작 — 복귀 폴링과 경합 금지
            .run { send in
                do {
                    for try await event in chatStreamClient.send(conversationID: conversationID, text: text) {
                        await send(.streamEvent(event))
                    }
                    await send(.streamFinished)
                } catch is CancellationError {
                    // 새 대화 전환 등 의도적 취소 — 실패 아님.
                } catch {
                    await send(.streamFailed(error.localizedDescription))
                }
            }
            .cancellable(id: CancelID.stream, cancelInFlight: true)
        )
    }

    private func reduce(event: ChatStreamEvent, into state: inout State) {
        guard let lastID = state.messages.last?.id,
              state.messages[id: lastID]?.role == .assistant
        else { return }
        switch event {
        case let .messageDelta(delta):
            state.messages[id: lastID]?.text.append(delta)
            // 본문이 시작되면 pill 을 내린다 — 텍스트가 진행 표시를 대체.
            state.messages[id: lastID]?.activeToolLabel = nil
        case let .toolStarted(name, label):
            state.messages[id: lastID]?.activeToolLabel = label
            state.messages[id: lastID]?.toolSteps.append(ToolStep(name: name, label: label))
        case let .toolFinished(name, summary):
            // pill 은 유지 — 즉시 내리면 "찾고 있어요 → (깜빡) … → 다음 툴" 로 어색하다.
            // 다음 toolStarted 가 교체하거나 첫 본문 delta 가 내린다 (2026-06-10 피드백).
            if let stepIndex = state.messages[id: lastID]?.toolSteps.lastIndex(where: { $0.name == name }) {
                state.messages[id: lastID]?.toolSteps[stepIndex].summary = summary
            }
        case let .citation(citation):
            state.messages[id: lastID]?.citations.append(citation)
        case let .proposal(proposal):
            state.messages[id: lastID]?.proposals.append(ProposalCard(proposal: proposal))
        case .done:
            state.messages[id: lastID]?.isStreaming = false
        }
    }

    /// 스트림 종료(정상·실패 공통) — 조립 중이던 assistant 버블의 진행 표시를 내린다.
    private func finishStreaming(_ state: inout State) {
        guard let lastID = state.messages.last?.id,
              state.messages[id: lastID]?.role == .assistant
        else { return }
        state.messages[id: lastID]?.isStreaming = false
        state.messages[id: lastID]?.activeToolLabel = nil
        // 한 글자도 못 받고 끝났으면 빈 버블을 남기지 않는다 (실패 안내는 runPhase 가 담당).
        // toolSteps 만 있는 경우도 제거 — "과정 보기" UI 가 없는 동안엔 시각적으로 빈 껍데기다.
        if let message = state.messages[id: lastID], message.text.isEmpty {
            state.messages.remove(id: lastID)
        }
    }
}
