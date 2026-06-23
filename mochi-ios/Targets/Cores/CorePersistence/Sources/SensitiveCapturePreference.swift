import Foundation

/// "민감 캡처는 항상 이 기기에만" 사용자 선호 — 앱(설정)에서 쓰고 ShareExtension 이 읽는다.
/// AppGroup UserDefaults 공유라 두 프로세스가 같은 값을 본다(PRIVACY §5.3).
/// 켜져 있으면 고신뢰 민감 신호 감지 시 선택 시트 없이 `localOnly`(서버 미전송)로 저장한다.
public enum SensitiveCapturePreference {
    private static let key = "mochi.privacy.sensitiveAlwaysLocalOnly"

    private static var store: UserDefaults? { UserDefaults(suiteName: AppGroup.identifier) }

    public static func load() -> Bool {
        store?.bool(forKey: key) ?? false
    }

    public static func save(_ value: Bool) {
        store?.set(value, forKey: key)
    }
}
