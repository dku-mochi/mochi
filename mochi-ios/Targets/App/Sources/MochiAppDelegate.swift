import UIKit
import UserNotifications
import Dependencies
import CoreNetworking

/// APNs 토큰 등록 + 알림 핸들러. `@UIApplicationDelegateAdaptor` 로 SwiftUI `MochiApp` 에 부착.
///
/// PR-B: background/종료 상태의 분석완료 통지를 위해 device push 토큰을 백엔드에 등록한다.
/// 알림 권한은 첫 진입(active) 시 1회 요청 — 거부해도 앱 내 needsReview 버킷이 always-on fallback.
public final class MochiAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// 알림 권한 확인 + remote 등록. 앱 진입(active)마다 호출해도 안전하다.
    ///
    /// 권한 팝업(1회)과 remote 등록(매번)을 분리한다 — 등록을 1회성 UserDefaults 플래그로 가드하면
    /// 첫 등록이 한 번 어긋났을 때(로그인 전 401·콜백 타이밍·설정에서 나중에 권한 ON) device 토큰을
    /// 영영 다시 못 받는다. 시스템이 토큰을 캐시하므로 매 진입 재등록은 저렴하고, 토큰 회전·첫 실패를
    /// 함께 복구한다(Apple 권고). 팝업은 `.notDetermined` 일 때만 — 시스템이 중복 노출을 막는다.
    /// active 시점 호출(didFinishLaunching 아님)은 컨텍스트 없는 즉시 팝업 회피 — 호출부(MochiApp) 책임.
    @MainActor
    func requestAuthorizationIfNeeded() {
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

    public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        // 토큰은 빌드 환경에 묶인다 — DEBUG(Xcode)=sandbox, Release(TestFlight/App Store)=production.
        #if DEBUG
        let environment: PushEnvironment = .sandbox
        #else
        let environment: PushEnvironment = .production
        #endif
        let api = DependencyValues._current.mochiAPIClient
        Task {
            // best-effort — 실패해도 폴링 fallback 이 메운다(미인증 시 백엔드가 401).
            try? await api.registerPushToken(
                token: token, kind: .apnsDevice, environment: environment, mochiItemID: nil
            )
        }
    }

    public func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // 폴링 fallback 이 있으므로 fatal 아님 — 등록 실패는 무시(다음 진입에서 재시도 가능).
    }

    // MARK: - 알림 핸들러

    /// foreground 수신 — 분석 완료 alert 를 배너로 노출(앱이 켜져 있어도 보이게).
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    /// 알림 탭 → 앱 진입 + 해당 항목 상세 진입. `userInfo["mochiItemID"]` 는 server PK —
    /// RootFeature→MainTabFeature 가 server→local 역매핑(repository.find(serverID:))해 상세를 present한다
    /// (로컬에 아직 없으면 짧게 재시도, 끝내 없으면 홈 버킷 fallback). 후보 선택 action 은 없다(선택은 LA / 앱 내 버킷).
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let raw = userInfo["mochiItemID"] as? String, let id = UUID(uuidString: raw) {
            Task { @MainActor in MochiApp.rootStore.send(.notificationTapped(id)) }
        }
        completionHandler()
    }
}
