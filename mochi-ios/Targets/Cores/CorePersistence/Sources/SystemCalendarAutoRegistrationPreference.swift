import Foundation

/// "캘린더·미리알림 자동 등록" 로컬 통제 밸브 — 설정 토글이 쓰고 `SystemCalendarSyncEngine` 이 읽는다.
/// 기본 on. **off 는 신규 등록·갱신·제거를 멈출 뿐 기존 EK 항목은 건드리지 않는다**(UX_SPEC §3.4d).
/// 서버 계약과 무관한 기기 로컬 값(AppGroup UserDefaults — `SensitiveCapturePreference` 와 동일 저장소).
public enum SystemCalendarAutoRegistrationPreference {
    private static let key = "mochi.integrations.systemCalendarAutoRegistration"

    private static var store: UserDefaults? { UserDefaults(suiteName: AppGroup.identifier) }

    public static func load() -> Bool {
        guard let value = store?.object(forKey: key) as? Bool else { return true }   // 기본 on
        return value
    }

    public static func save(_ value: Bool) {
        store?.set(value, forKey: key)
    }
}
