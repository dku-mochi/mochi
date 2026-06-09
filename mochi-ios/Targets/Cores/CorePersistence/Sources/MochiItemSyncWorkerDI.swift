import Dependencies
import Foundation

/// 백엔드 sync 를 즉시 trigger 하기 위한 가벼운 추상화 — Feature 가 `MochiItemSyncWorker` 의 구체
/// init dependencies (apiClient · tokenProvider) 를 알 필요 없이 `runOnce()` 만 호출하면 된다.
///
/// 메인 App 의 ``MochiApp`` 이 `MochiItemSyncWorker` 를 직접 init 한 뒤 본 키에 주입,
/// Feature 레이어는 `@Dependency(\.syncTrigger)` 로 받아 refresh 흐름에서 사용.
public protocol SyncTrigger: Sendable {
    func runOnce() async
    /// 서버→로컬 복구 — 재설치 후 서버의 owner 항목 전체를 로컬 Realm 으로 끌어온다.
    /// 로그인 직후·홈 빈 상태·설정 "전체 동기화" 버튼이 호출한다.
    func pullRemote() async
}

public enum SyncTriggerKey: DependencyKey {
    public static let liveValue: any SyncTrigger = NotConfiguredSyncTrigger()
    public static let testValue: any SyncTrigger = NotConfiguredSyncTrigger()
}

public extension DependencyValues {
    var syncTrigger: any SyncTrigger {
        get { self[SyncTriggerKey.self] }
        set { self[SyncTriggerKey.self] = newValue }
    }
}

/// 주입 누락 시 no-op. 사용자 흐름을 막지 않되 결과는 안 나옴.
public struct NotConfiguredSyncTrigger: SyncTrigger {
    public init() {}
    public func runOnce() async {}
    public func pullRemote() async {}
}

/// ``MochiItemSyncWorker`` 가 그대로 ``SyncTrigger`` 역할 — actor 이므로 자동 Sendable.
extension MochiItemSyncWorker: SyncTrigger {}
