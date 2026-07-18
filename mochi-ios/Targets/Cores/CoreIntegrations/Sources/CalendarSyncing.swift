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

    /// 현재 권한 보유 여부 — **프롬프트 없이** 상태만 확인한다. 동기화 엔진은 스스로 묻지 않는
    /// 규약이라(프롬프트는 상호작용 문맥의 몫) 요청 대신 이걸 본다.
    func hasEventAccess() async -> Bool
    func hasReminderAccess() async -> Bool

    /// 분석 결과 액션 후보를 시스템에 반영하고 식별자를 반환.
    /// `allDay` = 시간 정보 없이 날짜만 있는 일정 (payload date 만 있고 time 없음).
    func createEvent(title: String, start: Date, end: Date?, allDay: Bool) async throws -> String
    func createReminder(title: String, due: Date?) async throws -> String

    /// 영속 식별자의 기존 EKEvent 를 통째로 되맞춘다(제목·시각 덮어쓰기 — 같은 입력 재적용 멱등,
    /// 무변경이면 save 생략). 항목이 식별자로 안 잡히면 false — 호출자(엔진)가 tombstone 처리한다.
    func updateEvent(identifier: String, title: String, start: Date, end: Date?, allDay: Bool) async throws -> Bool
    func updateReminder(identifier: String, title: String, due: Date?, completed: Bool) async throws -> Bool

    /// 영속 식별자의 EKReminder **현재 완료 상태** 조회 — 미리알림 앱에서의 사용자 토글을 모찌로
    /// 역반영(완료 3-way merge)하기 위해 쓰기 전에 읽는다. 안 잡히면 nil(호출자가 tombstone 판단).
    func reminderCompleted(identifier: String) async throws -> Bool?

    /// 영속 식별자의 EK 항목 제거. 이미 없으면 성공으로 간주(멱등).
    func removeEvent(identifier: String) async throws
    func removeReminder(identifier: String) async throws
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

    public func hasEventAccess() async -> Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    public func hasReminderAccess() async -> Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
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

    public func updateEvent(identifier: String, title: String, start: Date, end: Date?, allDay: Bool) async throws -> Bool {
        guard let event = store.event(withIdentifier: identifier) else { return false }
        let resolvedEnd = end ?? (allDay ? start : start.addingTimeInterval(60 * 60))
        // 무변경이면 save 생략 — 엔진이 동기화마다 되밀어도 캘린더 변경 알림·iCloud churn 이 없다.
        // **종일 + end 미지정**만 endDate 비교를 제외한다 — 종일 종료일은 EventKit 이 정규화할 수 있어
        // 비교에 넣으면 매 동기화 재저장 churn 이 난다. 시각 일정은 end 제거(기간→점 전환)도 잡아야
        // 하므로 기본 종료(+1h)와 비교한다(결정적 값이라 1회 재저장 후 안정).
        if event.title == title, event.startDate == start, event.isAllDay == allDay,
           (allDay && end == nil) || event.endDate == resolvedEnd {
            return true
        }
        event.title = title
        event.startDate = start
        event.endDate = resolvedEnd
        event.isAllDay = allDay
        do {
            try store.save(event, span: .thisEvent)
            return true
        } catch {
            throw CalendarSyncError.underlying(message: error.localizedDescription)
        }
    }

    public func updateReminder(identifier: String, title: String, due: Date?, completed: Bool) async throws -> Bool {
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else { return false }
        let components = due.map {
            Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0)
        }
        if reminder.title == title, reminder.dueDateComponents == components, reminder.isCompleted == completed {
            return true
        }
        reminder.title = title
        reminder.dueDateComponents = components
        reminder.isCompleted = completed
        do {
            try store.save(reminder, commit: true)
            return true
        } catch {
            throw CalendarSyncError.underlying(message: error.localizedDescription)
        }
    }

    public func reminderCompleted(identifier: String) async throws -> Bool? {
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else { return nil }
        return reminder.isCompleted
    }

    public func removeEvent(identifier: String) async throws {
        guard let event = store.event(withIdentifier: identifier) else { return }   // 이미 없음 = 멱등 성공
        do {
            try store.remove(event, span: .thisEvent)
        } catch {
            throw CalendarSyncError.underlying(message: error.localizedDescription)
        }
    }

    public func removeReminder(identifier: String) async throws {
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else { return }
        do {
            try store.remove(reminder, commit: true)
        } catch {
            throw CalendarSyncError.underlying(message: error.localizedDescription)
        }
    }
}
