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
    @Dependency(\.mochiAPIClient) var apiClient
    @Dependency(\.mochiItemRepository) var repository
    @Dependency(\.syncTrigger) var syncTrigger
    @Dependency(\.reminderScheduler) var reminderScheduler
    @Dependency(\.uuid) var uuid

    private enum CancelID { case stream }

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
                return .cancel(id: CancelID.stream)

            case let .streamEvent(event):
                reduce(event: event, into: &state)
                return .none

            case .streamFinished:
                finishStreaming(&state)
                state.runPhase = .idle
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
                return .none

            case let .proposalResolved(messageID, proposalID, status):
                state.messages[id: messageID]?.proposals[id: proposalID]?.status = status
                return .none

            case .delegate:
                return .none
            }
        }
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
                let source = IngestSource(id: uuid(), channel: .chat, text: text)
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
        state.messages.append(ChatMessage(id: uuid(), role: .user, text: text))
        var assistant = ChatMessage(id: uuid(), role: .assistant, text: "")
        assistant.isStreaming = true
        state.messages.append(assistant)
        return .run { send in
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
    }

    private func reduce(event: ChatStreamEvent, into state: inout State) {
        guard let lastID = state.messages.last?.id,
              state.messages[id: lastID]?.role == .assistant
        else { return }
        switch event {
        case let .messageDelta(delta):
            state.messages[id: lastID]?.text.append(delta)
        case let .toolStarted(name, label):
            state.messages[id: lastID]?.activeToolLabel = label
            state.messages[id: lastID]?.toolSteps.append(ToolStep(name: name, label: label))
        case let .toolFinished(name, summary):
            state.messages[id: lastID]?.activeToolLabel = nil
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
