import Foundation
import EventKit
import CoreDomain

/// EventKit/Reminders와의 양방향 동기화를 추상화한 outbound port.
///
/// 구현체는 EventKit를 직접 부르고, 테스트는 ``MockCalendarSyncer`` 같은 in-memory 구현을 주입한다.
public protocol CalendarSyncing: Sendable {
    /// 캘린더 권한 요청 (iOS 17+ `requestFullAccessToEvents`).
    func requestEventAccess() async throws

    /// 미리알림 권한 요청.
    func requestReminderAccess() async throws

    /// 분석 결과 액션 후보를 시스템에 반영하고 식별자를 반환.
    /// `allDay` = 시간 정보 없이 날짜만 있는 일정 (payload date 만 있고 time 없음).
    func createEvent(title: String, start: Date, end: Date?, allDay: Bool) async throws -> String
    func createReminder(title: String, due: Date?) async throws -> String
}

public enum CalendarSyncError: Error, Equatable, Sendable {
    case accessDenied
    case invalidDate
    case underlying(message: String)
}

public actor LiveCalendarSyncer: CalendarSyncing {
    private let store = EKEventStore()
    public init() {}

    public func requestEventAccess() async throws {
        let granted = try await store.requestFullAccessToEvents()
        if !granted { throw CalendarSyncError.accessDenied }
    }

    public func requestReminderAccess() async throws {
        let granted = try await store.requestFullAccessToReminders()
        if !granted { throw CalendarSyncError.accessDenied }
    }

    public func createEvent(title: String, start: Date, end: Date?, allDay: Bool) async throws -> String {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end ?? (allDay ? start : start.addingTimeInterval(60 * 60))
        event.isAllDay = allDay
        event.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(event, span: .thisEvent)
            return event.eventIdentifier
        } catch {
            throw CalendarSyncError.underlying(message: error.localizedDescription)
        }
    }

    public func createReminder(title: String, due: Date?) async throws -> String {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        }
        reminder.calendar = store.defaultCalendarForNewReminders()
        do {
            try store.save(reminder, commit: true)
            return reminder.calendarItemIdentifier
        } catch {
            throw CalendarSyncError.underlying(message: error.localizedDescription)
        }
    }
}
