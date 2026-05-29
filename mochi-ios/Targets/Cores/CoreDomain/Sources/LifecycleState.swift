import Foundation

/// Intent별 차등 생명주기 상태 머신.
///
/// `LifecyclePolicy.validate(from:to:intent:)` 가 다음 두 가지를 모두 검증한다:
/// 1. (current.kind → next.kind) 페어가 Intent별 허용 집합에 있는지
/// 2. `.archived(reason:)` 의 reason이 Intent별 허용 reason 집합에 있는지
public enum LifecycleState: Equatable, Sendable, Hashable, Codable {
    case ingested
    case analyzing
    case active
    case decaying
    case reviewRequested
    case archived(reason: ArchiveReason)
    case failed(reason: String)

    public enum ArchiveReason: String, Codable, Sendable, CaseIterable {
        case scheduleEnded
        case todoCompleted
        case knowledgeStale
        case userManual
    }

    /// 외부 비교용 가벼운 kind 표현.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case ingested, analyzing, active, decaying, reviewRequested, archived, failed
    }

    public var kind: Kind {
        switch self {
        case .ingested:        return .ingested
        case .analyzing:       return .analyzing
        case .active:          return .active
        case .decaying:        return .decaying
        case .reviewRequested: return .reviewRequested
        case .archived:        return .archived
        case .failed:          return .failed
        }
    }
}

public enum LifecycleTransitionError: Error, Equatable, Sendable {
    case illegalTransition(fromKind: LifecycleState.Kind, toKind: LifecycleState.Kind, intent: Intent)
    case missingArchiveReason(intent: Intent)
    case invalidArchiveReason(reason: LifecycleState.ArchiveReason, intent: Intent)
}

public enum LifecyclePolicy {
    public static let knowledgeActiveWindow: TimeInterval = 30 * 24 * 60 * 60
    public static let knowledgeDecayWindow: TimeInterval = 180 * 24 * 60 * 60

    private static let allowedKindPairs: [Intent: Set<KindPair>] = [
        .schedule: [
            .init(.ingested, .analyzing),
            .init(.analyzing, .active),
            .init(.analyzing, .failed),
            .init(.active, .archived),
        ],
        .todo: [
            .init(.ingested, .analyzing),
            .init(.analyzing, .active),
            .init(.analyzing, .failed),
            .init(.active, .archived),
        ],
        .knowledge: [
            .init(.ingested, .analyzing),
            .init(.analyzing, .active),
            .init(.analyzing, .failed),
            .init(.active, .decaying),
            .init(.decaying, .active),
            .init(.decaying, .reviewRequested),
            .init(.reviewRequested, .active),
            .init(.reviewRequested, .archived),
        ],
        .memo: [
            .init(.ingested, .analyzing),
            .init(.analyzing, .active),
            .init(.analyzing, .failed),
            .init(.active, .archived),
        ],
    ]

    private static let intentArchiveReasons: [Intent: Set<LifecycleState.ArchiveReason>] = [
        .schedule:  [.scheduleEnded, .userManual],
        .todo:      [.todoCompleted, .userManual],
        .knowledge: [.knowledgeStale, .userManual],
        .memo:      [.userManual],
    ]

    public static func validate(
        from currentState: LifecycleState,
        to nextState: LifecycleState,
        intent: Intent
    ) -> Result<Void, LifecycleTransitionError> {
        let pair = KindPair(currentState.kind, nextState.kind)
        guard allowedKindPairs[intent]?.contains(pair) == true else {
            return .failure(.illegalTransition(fromKind: currentState.kind, toKind: nextState.kind, intent: intent))
        }
        if case let .archived(reason) = nextState {
            guard let reasons = intentArchiveReasons[intent], reasons.contains(reason) else {
                return .failure(.invalidArchiveReason(reason: reason, intent: intent))
            }
        }
        return .success(())
    }
}

private struct KindPair: Hashable {
    let from: LifecycleState.Kind
    let to: LifecycleState.Kind
    init(_ from: LifecycleState.Kind, _ to: LifecycleState.Kind) {
        self.from = from
        self.to = to
    }
}
