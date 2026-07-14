import Foundation
import CoreDomain

/// intent payload → EKEvent/EKReminder 시각 해석의 **단일 원천**.
///
/// 원래 확정 시점 call-site 등록(register)의 집이었으나, 2026-07-14 자동 관리 전환으로 생성·갱신·제거
/// 실행은 `CorePersistence.SystemCalendarSyncEngine`(Realm 관찰) 이 전담한다 — 여기엔 payload 파싱
/// 규칙만 남긴다(엔진·과거 등록분이 같은 해석을 공유해야 시각이 어긋나지 않는다).
/// payload 는 LLM/폼이 만든 string-key 맵(키: title/date/time/end_date/end_time/deadline).
public enum SystemCalendarRegistrar {
    /// 도메인 typed payload → string-key 맵. 엔진이 `scheduleStart`/`scheduleEnd` 에 넘기기 위한 변환.
    public static func stringMap(_ payload: IntentPayload) -> [String: String] {
        var map: [String: String] = [:]
        map["title"] = payload.title
        map["date"] = payload.date
        map["time"] = payload.time
        map["end_date"] = payload.endDate
        map["end_time"] = payload.endTime
        map["deadline"] = payload.deadline
        return map
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
