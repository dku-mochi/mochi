import Foundation

/// 도메인 레이어가 표현하는 에러 — UI/Persistence/Network 모두에서 재사용.
public enum DomainError: Error, Equatable, Sendable {
    case validation(String)
    case notFound(entity: String, id: String)
    case persistenceFailed(reason: String)
    case networkFailed(reason: String, transientRetryAfter: TimeInterval?)
    case agentFailed(node: AgentNode, reason: String)
    case lifecycleTransition(LifecycleTransitionError)
    case unauthorized
    case cancelled
}
