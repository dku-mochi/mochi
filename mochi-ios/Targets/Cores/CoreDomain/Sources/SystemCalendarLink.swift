import Foundation

/// intent instance ↔ 시스템 캘린더(EKEvent)·미리알림(EKReminder) 항목의 연결 기록.
///
/// `SystemCalendarSyncEngine`(CorePersistence)이 확정 schedule/todo 를 자동 등록할 때 만들고,
/// 이 링크가 있어야 이후 날짜·제목 수정과 완료·삭제가 등록된 EK 항목을 따라간다(UX_SPEC §1.5).
/// 서버 계약과 무관한 **기기 로컬 상태**다 — 재설치 시 소실돼도 엔진 reconcile 이 다시 세운다.
public struct SystemCalendarLink: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// schedule → `EKEvent.eventIdentifier`
        case event
        /// todo → `EKReminder.calendarItemIdentifier`
        case reminder
    }

    public let instanceID: UUID
    public let kind: Kind
    public let ekIdentifier: String
    /// EK 항목이 식별자로 더는 안 잡혔던 링크(사용자가 캘린더 앱에서 직접 삭제, 또는 iCloud 동기화로
    /// 식별자 재발급). 재생성하면 중복·사용자 삭제 무시 위험이라 **엔진이 이 표시를 보고 재등록을 막는다**.
    public let tombstoned: Bool

    public init(instanceID: UUID, kind: Kind, ekIdentifier: String, tombstoned: Bool = false) {
        self.instanceID = instanceID
        self.kind = kind
        self.ekIdentifier = ekIdentifier
        self.tombstoned = tombstoned
    }
}
