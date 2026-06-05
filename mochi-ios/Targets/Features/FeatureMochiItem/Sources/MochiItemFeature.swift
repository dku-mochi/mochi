import Foundation
import ComposableArchitecture
import CoreDomain
import CorePersistence
import CoreAgentClient

/// 새 캡처를 받아 백엔드 agent loop의 스트리밍 분석 결과를 점진적으로 표시한다.
@Reducer
public struct MochiItemFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        public var source: IngestSource
        public var currentNode: AgentNode = .ingested
        public var partialSummary: String = ""
        public var toolCalls: [ToolCall] = []
        public var finalAnalysis: MochiItemAnalysis?
        public var lastError: String?

        public init(source: IngestSource) {
            self.source = source
        }
    }

    public enum Action: Sendable {
        case startAnalysis
        case stopAnalysis
        case event(AgentEvent)
        case streamFinished
        case streamFailed(String)
    }

    public enum CancelID: Hashable { case stream }

    @Dependency(\.agentStreamClient) var agentStream
    @Dependency(\.mochiItemRepository)  var repository

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .startAnalysis:
                // ⚠️ 현재 미배선(dead) — `MainTabFeature.mochiItem` 를 세팅하는 경로가 없다. 활성화 시 2가지 선결:
                //  (1) stream 인자는 **serverID** 여야 한다(`LiveAgentStreamClient` 규약 — 로컬 id 는 404).
                //      State 에 serverID 를 실어 전달하라(아래 `source.id` 는 로컬 id).
                //  (2) 완료 적용(`streamFinished` 의 upsert)은 `MochiItemSyncWorker` 단일 소유(handoff §3.3).
                //      이 Feature 는 진행표시(node/partial)만 맡고 완료 write 는 빼야 이중 적용을 피한다.
                let mochiItemID = state.source.id
                return .run { send in
                    do {
                        for try await event in agentStream.stream(mochiItemID: mochiItemID) {
                            await send(.event(event))
                        }
                        await send(.streamFinished)
                    } catch {
                        await send(.streamFailed(String(describing: error)))
                    }
                }
                .cancellable(id: CancelID.stream)

            case .stopAnalysis:
                return .cancel(id: CancelID.stream)

            case let .event(event):
                switch event {
                case let .nodeEntered(node):
                    state.currentNode = node
                case let .toolStarted(name):
                    // placeholder ToolCall 추가 후 .toolFinished 시 교체
                    _ = name
                case let .toolFinished(call):
                    state.toolCalls.append(call)
                case let .partialSummary(text):
                    state.partialSummary += text
                case let .finalAnalysis(analysis):
                    state.finalAnalysis = analysis
                case let .failed(node, message):
                    state.lastError = "[\(node.rawValue)] \(message)"
                }
                return .none

            case .streamFinished:
                guard let analysis = state.finalAnalysis else { return .none }
                let updated = MochiItem(
                    source: state.source,
                    analysis: analysis,
                    lifecycleState: .analyzed,
                    syncState: .uploaded(serverID: state.source.id, at: Date())
                )
                return .run { _ in try await repository.upsert(updated) }

            case let .streamFailed(message):
                state.lastError = message
                return .none
            }
        }
    }
}

// Dependency key는 CoreAgentClient/Sources/AgentStreamClientDI.swift에서 정의.
