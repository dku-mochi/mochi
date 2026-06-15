import Foundation
import CoreDomain

/// 확정된 instance 를 실제 iOS 캘린더(schedule→EKEvent)·미리알림(todo→EKReminder)에 등록한다 —
/// 일정·할 일이 모찌 안에만 머물지 않게(미션: "필요한 기억은 쉽게 떠오른다").
///
/// 채팅 일정 확정과 캘린더 탭 "일정 추가"가 공유한다(2026-06-15 추출 — 이전엔 ChatFeature private).
/// payload 는 LLM/폼이 만든 string-key 맵을 그대로 받는다(키: title/date/time/end_date/end_time/deadline).
public enum SystemCalendarRegistrar {
    public struct Instance: Sendable {
        public let intentType: String
        public let payload: [String: String]
        public init(intentType: String, payload: [String: String]) {
            self.intentType = intentType
            self.payload = payload
        }
    }

    /// **권한을 전부 먼저 확보**하고 나서 생성한다 — 일부만 만들어진 채 권한으로 실패하면
    /// 재시도 시 EK 항목이 중복 등록된다(EventKit save 는 멱등이 아님).
    /// 권한 확보 후의 save 실패(기본 캘린더 부재 등)는 best-effort 로 삼킨다 — 모찌 기록은
    /// 이미 생성됐고(확정의 본질), 실패로 재시도를 유도하면 앞서 만든 EK 항목만 중복된다.
    public static func register(
        instances: [Instance],
        fallbackTitle: String?,
        using syncer: any CalendarSyncing
    ) async throws {
        let schedules = instances.filter {
            $0.intentType == "schedule" && scheduleStart(from: $0.payload) != nil
        }
        let todos = instances.filter { $0.intentType == "todo" }
        if !schedules.isEmpty { try await syncer.requestEventAccess() }
        if !todos.isEmpty { try await syncer.requestReminderAccess() }

        for instance in schedules {
            guard let (start, allDay) = scheduleStart(from: instance.payload) else { continue }
            _ = try? await syncer.createEvent(
                title: instance.payload["title"] ?? fallbackTitle ?? "모찌 일정",
                start: start,
                end: scheduleEnd(from: instance.payload, start: start),
                allDay: allDay
            )
        }
        for instance in todos {
            _ = try? await syncer.createReminder(
                title: instance.payload["title"] ?? fallbackTitle ?? "모찌 할 일",
                due: PayloadDate.parse(instance.payload["deadline"])
            )
        }
    }

    /// payload end_date(+end_time) → 기간 일정의 이벤트 종료 시각.
    /// 없거나 파싱 불가·시작 이전이면 nil — 점 일정으로 기본값(종일=start, 시각=+1h)을 따른다.
    public static func scheduleEnd(from payload: [String: String], start: Date) -> Date? {
        guard let rawEndDate = payload["end_date"], !rawEndDate.isEmpty else { return nil }
        let rawEndTime = payload["end_time"] ?? ""
        let parsed = rawEndTime.isEmpty
            ? PayloadDate.parse(rawEndDate)
            : PayloadDate.parse("\(rawEndDate) \(rawEndTime)") ?? PayloadDate.parse(rawEndDate)
        guard let end = parsed, end > start else { return nil }
        return end
    }

    /// payload date(+time) → 이벤트 시작 시각. time 이 없으면 종일 일정.
    /// 날짜 파싱 불가(자연어 등)면 nil — 시스템 등록은 건너뛴다(모찌 기록 자체는 이미 생성됨).
    public static func scheduleStart(from payload: [String: String]) -> (start: Date, allDay: Bool)? {
        let rawDate = payload["date"]
        if let rawDate, let rawTime = payload["time"], !rawTime.isEmpty,
           let combined = PayloadDate.parse("\(rawDate) \(rawTime)") {
            return (combined, false)
        }
        guard let date = PayloadDate.parse(rawDate) else { return nil }
        // date 문자열 자체에 시간이 포함된 경우(ISO datetime, 10자 초과)는 시각 일정으로.
        return (date, (rawDate?.count ?? 0) <= 10)
    }
}
