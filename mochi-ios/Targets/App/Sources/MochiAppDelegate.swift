import os
import UIKit
import UserNotifications
import Dependencies
import CoreNetworking
import CorePersistence

/// APNs 토큰 등록 + 알림 핸들러. `@UIApplicationDelegateAdaptor` 로 SwiftUI `MochiApp` 에 부착.
///
/// PR-B: background/종료 상태의 분석완료 통지를 위해 device push 토큰을 백엔드에 등록한다.
/// 권한 요청·등록 로직은 ``PushAuthorization`` 단일 지점에 있다 — 팝업은 인증 완료 후(``RootFeature``)로
/// 이연하고(미인증 콜드스타트 팝업 회피), 등록은 매 active(``MochiApp``) 안전 호출한다. 거부해도 앱 내
/// needsReview 버킷이 always-on fallback.
public final class MochiAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// silent push 백그라운드 체인 진단용 — Console.app(기기 연결)/Xcode 콘솔에서 `app.mochi` subsystem,
    /// `silent-sync` category 로 필터. 백그라운드 경로는 UI 가 없어 로그가 유일한 관측 수단이다
    /// (ShareExt `direct-upload` Logger 와 같은 관례). 토큰·본문은 절대 로그하지 않는다.
    private static let syncLogger = Logger(subsystem: "app.mochi", category: "silent-sync")
    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
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

    /// silent 동기화 push (content-available, alert 없음) — 분석 완료가 확정 schedule/todo 를 포함하면
    /// 서버가 보낸다(§1.5 자동 관리). 앱을 열지 않아도 아래 체인이 foreground tick 과 같은 순서로
    /// 따라잡아, 몇 분 내 아이폰 캘린더·미리알림에 선다. 사용자 노출 알림이 아니라
    /// 데이터 동기화 신호라 알림 선호(preference_off) 게이트와 무관하다. OS 스로틀·강제종료로 미도달할 수
    /// 있으므로 최종 보증은 앱 실행/복귀 시 엔진 reconcile 백스톱(MochiApp).
    ///
    /// **체인이 reconcile 하나로 안 되는 이유**(2026-07-14 실기기 버그 fix): ShareExt 캡처는 push 도착
    /// 시점에 로컬 Realm 에 없다 — App Group inbound 큐(JSON)에만 있고, 큐→Realm drain 은 foreground
    /// tick 에서만 돌았다. `reconcile` 은 `uploaded:<serverID>` 링크로만 항목을 찾으므로(find(serverID:))
    /// drain(큐→Realm) → runOnce(멱등 업로드, ShareExt 직접 전송과 같은 행 반환 → serverID 확보) 가
    /// 선행돼야 한다. 전 단계가 멱등이고(runOnce·syncNow 는 단일 비행) foreground 경합·중복 push 에도
    /// 안전하다.
    public func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let raw = userInfo["mochiItemID"] as? String, let id = UUID(uuidString: raw) else {
            Self.syncLogger.notice("push received: mochiItemID 없음/파싱 실패 → noData")
            completionHandler(.noData)
            return
        }
        Self.syncLogger.notice("push received: item=\(raw, privacy: .public) state=\(application.applicationState.rawValue)")
        let drainer = DependencyValues._current.inboundQueueDrainer
        let syncTrigger = DependencyValues._current.syncTrigger
        let engine = DependencyValues._current.systemCalendarSyncEngine
        // 백그라운드 예산(~30초) 안에 completionHandler 를 **정확히 한 번** 보장하는 watchdog(codex P1) —
        // runOnce 는 이미지 presign→PUT 까지 포함하므로 느린 망에서 예산을 넘길 수 있고, 제때 못 부르면
        // OS 가 이후 백그라운드 push 전달을 스로틀한다. 초과 시 잔여 체인을 협조 취소하고 .failed 로 마감 —
        // 남은 작업은 전부 멱등이라 다음 push/foreground 백스톱이 이어받는다.
        let hasFinished = OSAllocatedUnfairLock(initialState: false)
        // 첫 호출만 completionHandler 전달 — 승자였는지 반환(watchdog 이 뒷북 로그를 남기지 않게).
        let finish: @Sendable (UIBackgroundFetchResult) -> Bool = { result in
            let isFirst = hasFinished.withLock { finished in
                defer { finished = true }
                return !finished
            }
            if isFirst { completionHandler(result) }
            return isFirst
        }
        let work = Task {
            let drained = await drainer.drain()
            Self.syncLogger.notice("drain: consumed=\(drained.consumed) failed=\(drained.failedFiles.count)")
            await syncTrigger.runOnce()
            Self.syncLogger.notice("runOnce done")
            await syncTrigger.reconcile(serverID: id)
            Self.syncLogger.notice("reconcile done: item=\(raw, privacy: .public)")
            await engine.syncNow()
            if finish(.newData) {
                Self.syncLogger.notice("syncNow done → newData")
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(25))
            work.cancel()   // 이미 끝난 작업 cancel 은 no-op.
            if finish(.failed) {
                Self.syncLogger.notice("watchdog: 25s 예산 초과 — 잔여 체인 협조 취소 → failed")
            }
        }
    }

    // MARK: - 알림 핸들러

    /// foreground 수신 — 분석 완료 alert 를 배너로 노출(앱이 켜져 있어도 보이게)하고, 동시에 해당 항목을
    /// 즉시 reconcile 한다(폴링 tick 대기 제거). `userInfo["mochiItemID"]` 는 server PK —
    /// RootFeature 가 `syncTrigger.reconcile(serverID:)` 로 가져오고, 반영은 observeChanges 로 열린
    /// 상세(로딩 중이면 완료 화면으로 전환)·홈에 전파된다. 탭과 달리 화면 전환은 없다.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        if let raw = userInfo["mochiItemID"] as? String, let id = UUID(uuidString: raw) {
            Task { @MainActor in MochiApp.rootStore.send(.analysisPushReceived(id)) }
        }
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
        // 능동 회수 알림(routeType="detail" + recallEventID) → ③ 회수 상세 직행. recallEventID 는 항상
        // 존재해 landing fallback·반응추적 키가 된다(서버 fetch 로 빈 상세 금지). 기존 분석완료 알림은
        // mochiItemID(server PK) 로 기존 상세 경로를 탄다.
        if let routeType = userInfo["routeType"] as? String, routeType == "detail",
           let raw = userInfo["recallEventID"] as? String, let eventID = UUID(uuidString: raw) {
            Task { @MainActor in MochiApp.rootStore.send(.recallNotificationTapped(recallEventID: eventID)) }
        } else if let raw = userInfo["mochiItemID"] as? String, let id = UUID(uuidString: raw) {
            Task { @MainActor in MochiApp.rootStore.send(.notificationTapped(id)) }
        }
        completionHandler()
    }
}
