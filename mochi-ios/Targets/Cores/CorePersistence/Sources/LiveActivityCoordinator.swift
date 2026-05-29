import Dependencies
import Foundation

/// 백탭 분류 흐름의 Live Activity 를 trigger 하는 추상화.
///
/// `MochiItemSyncWorker` 가 multipart `POST /mochi_items/back-tap` 호출 시점에 `.analyzing` Activity 를
/// 시작, 응답 도착 시 `.ready(candidates)` 로 update, 호출 실패 시 end. ActivityKit 의존성을
/// App 타겟에 격리하기 위한 port — CorePersistence (이 모듈) 는 ActivityKit 을 import 하지 않는다.
public protocol LiveActivityCoordinator: Sendable {
    /// multipart 호출 시작 직전 호출. Lock Screen / Dynamic Island 에 `.analyzing` 표시.
    /// `thumbnailRelativePath` 는 App Group container 기준 상대 경로 (예: `captures/<filename>.png`).
    /// nil 이면 좌측 column 의 썸네일 자리에 placeholder.
    func startAnalyzing(mochiItemID: UUID, caption: String, thumbnailRelativePath: String?) async

    /// 분류 응답 도착 시 `.ready` 로 transition. 사용자가 후보 선택할 수 있는 상태.
    func transitionToReady(
        mochiItemID: UUID,
        candidates: [LiveActivityCandidate]
    ) async

    /// 호출 실패 / 인증 만료 등 dangling 가능 시점에 호출. 활성 Activity 가 있으면 end.
    func endIfActive(mochiItemID: UUID, failed: Bool) async
}

/// 후보 한 건. ActivityKit attributes 의 `Candidate` 와 1:1 매핑되지만 CorePersistence 가
/// `CoreLiveActivity` 에 의존하지 않도록 별도 struct 로 둔다.
public struct LiveActivityCandidate: Sendable, Hashable {
    public let label: String
    public let intent: String           // schedule / todo / knowledge / memo
    public let applicability: Double

    public init(label: String, intent: String, applicability: Double) {
        self.label = label
        self.intent = intent
        self.applicability = applicability
    }
}

public enum LiveActivityCoordinatorKey: DependencyKey {
    public static let liveValue: any LiveActivityCoordinator = NotConfiguredLiveActivityCoordinator()
    public static let testValue: any LiveActivityCoordinator = NotConfiguredLiveActivityCoordinator()
}

public extension DependencyValues {
    var liveActivityCoordinator: any LiveActivityCoordinator {
        get { self[LiveActivityCoordinatorKey.self] }
        set { self[LiveActivityCoordinatorKey.self] = newValue }
    }
}

/// 주입 누락 시 no-op. MochiItemSyncWorker 흐름은 막지 않음.
public struct NotConfiguredLiveActivityCoordinator: LiveActivityCoordinator {
    public init() {}
    public func startAnalyzing(mochiItemID: UUID, caption: String, thumbnailRelativePath: String?) async {}
    public func transitionToReady(mochiItemID: UUID, candidates: [LiveActivityCandidate]) async {}
    public func endIfActive(mochiItemID: UUID, failed: Bool) async {}
}

/// mochiItemID prefix 를 caption 에 박는 헬퍼 — Live coordinator 의 `findActivity(for:)` 매칭에 사용.
/// CorePersistence + App 타겟 양쪽에서 import 가능하도록 본 모듈에 둠.
public func liveActivityCaption(mochiItemID: UUID, body: String) -> String {
    "[\(mochiItemID.uuidString.prefix(8))] \(body)"
}
