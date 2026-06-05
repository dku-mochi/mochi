import Dependencies
import Foundation

/// 캡처 분석 흐름의 Live Activity 를 trigger 하는 추상화.
///
/// `MochiItemSyncWorker` 가 ingest(`POST /mochi_items`) 시작 시 `.analyzing` Activity 를 시작하고,
/// ingest 응답으로 serverID 를 받으면 LA push 토큰을 백엔드에 등록(`registerPushToken`)한다. 분석
/// 완료(SSE `final` / 폴링) 시 `.ready` 로 update, 실패 시 end. ActivityKit 의존성을 App 타겟에
/// 격리하기 위한 port — CorePersistence (이 모듈) 는 ActivityKit 을 import 하지 않는다.
public protocol LiveActivityCoordinator: Sendable {
    /// ingest 시작 직전 호출. Lock Screen / Dynamic Island 에 `.analyzing` 표시. 전 채널 점유.
    /// `thumbnailRelativePath` 는 App Group container 기준 상대 경로(스크린샷만 존재, 그 외 nil → placeholder).
    func startAnalyzing(mochiItemID: UUID, caption: String, thumbnailRelativePath: String?) async

    /// ingest 응답으로 serverID 를 받은 직후 호출. LA push 토큰(로컬 관찰)을 **serverID** 로 백엔드에
    /// 등록한다 — 백엔드 `list_live_activity_for_item` 이 server PK 로 LA 토큰을 조회하기 때문.
    /// (`startAnalyzing` 시점엔 serverID 가 없어 토큰을 들고만 있다가 여기서 짝지어 등록.)
    func registerPushToken(mochiItemID: UUID, serverID: UUID) async

    /// 분석 완료 시 `.ready` 로 transition. `needsReview` 면 후보 선택 대기, 아니면 확정 표시(summary).
    func transitionToReady(
        mochiItemID: UUID,
        needsReview: Bool,
        summary: String,
        candidates: [LiveActivityCandidate]
    ) async

    /// 호출 실패 / 인증 만료 / 분석 실패 등 dangling 시점에 호출. 활성 Activity 가 있으면 end.
    func endIfActive(mochiItemID: UUID, failed: Bool) async
}

/// 후보 한 건. ActivityKit attributes 의 `Candidate`(`intentType`/`label`/`reasoning`)와 1:1 매핑되지만
/// CorePersistence 가 `CoreLiveActivity` 에 의존하지 않도록 별도 struct 로 둔다.
public struct LiveActivityCandidate: Sendable, Hashable {
    public let intentType: String       // schedule / todo / knowledge / memo
    public let label: String
    public let reasoning: String

    public init(intentType: String, label: String, reasoning: String) {
        self.intentType = intentType
        self.label = label
        self.reasoning = reasoning
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
    public func registerPushToken(mochiItemID: UUID, serverID: UUID) async {}
    public func transitionToReady(
        mochiItemID: UUID,
        needsReview: Bool,
        summary: String,
        candidates: [LiveActivityCandidate]
    ) async {}
    public func endIfActive(mochiItemID: UUID, failed: Bool) async {}
}
