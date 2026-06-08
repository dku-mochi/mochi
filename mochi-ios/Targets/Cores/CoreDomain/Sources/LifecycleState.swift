import Foundation

/// MochiItem 의 **처리상태** (item 단위, 분석 파이프라인 진행).
///
/// 2026-06-04 빅뱅으로 lifecycle 은 2분할됐다 — 이 처리상태(item)와 `InstanceLifecycle`(intent
/// instance 의미상태)는 직교한다. archive 없음, intent 무관 단일 선형 전이라 정책 불필요.
public enum ProcessingState: Equatable, Sendable, Hashable, Codable {
    case ingested
    case analyzing
    /// 분석 완료·instance 적재됨 (구 `active` — iOS 폴링 컷오버 신호).
    case analyzed
    case failed(reason: String)

    /// 외부 비교용 가벼운 kind 표현.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case ingested, analyzing, analyzed, failed
    }

    public var kind: Kind {
        switch self {
        case .ingested:  return .ingested
        case .analyzing: return .analyzing
        case .analyzed:  return .analyzed
        case .failed:    return .failed
        }
    }
}

/// intent instance 의 **의미상태** (instance 단위, 완료/만료/decay).
///
/// instance 는 분석 성공 시 `active` 로 태어난다. intent_type 별 차등 전이를
/// `LifecyclePolicy.validate(from:to:intent:)` 가 검증한다.
public enum InstanceLifecycle: Equatable, Sendable, Hashable, Codable {
    case active
    case decaying
    case reviewRequested
    case archived(reason: ArchiveReason)

    public enum ArchiveReason: String, Codable, Sendable, CaseIterable {
        case scheduleEnded
        case todoCompleted
        case knowledgeStale
        case userManual
    }

    /// 외부 비교용 가벼운 kind 표현.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case active, decaying, reviewRequested, archived
    }

    public var kind: Kind {
        switch self {
        case .active:          return .active
        case .decaying:        return .decaying
        case .reviewRequested: return .reviewRequested
        case .archived:        return .archived
        }
    }
}

public enum LifecycleTransitionError: Error, Equatable, Sendable {
    case illegalTransition(fromKind: InstanceLifecycle.Kind, toKind: InstanceLifecycle.Kind, intent: Intent)
    case invalidArchiveReason(reason: InstanceLifecycle.ArchiveReason, intent: Intent)
}

/// intent instance 의미상태 전이 정책. 백엔드 `intents/domain/lifecycle_policy.py` 와 1:1.
public enum LifecyclePolicy {
    public static let knowledgeActiveWindow: TimeInterval = 30 * 24 * 60 * 60
    public static let knowledgeDecayWindow: TimeInterval = 180 * 24 * 60 * 60

    private static let allowedKindPairs: [Intent: Set<KindPair>] = [
        .schedule: [
            .init(.active, .archived),
        ],
        .todo: [
            .init(.active, .archived),
            // 완료 취소 — 사용자가 todo 체크를 해제해 미완료로 되돌림(수동 역전이). 잘못 누른 완료를
            // 영구화하지 않기 위한 합법 전이. archived→active 라 archive_reason 검증은 건너뛴다.
            .init(.archived, .active),
        ],
        .knowledge: [
            .init(.active, .decaying),
            .init(.decaying, .active),
            .init(.decaying, .reviewRequested),
            .init(.reviewRequested, .active),
            .init(.reviewRequested, .archived),
        ],
        .memo: [
            .init(.active, .archived),
        ],
    ]

    private static let intentArchiveReasons: [Intent: Set<InstanceLifecycle.ArchiveReason>] = [
        .schedule:  [.scheduleEnded, .userManual],
        .todo:      [.todoCompleted, .userManual],
        .knowledge: [.knowledgeStale, .userManual],
        .memo:      [.userManual],
    ]

    public static func validate(
        from currentState: InstanceLifecycle,
        to nextState: InstanceLifecycle,
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
    let from: InstanceLifecycle.Kind
    let to: InstanceLifecycle.Kind
    init(_ from: InstanceLifecycle.Kind, _ to: InstanceLifecycle.Kind) {
        self.from = from
        self.to = to
    }
}
