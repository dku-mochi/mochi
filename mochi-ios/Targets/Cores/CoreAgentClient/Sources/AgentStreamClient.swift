import Foundation
import CoreDomain
import CoreNetworking

/// Gemini multimodal function-calling 스트림을 SSE/WebSocket으로 받는 클라이언트.
///
/// 백엔드 `/api/v1/captures/{id}/stream` 가 토큰/툴콜을 흘려보내는 동안,
/// iOS는 ``AgentEvent`` 를 받아 UI에 점진적으로 노출한다.
public protocol AgentStreamClient: Sendable {
    func stream(captureID: UUID) -> AsyncThrowingStream<AgentEvent, Error>
}

public enum AgentEvent: Equatable, Sendable, Hashable {
    case nodeEntered(AgentNode)
    case toolStarted(ToolCall.ToolName)
    case toolFinished(ToolCall)
    case partialSummary(String)
    case finalAnalysis(CaptureAnalysis)
    case failed(node: AgentNode, message: String)
}
