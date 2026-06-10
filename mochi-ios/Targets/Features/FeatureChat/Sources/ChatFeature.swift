import ComposableArchitecture
import CoreAgentClient
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
        public var proposals: [ChatProposal] = []
        public var isStreaming: Bool = false

        public init(id: UUID, role: Role, text: String) {
            self.id = id
            self.role = role
            self.text = text
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
    }

    @Dependency(\.chatStreamClient) var chatStreamClient
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
            }
        }
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
            state.messages[id: lastID]?.proposals.append(proposal)
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
