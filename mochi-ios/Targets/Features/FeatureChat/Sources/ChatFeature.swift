import ComposableArchitecture
import CoreAgentClient
import CoreDomain
import CoreIntegrations
import CoreNetworking
import CorePersistence
import Foundation

/// 대화 화면 — 기록 기반 질문·요청 대화 (검색이 아니라 "내 기억에게 묻는" 표면).
///
/// 탭 콘텐츠가 아니라 **NavigationStack push 풀스크린**이다(2026-06-10 구조 전환) —
/// 탭바 위에 입력 독이 얹히는 이중 바와 TabView 안 키보드 inset 버그를 구조에서 제거.
/// 랜딩(``ChatLandingFeature``)·홈 입력바가 ``Entry`` 를 들고 push 한다.
/// conversationID 는 클라이언트가 생성, 서버가 첫 메시지에서 암묵 생성한다.
/// 스트림은 ``ChatStreamClient`` (POST-as-SSE).
@Reducer
public struct ChatFeature: Sendable {
    /// push 진입 컨텍스트 — `.appeared` 에서 한 번 소비된다.
    public enum Entry: Equatable, Sendable {
        /// 랜딩 입력바 탭 — 활성 세션(30분 내) 복원 + 컴포저 자동 포커스.
        case blank
        /// 랜딩 칩·홈 입력바 — 항상 새 대화의 첫 메시지로 즉시 전송.
        case firstMessage(String)
        /// 지난 대화 선택 — 해당 대화 스냅샷 재개.
        case resume(UUID)
    }

    @ObservableState
    public struct State: Equatable, Sendable {
        public let entry: Entry
        /// `.appeared` 1회 소비 가드 — fullScreenCover(백탭 모달) dismiss 가 onAppear 를
        /// 재발화해도, 새 대화로 리셋된 빈 state 에 firstMessage 가 재전송되지 않게 한다.
        public var entryConsumed = false
        public var conversationID: UUID?
        public var messages: IdentifiedArrayOf<ChatMessage> = []
        public var draft: String = ""
        public var runPhase: RunPhase = .idle
        @Presents public var history: ChatHistoryFeature.State?

        public init(entry: Entry = .blank) {
            self.entry = entry
        }

        public var isEmpty: Bool { messages.isEmpty }
        public var isStreaming: Bool { runPhase == .streaming }
        public var canSubmit: Bool {
            !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && runPhase != .streaming && runPhase != .awaitingRemote
        }
    }

    public enum RunPhase: Equatable, Sendable {
        case idle
        case streaming
        /// 서버 run 이 아직 진행 중인 대화로 복귀 — 스냅샷 폴링이 답을 기다리는 중.
        /// 전송을 막는다(서버가 동시 run 을 409 로 거부) + 타이핑 점으로 진행을 보인다.
        case awaitingRemote
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
        case newConversationTapped
        case streamEvent(ChatStreamEvent)
        case streamFinished
        case streamFailed(String)
        /// push 진입 — ``Entry`` 소비 (비활성 30분 자동분리 판정 / 첫 메시지 전송 / 재개).
        case appeared
        /// 백그라운드 → 포그라운드 복귀 — SSE 가 끊겼어도 run 은 서버에서 완주하므로
        /// 스냅샷을 다시 읽는다 ("돌아왔더니 답이 와 있다"). running 이면 2초 폴링.
        case sceneActivated
        case historyButtonTapped
        case history(PresentationAction<ChatHistoryFeature.Action>)
        case snapshotLoaded(
            conversationID: UUID, messages: IdentifiedArrayOf<ChatMessage>, isRunning: Bool
        )
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
    @Dependency(\.calendarSyncer) var calendarSyncer
    @Dependency(\.date) var date
    @Dependency(\.uuid) var uuid
    @Dependency(\.continuousClock) var clock

