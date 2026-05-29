import Foundation

/// 백엔드 agent loop가 한 캡처를 분석할 때의 실행 trace.
///
/// 같은 그래프(`AgentNode`) 노드들이 백엔드 `app/modules/agent` 에서도 정의된다 —
/// iOS는 진행 상태를 시각화하고, 디버깅 시 사용자에게 노출하기 위해 동일한 enum을 사용한다.
public struct AgentRun: Equatable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let mochiItemID: UUID
    public var currentNode: AgentNode
    public var toolCalls: [ToolCall]
    public var totalTokens: Int
    public var totalLatencyMs: Int
    public var startedAt: Date
    public var endedAt: Date?

    public init(
        id: UUID = UUID(),
        mochiItemID: UUID,
        currentNode: AgentNode = .ingested,
        toolCalls: [ToolCall] = [],
        totalTokens: Int = 0,
        totalLatencyMs: Int = 0,
        startedAt: Date = .init(),
        endedAt: Date? = nil
    ) {
        self.id = id
        self.mochiItemID = mochiItemID
        self.currentNode = currentNode
        self.toolCalls = toolCalls
        self.totalTokens = totalTokens
        self.totalLatencyMs = totalLatencyMs
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// Agent state graph 노드. 백엔드 `agent/orchestrator.py` 와 동일한 이름을 유지한다.
public enum AgentNode: String, Codable, Sendable, CaseIterable {
    case ingested
    case normalized
    case analyzed
    case routed
    case persisted
    case indexed
    case synced
    case failed
}

public struct ToolCall: Equatable, Sendable, Hashable, Codable {
    public let name: ToolName
    public let inputDigest: String      // 입력의 hash — 원본은 백엔드만 보관
    public let outputDigest: String?
    public let tokensIn: Int
    public let tokensOut: Int
    public let latencyMs: Int
    public let succeeded: Bool

    public init(
        name: ToolName,
        inputDigest: String,
        outputDigest: String?,
        tokensIn: Int,
        tokensOut: Int,
        latencyMs: Int,
        succeeded: Bool
    ) {
        self.name = name
        self.inputDigest = inputDigest
        self.outputDigest = outputDigest
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.latencyMs = latencyMs
        self.succeeded = succeeded
    }

    public enum ToolName: String, Codable, Sendable, CaseIterable {
        case multimodalAnalyze
        case ocrFallback
        case webFetch
        case embed
        case hybridSearch
        case calendarSync
    }
}
