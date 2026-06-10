import Foundation

/// intent instance payload 의 날짜 문자열(`date`/`time`/`deadline`) 파서 — **단일 원천**.
///
/// 캘린더 탭(마커·날짜 sheet)과 채팅 proposal 확정(시스템 캘린더·미리알림 등록)이 같은
/// payload 를 읽는다 — 포맷 해석이 갈라지면 같은 일정이 화면마다 다른 날짜에 보인다.
public enum PayloadDate {
    /// ISO8601 / "yyyy-MM-dd'T'HH:mm" / "yyyy-MM-dd HH:mm" / "yyyy-MM-dd" 를 지원하고,
    /// TZ 미명시(날짜만 등)는 KST 로 해석한다(백엔드 KST 집계와 정합). 파싱 불가(자연어)면 nil.
    public static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) { return date }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss",
                       "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}
