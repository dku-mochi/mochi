import SwiftUI

// 마감/일정 표시 공용 (캘린더 탭 · 이번 주 돌아보기 · 기록 상세).
// 원래 FeatureInbox 내부였으나 기록 상세가 같은 시각 언어를 쓰게 되며 DesignSystem 으로 승격 (2026-06-11).

extension Calendar {
    /// 날짜 계산(월 경계·일 그룹·오늘·D-day)은 백엔드 KST 월간 집계와 일치시키기 위해
    /// Asia/Seoul 로 고정한다. `Calendar.current`(기기 TZ)에 의존하면 월말 UTC 캡처가
    /// 다른 날짜로 그룹돼 서버와 어긋난다.
    public static let mochiSeoul: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        return calendar
    }()
}

extension DateFormatter {
    /// 표시용 한국어·KST 고정 포매터.
    public static func mochiSeoul(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = format
        return formatter
    }
}

/// 마감 D-day 라벨과 긴급도 색, 일정 상대 라벨 — 화면들이 같은 시각 언어를 쓴다.
public enum DueDisplay {
    /// "n일 지남" / "오늘 마감" / "내일 마감" / "D-n" — 시각이 있으면 " · 오후 9:00" 을 덧붙인다.
    /// todo 의 시각은 별도 필드가 아니라 deadline 안에 담기므로(알람형 할 일), 시각이 들어온
    /// 마감은 그 시각까지 라벨에 드러낸다.
    public static func deadlineLabel(_ deadline: Date) -> String {
        let days = daysFromToday(to: deadline)
        let day: String
        if days < 0 { day = "\(-days)일 지남" }
        else if days == 0 { day = "오늘 마감" }
        else if days == 1 { day = "내일 마감" }
        else { day = "D-\(days)" }
        return day + timeSuffix(deadline)
    }

    /// 긴급도 색 — 지남(blush) > 오늘·내일(peach) > 그 외 마감(butter) > 미정(muted).
    /// 가장 급한 것이 가장 강한 색 — "내일"이 D-4 보다 옅어 보이던 역전을 바로잡는다.
    public static func deadlineColor(_ deadline: Date?) -> Color {
        guard let deadline else { return HomeDesign.Color.textMuted }
        let days = daysFromToday(to: deadline)
        if days < 0 { return HomeDesign.Color.blush400 }
        if days <= 1 { return HomeDesign.Color.peach400 }
        return HomeDesign.Color.butter400
    }

    /// 기간 일정 라벨 — "시작 ~ 끝". **양끝을 같은 절대 포맷**("M월 d일 (E)" + 시각)으로 적는다.
    /// 한쪽만 상대(오늘/D-10)로 적으면 끝의 절대 날짜와 포맷이 어긋나 "D-10 ~ 6월 27일 (토)" 처럼
    /// 읽기 나빠진다 — 양끝 포맷을 통일한다.
    public static func scheduleRangeLabel(_ start: Date, _ end: Date) -> String {
        rangeEndpoint(start) + " ~ " + rangeEndpoint(end)
    }

    /// 일정 상대 라벨 — 오늘/내일/요일(7일 미만)/D-n + (자정이 아니면) 시각.
    /// 절대 날짜는 왼쪽 날짜 타일이 담당하므로 여기선 상대 표현만.
    public static func scheduleLabel(_ date: Date) -> String {
        let days = daysFromToday(to: date)
        let day: String
        if days < 0 { day = DateFormatter.mochiSeoul("M월 d일 (E)").string(from: date) }  // 지난 일정 방어
        else if days == 0 { day = "오늘" }
        else if days == 1 { day = "내일" }
        else if days < 7 { day = DateFormatter.mochiSeoul("EEEE").string(from: date) }
        else { day = "D-\(days)" }
        return day + timeSuffix(date)
    }

    /// 기간 끝점 — 양끝 공통 절대 포맷("M월 d일 (E)" + 시각). 상대 표현 없음(양끝 포맷 통일).
    private static func rangeEndpoint(_ date: Date) -> String {
        DateFormatter.mochiSeoul("M월 d일 (E)").string(from: date) + timeSuffix(date)
    }

    /// 자정(시각 없음)이 아니면 " · 오후 9:00" 형태의 시각 접미사 — **표시 시각 포맷의 단일 원천**.
    /// date-only payload 는 KST 자정으로 파싱돼 hasTime=false → 접미사 없음(하루 단위 일정/마감).
    private static func timeSuffix(_ date: Date) -> String {
        let calendar = Calendar.mochiSeoul
        let hasTime = calendar.component(.hour, from: date) != 0 || calendar.component(.minute, from: date) != 0
        return hasTime ? " · " + DateFormatter.mochiSeoul("a h:mm").string(from: date) : ""
    }

    private static func daysFromToday(to date: Date) -> Int {
        let calendar = Calendar.mochiSeoul
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
    }
}

/// 일정 행의 날짜 타일(월/일) — 캘린더 탭·이번 주 돌아보기·기록 상세 공용. 날짜 없으면 달력 아이콘 폴백.
public struct ScheduleDateTile: View {
    let date: Date?

    public init(date: Date?) {
        self.date = date
    }

    public var body: some View {
        VStack(spacing: 1) {
            if let date {
                Text(DateFormatter.mochiSeoul("M월").string(from: date))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.sky400)
                Text(DateFormatter.mochiSeoul("d").string(from: date))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
            } else {
                Image(systemName: "calendar")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.sky400)
            }
        }
        .frame(width: 46, height: 48)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                .fill(HomeDesign.Color.sky100)
        )
    }
}
