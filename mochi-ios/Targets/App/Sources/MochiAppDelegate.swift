import UIKit
import UserNotifications
import Dependencies
import CoreNetworking

/// APNs 토큰 등록 + 알림 핸들러. `@UIApplicationDelegateAdaptor` 로 SwiftUI `MochiApp` 에 부착.
///
/// PR-B: background/종료 상태의 분석완료 통지를 위해 device push 토큰을 백엔드에 등록한다.
/// 알림 권한은 첫 진입(active) 시 1회 요청 — 거부해도 앱 내 needsReview 버킷이 always-on fallback.
public final class MochiAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let didRequestAuthKey = "mochi.push.didRequestAuthorization"

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// 알림 권한 요청 — 첫 진입 시 1회(didFinishLaunching 이 아닌 active — 컨텍스트 없는 즉시 팝업 회피).
    /// 권한 허용 시 remote 등록 → `didRegisterForRemoteNotificationsWithDeviceToken` 콜백.
    @MainActor
    func requestAuthorizationIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didRequestAuthKey) else { return }
        defaults.set(true, forKey: Self.didRequestAuthKey)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in
                UIApplication.shared.registerForRemoteNotifications()
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

    /// 알림 탭 → 앱 진입 + 홈 버킷으로 라우팅. 후보 선택 action 은 없다(선택은 LA / 앱 내 버킷).
    /// `userInfo["mochiItemID"]` 는 server PK — 복귀 시 scenePhase active reconcile 이 해당 항목을
    /// 최신화해 홈 버킷에 띄운다. (상세 딥링크는 server→local id 매핑이 필요해 후속.)
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
