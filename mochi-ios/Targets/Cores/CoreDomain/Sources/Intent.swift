import Foundation

/// 모찌의 4-Intent 분류.
///
/// 사용자가 기록을 남기는 4가지 의도. 각 Intent는 서로 다른 데이터 생명주기를 가진다.
///
/// - `schedule`   일정 — EventKit/Google Calendar 자동 sync, 이벤트 종료 시 자동 아카이브
/// - `todo`       할일 — Reminders 자동 sync, 완료 체크 시 자동 아카이브
/// - `knowledge`  지식 — Active 30d → Decay 180d → 무참조 시 사용자 검토 요청
/// - `memo`       기록 — 영구 보관, 사용자 수동 삭제만 허용
public enum Intent: String, Codable, CaseIterable, Sendable, Hashable {
    case schedule
    case todo
    case knowledge
    case memo

    public var displayName: String {
        switch self {
        case .schedule: return "일정"
        case .todo:     return "할일"
        case .knowledge: return "지식"
        case .memo:     return "기록"
        }
    }

    public var systemImageName: String {
        switch self {
        case .schedule: return "calendar"
        case .todo:     return "checklist"
        case .knowledge: return "book.closed"
        case .memo:     return "doc.text"
        }
    }
}
