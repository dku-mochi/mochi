import Foundation
import ComposableArchitecture
import CoreDomain
import CorePersistence
import CoreAgentClient

/// 새 캡처를 받아 백엔드 agent loop의 스트리밍 분석 결과를 점진적으로 표시한다.
@Reducer
public struct CaptureFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        public var source: CaptureSource
        public var currentNode: AgentNode = .ingested
        public var partialSummary: String = ""
        public var toolCalls: [ToolCall] = []
        public var finalAnalysis: CaptureAnalysis?
        public var lastError: String?

        public init(source: CaptureSource) {
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
    @Dependency(\.captureRepository)  var repository

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .startAnalysis:
                let captureID = state.source.id
                return .run { send in
                    do {
                        for try await event in agentStream.stream(captureID: captureID) {
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
                let updated = Capture(
                    source: state.source,
                    analysis: analysis,
                    lifecycleState: .active,
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