    /// 비활성 자동분리 임계 — 30분 (journal 2026-06-10 플랜).
    static let sessionMaxIdleSeconds: TimeInterval = 30 * 60
    /// 복귀 폴링 상한 — run 60초 + stale 임계(90초) 여유. 2초 간격이라 최대 ~90초.
    static let maxSnapshotPolls = 45
    /// 원격 run 대기 중 타이핑 점 placeholder 의 고정 id — 폴링마다 새 id 면 스크롤이 튄다.
    static let remotePendingMessageID = UUID(uuidString: "00000000-0000-0000-0000-FEEDFEEDFEED")!

    private enum CancelID { case stream, snapshotPoll }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .sendTapped:
                guard state.canSubmit else { return .none }
                let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                state.draft = ""
                return sendMessage(text, state: &state)

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
                // Entry 는 1회 소비 — onAppear 재발화(상세·fullScreenCover dismiss)에 안전.
                guard !state.entryConsumed else { return .none }
                state.entryConsumed = true
                switch state.entry {
                case .blank:
                    guard let persisted = sessionStore.load() else { return .none }
                    guard date.now.timeIntervalSince(persisted.lastActivityAt) < Self.sessionMaxIdleSeconds
                    else {
                        // 30분 지남 — 조용히 새 대화 (사용자가 세션을 관리하지 않는다).
                        sessionStore.clear()
                        return .none
                    }
                    return loadSnapshot(persisted.conversationID)

                case let .firstMessage(text):
                    // 칩·홈 입력바 — 항상 새 대화 (state 가 push 마다 fresh 라 그대로 전송).
                    return sendMessage(text, state: &state)

                case let .resume(conversationID):
                    return loadSnapshot(conversationID)
                }

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

            case let .snapshotLoaded(conversationID, messages, isRunning):
                // 폴링 effect 의 in-flight 결과가 새 턴 시작 직후 도착하는 좁은 경합 가드 —
                // 스트리밍 중인 버블을 스냅샷이 덮어쓰지 않는다 (리뷰 P2).
                guard state.runPhase != .streaming else { return .none }
                state.conversationID = conversationID
                state.messages = messages
                // run 진행 중 복귀(스트림 끊긴 채 back→재진입 등) — 전송을 막고(서버 409)
                // 타이핑 점 placeholder 로 "답이 오는 중"을 보인다. 다음 스냅샷이 통째로 교체.
                state.runPhase = isRunning ? .awaitingRemote : .idle
                if isRunning {
                    var pending = ChatMessage(id: Self.remotePendingMessageID, role: .assistant, text: "")
                    pending.isStreaming = true
                    state.messages.append(pending)
                }
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
                let isRunning = snapshot.messages.last { $0.role == "user" }?.runStatus == "running"
                await send(
                    .snapshotLoaded(
                        conversationID: conversationID,
                        messages: Self.fold(snapshot.messages),
                        // 폴링 소진 시점엔 false 로 — awaitingRemote 에 영원히 잠기지 않게.
                        isRunning: isRunning && attempt < Self.maxSnapshotPolls
                    )
                )
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
                // 서버 먼저 — 비-404 실패(네트워크·5xx)면 로컬을 건드리지 않아 일시 소실이 없다.
                // 404(이미 서버에 없음)는 만료 카드로 보내되, 어느 쪽이든 로컬 미러는 **전부**
                // 거둔다 — pull↔upload 경합 복제 쌍(origin 행 + server-id PK 행)에서 한 행만
                // 지우면 남은 쪽이 영구 고아가 된다(서버에서 사라져 pull 도 dedup 도 다시는
                // 안 만짐). 2026-06-11 사용자 리포트: 삭제 카드 확정이 홈에 반영 안 됨.
                var notFound: APIErrorEnvelope?
                do {
                    try await apiClient.deleteMochiItem(mochiServerID: mochiItemID)
                } catch let error as APIErrorEnvelope where error.code.hasSuffix(".not_found") {
                    notFound = error
                }
                for localID in await Self.lookupLocalIDs(serverID: mochiItemID, repository: repository) {
                    try? await repository.delete(id: localID)
                }
                if let notFound { throw notFound }   // 기존 만료(expired) 분기 유지

