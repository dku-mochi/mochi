import Dependencies
import Foundation
import CoreDomain

public enum AgentStreamClientKey: DependencyKey {
    public static let liveValue: any AgentStreamClient = NotConfiguredAgentStreamClient()
    public static let testValue: any AgentStreamClient = NotConfiguredAgentStreamClient()
}

public extension DependencyValues {
    var agentStreamClient: any AgentStreamClient {
        get { self[AgentStreamClientKey.self] }
        set { self[AgentStreamClientKey.self] = newValue }
    }
}

/// 라이브 클라이언트가 주입되지 않은 채 호출되면 명확한 에러를 던지는 sentinel.
public struct NotConfiguredAgentStreamClient: AgentStreamClient {
    public init() {}
    public func stream(mochiItemID: UUID) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: DomainError.networkFailed(reason: "AgentStreamClient not configured", transientRetryAfter: nil))
        }
    }
}
