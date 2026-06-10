import Foundation
import CoreDomain

/// 테스트·미설정 컨텍스트에서 사용하는 실패 sentinel. 실제 캘린더 접근은 절대 시도하지 않는다.
public actor UnconfiguredCalendarSyncer: CalendarSyncing {
    public init() {}
    public func requestEventAccess() async throws { throw CalendarSyncError.accessDenied }
    public func requestReminderAccess() async throws { throw CalendarSyncError.accessDenied }
    public func createEvent(title: String, start: Date, end: Date?, allDay: Bool) async throws -> String {
        throw CalendarSyncError.underlying(message: "CalendarSyncer not configured")
    }
    public func createReminder(title: String, due: Date?) async throws -> String {
        throw CalendarSyncError.underlying(message: "CalendarSyncer not configured")
    }
}