            case let .updateItem(payload):
                let updated = try await apiClient.updateMochiItem(
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
                // PATCH 응답(서버 정본)을 로컬 미러에 직접 merge — 캘린더·홈은 로컬 Realm
                // 구동(observeChanges)인데 pullRemote 는 "없는 항목 채우기" 전용이고, 분석
                // SSE/폴링도 analysis 가 이미 붙은 항목은 건드리지 않아 여기 말곤 반영 경로가 없다
                // (날짜 수정이 캘린더에 안 보이던 2026-06-10 버그).
                await applyServerItem(updated)
                // 시스템 캘린더·미리알림 갱신은 SystemCalendarSyncEngine 이 위 로컬 merge 를
                // observeChanges 로 감지해 따라간다(§1.5 자동 관리) — call-site 배선 없음.

            case let .createSchedule(payload):
                // 분석 생략 직행 생성 (§5.2 예외). proposal id 가 Idempotency-Key — 재탭 멱등.
                _ = try await apiClient.ingestMochiItem(
                    MochiItemIngestRequest(
                        channel: .chat,
                        text: payload.text,
                        confirmedInstances: payload.instances.map {
                            ConfirmedInstanceIngestDTO(intentType: $0.intentType, payload: $0.payload)
                        },
                        // propose-시점 도출 메타 — confirmedInstances 와 함께 운반(§5.2 는 instance 재분석만 생략).
                        category: payload.category,
                        summary: payload.summary
                    ),
                    idempotencyKey: proposal.id.uuidString
                )
                await syncTrigger.pullRemote()   // 캘린더·검색에 바로 보이게 로컬 미러 채움
                // 시스템 캘린더(schedule→EKEvent)·미리알림(todo→EKReminder) 반영은
                // SystemCalendarSyncEngine 이 위 pullRemote 의 Realm 쓰기를 관찰해 수행한다
                // (§1.5 자동 관리 — call-site 등록 배선 제거, 2026-07-14). 엔진은 권한을 묻지 않는
                // 규약이라 **확정 순간인 여기서만 프롬프트**를 띄운다. 거부 시 기존 규약대로 failed
                // 카드 + 설정 링크 — 기록은 이미 생성됐고 ingest 멱등이라 재확정도, 권한 허용 후
                // 다음 동기화의 자동 따라잡기도 안전하다.
                //
                // **두 권한을 모두 확보한다** (2026-07-14 실기기 버그 fix): 이벤트/미리알림은 iOS 17+
                // 에서 별개 권한인데, proposal 에 있는 종류만 요청하면 캡처 분석發 todo 는 프롬프트
                // 지점이 없어 미리알림이 영영 notDetermined → 엔진이 조용히 대기만 했다("캘린더는
                // 되는데 미리알림은 안 됨"). 두 요청을 **독립적으로** 수행해 결과만 모은다 — 순차
                // try 는 첫 거부가 두 번째 프롬프트까지 막아 같은 버그가 재현된다(codex P1).
                // proposal 에 포함된 종류의 거부만 마지막에 failed 카드(설정 링크)로 올린다.
                if SystemCalendarAutoRegistrationPreference.load() {
                    let types = Set(payload.instances.map(\.intentType))
                    let eventDenied = (try? await calendarSyncer.requestEventAccess()) == nil
                    let reminderDenied = (try? await calendarSyncer.requestReminderAccess()) == nil
                    if (types.contains("schedule") && eventDenied)
                        || (types.contains("todo") && reminderDenied) {
                        throw CalendarSyncError.accessDenied
                    }
                }

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

            case let .rescheduleNotification(payload):
                // 서버 예정 알림 시각 이동 — 홈탭 reschedule 과 같은 REST. pending 아니면(발송·취소됨)
                // 404 → 아래 catch 가 .expired 로 만료 카드 처리.
                try await apiClient.rescheduleUpcoming(eventID: payload.eventID, fireAt: payload.fireAt)

            case let .cancelNotification(payload):
                // 끄기 — kind 별 cascade(deadline/nudge=시리즈 정지, spaced=이번 회차)는 서버 veto 가 처리.
                try await apiClient.vetoUpcoming(eventID: payload.eventID)
            }
            return .confirmed
        } catch let error as APIErrorEnvelope where error.code.hasSuffix(".not_found") {
            return .expired
        } catch ReminderSchedulingError.permissionDenied {
            return .failed(reason: "알림 권한이 꺼져 있어요", needsNotificationPermission: true)
        } catch ReminderSchedulingError.invalidFireDate {
            return .failed(reason: "이미 지난 시간이에요", needsNotificationPermission: false)
        } catch CalendarSyncError.accessDenied {
            return .failed(reason: "캘린더·미리알림 권한이 꺼져 있어요", needsNotificationPermission: true)
        } catch {
            return .failed(reason: "잠시 후 다시 시도해주세요", needsNotificationPermission: false)
        }
    }

    /// PATCH 응답(갱신된 서버 항목)을 로컬 Realm 미러에 merge 한다.
    ///
    /// 콘텐츠(text/userMemo)와 분석(summary/instances — 날짜 payload 포함)만 서버 값으로 갈고,
    /// 로컬 전용 필드(userTitle·syncState·이미지 경로·createdAt)는 보존한다.
    /// `updatedAt` 은 bump — 분석 SSE/폴링의 세대 가드가 stale 결과로 되덮지 않게.
    private func applyServerItem(_ dto: MochiItemDTO) async {
        guard let localID = await Self.lookupLocalID(serverID: dto.id, repository: repository),
              let current = try? await repository.find(id: localID)
        else {
            // 로컬 미러에 아직 없는 항목(재설치 직후 등) — pull 의 "없는 항목 insert" 가 채운다.
            await syncTrigger.pullRemote()
            return
        }
        let source = IngestSource(
            id: current.source.id,
            channel: current.source.channel,
            url: current.source.url,
            text: dto.text,
            imageRefs: current.source.imageRefs,
            userMemo: dto.userMemo,
            capturedAt: current.source.capturedAt
        )
        let merged = MochiItem(
            source: source,
            analysis: dto.lifecycleKind == "analyzed" ? dto.toMochiItemAnalysis() : current.analysis,
            lifecycleState: current.lifecycleState,
            syncState: current.syncState,
            userTitle: current.userTitle,
            createdAt: current.createdAt,
            updatedAt: date.now
        )
        try? await repository.upsert(merged)
    }

    /// 서버 id → 로컬 Realm id (조회만).
    /// 서버에서 pull 된 항목은 로컬 id == 서버 id, 로컬 생성 항목은 syncState 의 serverID 로 매칭.
    private static func lookupLocalID(
        serverID: UUID, repository: any MochiItemRepository
    ) async -> MochiItem.ID? {
        await lookupLocalIDs(serverID: serverID, repository: repository).first
    }

    /// 서버 id 로 매핑되는 로컬 행 **전부**. pull↔upload 경합 복제 쌍이면 둘 다 돌려준다.
    /// origin 행(로컬 PK + `syncState.uploaded(serverID)`)을 server-id PK 행보다 앞에 둔다 —
    /// MochiItemSyncWorker dedup 과 같은 "origin 행이 정본" 규약. 복제 쌍에서 server-id PK 행에
    /// 수정을 merge 하면 다음 pull 의 dedup 정리가 그 행을 지워 수정이 증발한다.
    private static func lookupLocalIDs(
        serverID: UUID, repository: any MochiItemRepository
    ) async -> [MochiItem.ID] {
        var ids: [MochiItem.ID] = []
        let all = (try? await repository.listRecent(limit: 2000)) ?? []
        for item in all where item.id != serverID {
            if case let .uploaded(id, _) = item.syncState, id == serverID { ids.append(item.id) }
        }
        if let direct = try? await repository.find(id: serverID), direct != nil { ids.append(serverID) }
        return ids
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
