import Dependencies
import UIKit
import UserNotifications

/// 푸시 권한 요청·등록 로직의 단일 지점.
///
/// 권한 **팝업**(`.notDetermined` → `requestAuthorization`)과 remote **등록**(`registerForRemoteNotifications`)을
/// 분리한다. 팝업은 사용자가 회수 가치를 경험하기도 전인 미인증 콜드스타트에 뜨면 안 된다 — iOS 는 1회 거부 시
/// 앱 내 재요청이 불가하므로, 거부가 회수 알림(미션 핵심 전달 채널)을 영구히 죽인다. 따라서 팝업은 인증 완료
/// 후에만(`RootFeature` 가 트리거), 등록은 매 active 안전하게 호출한다(시스템 토큰 캐시라 저렴, 회전 복구).
enum PushAuthorization {
    /// 팝업 없는 remote 등록 — 알림 권한과 **무관하게 항상** 등록한다(2026-07-14). APNs 토큰은 alert
    /// 표시 권한이 아니라 기기 주소다: silent 동기화 push(시스템 캘린더·미리알림 자동 관리, §1.5)는
    /// 알림을 거부한 사용자에게도 가야 한다. alert 표시는 어차피 OS 가 권한으로 거른다.
    /// 매 진입(active) 호출해도 안전(토큰 회전·첫 실패 복구).
    @MainActor
    static func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// `.notDetermined` 면 권한 팝업(1회) — **인증 완료 후에만** 호출. 이미 허용돼 있으면 재등록만.
    @MainActor
    static func requestIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                        guard granted else { return }
                        Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
                    }
            case .authorized, .provisional, .ephemeral:
                Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
            default:
                break  // .denied — 앱 내 needsReview 버킷이 always-on fallback.
            }
        }
    }
}

/// `RootFeature` 가 인증 시점에 푸시 권한 팝업을 띄우기 위한 의존성(미인증 콜드스타트 팝업 회피).
protocol PushAuthorizationRequesting: Sendable {
    func requestIfNeeded() async
}

struct LivePushAuthorizationRequester: PushAuthorizationRequesting {
    func requestIfNeeded() async {
        await MainActor.run { PushAuthorization.requestIfNeeded() }
    }
}

struct NoopPushAuthorizationRequester: PushAuthorizationRequesting {
    func requestIfNeeded() async {}
}

enum PushAuthorizationKey: DependencyKey {
    static let liveValue: any PushAuthorizationRequesting = LivePushAuthorizationRequester()
    static let testValue: any PushAuthorizationRequesting = NoopPushAuthorizationRequester()
}

extension DependencyValues {
    var pushAuthorization: any PushAuthorizationRequesting {
        get { self[PushAuthorizationKey.self] }
        set { self[PushAuthorizationKey.self] = newValue }
    }
}
