#if DEBUG

import ActivityKit
import Foundation
import UIKit
import UserNotifications

import CoreLiveActivity

/// 백탭 캡쳐 → use case 후보 노출 알림 UX 의 prototype (Tier 1 + 2 + 3 결합).
///
/// 앱 launch 직후 mock 흐름을 시작한다:
///
///   t=0s   : Live Activity 시작 (`.analyzing` phase). Lock Screen / Dynamic Island 에 "🐹
///            모찌 분석 중…" 표시.
///   t=10s  : Live Activity `.ready` 로 update + Interactive Notification 발송. 알림은
///            액션 버튼 4개 (후보 3개 + "다른 의도") 와 `categoryIdentifier=MOCK_USECASE_V0`
///            로 펼침 시 `MochiNotificationContent` 의 SwiftUI multi-select view 노출.
///   사용자  : Lock Screen Live Activity 의 후보 버튼 (SelectCandidateIntent) 또는 알림 액션
///            또는 알림 펼침 → multi-select 중 하나로 의도 선택.
///
/// Mock 데이터는 `lab/intent_v6_compressed_results.json` 의 마우스 캡쳐 케이스.
///
/// **DEBUG 한정** — release 빌드에 컴파일되지 않는다. 끄려면 `MochiApp.init()` 의 호출 주석.
enum MockUseCaseNotificationPrototype {

    static let categoryIdentifier = "MOCK_USECASE_V0"
    static let actionPrefix = "MOCK_USECASE_ACTION_"
    static let otherIntentActionID = actionPrefix + "OTHER"
    static let captureCaption = "마우스 살까 말까 고민중"

    static func scheduleAfterLaunch() {
        UNUserNotificationCenter.current().delegate = delegate
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            if let error = error {
                print("[MockUseCase] auth error: \(error)")
                return
            }
            guard granted else {
                print("[MockUseCase] notification permission denied — 시뮬레이터 설정에서 허용 필요")
                return
            }
            registerCategory()
            // Live Activity 는 즉시 시작 (analyzing phase). 10초 후 분석 완료 + 알림 발송.
            startLiveActivity()
            scheduleNotificationIn10Seconds()
            // 10초 뒤 Live Activity 도 .ready 로 update.
            Task { await Task.sleep(seconds: 10); await transitionActivityToReady() }
        }
    }

    // MARK: - Category (액션 버튼 + content extension 매칭)

    private static func registerCategory() {
        let candidateActions = mockCandidates().map { c in
            UNNotificationAction(
                identifier: actionPrefix + c.label,
                title: c.label,
                options: []
            )
        }
        let otherAction = UNNotificationAction(
            identifier: otherIntentActionID,
            title: "다른 의도",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: candidateActions + [otherAction],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "모찌가 캡쳐를 분류했어요",
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - Notification

    private static func scheduleNotificationIn10Seconds() {
        let candidates = mockCandidates()
        let topLabel = candidates.first?.label ?? "구매 고민"

        let content = UNMutableNotificationContent()
        content.title = "🐹 모찌에 저장됐어요"
        content.subtitle = captureCaption
        content.body = "어떤 의도로 남기셨나요? — 가장 그럴듯한 건 \"\(topLabel)\""
        content.categoryIdentifier = categoryIdentifier
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        // `NotificationContentExtension` 이 펼침 시 후보를 렌더하도록 userInfo 페이로드.
        content.userInfo = [
            "caption": captureCaption,
            "candidates": candidates.map { [
                "label": $0.label,
                "intent": $0.intent,
                "applicability": $0.applicability,
            ] },
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)
        let request = UNNotificationRequest(
            identifier: "mock-usecase-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[MockUseCase] schedule error: \(error)")
            } else {
                print("[MockUseCase] 알림 schedule — 10초 후 도착")
            }
        }
    }

    // MARK: - Live Activity

    /// 앱 launch 직후 시작. `.analyzing` phase 로 Lock Screen / Dynamic Island 점유.
    private static func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[MockUseCase] Live Activities 비활성화 — 설정 > 모찌 > Live Activity 켜기")
            return
        }
        let attributes = MockUseCaseActivityAttributes(captureCaption: captureCaption)
        let initialState = MockUseCaseActivityAttributes.ContentState(
            phase: .analyzing,
            candidates: mockCandidates(),
            selectedLabel: nil
        )
        do {
            let activity = try Activity<MockUseCaseActivityAttributes>.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            print("[MockUseCase] Live Activity 시작: \(activity.id)")
        } catch {
            print("[MockUseCase] Live Activity 시작 실패: \(error)")
        }
    }

    /// 10초 후 `.ready` 로 갱신.
    private static func transitionActivityToReady() async {
        for activity in Activity<MockUseCaseActivityAttributes>.activities {
            let ready = MockUseCaseActivityAttributes.ContentState(
                phase: .ready,
                candidates: mockCandidates(),
                selectedLabel: nil
            )
            await activity.update(.init(state: ready, staleDate: nil))
            print("[MockUseCase] Live Activity → .ready")
        }
    }

    // MARK: - Mock 후보

    static func mockCandidates() -> [MockUseCaseActivityAttributes.Candidate] {
        [
            .init(label: "구매 고민",   intent: "todo",      applicability: 0.95),
            .init(label: "가격 비교",   intent: "knowledge", applicability: 0.75),
            .init(label: "위시리스트", intent: "memo",      applicability: 0.55),
        ]
    }

    // MARK: - Delegate

    private static let delegate = ForegroundDelegate()

    private final class ForegroundDelegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .sound, .list])
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            let actionID = response.actionIdentifier
            switch actionID {
            case UNNotificationDefaultActionIdentifier:
                print("[MockUseCase] 알림 본체 탭 — 모찌 앱 진입")
            case UNNotificationDismissActionIdentifier:
                print("[MockUseCase] 알림 dismiss")
            case MockUseCaseNotificationPrototype.otherIntentActionID:
                print("[MockUseCase] '다른 의도' 선택 — 모찌 진입 (mock)")
            default:
                if actionID.hasPrefix(MockUseCaseNotificationPrototype.actionPrefix) {
                    let label = String(actionID.dropFirst(MockUseCaseNotificationPrototype.actionPrefix.count))
                    print("[MockUseCase] '\(label)' 알림 액션 선택 — 저장 (mock)")
                }
            }
            completionHandler()
        }
    }
}

private extension Task where Success == Never, Failure == Never {
    static func sleep(seconds: Double) async {
        let ns = UInt64(seconds * 1_000_000_000)
        try? await Task<Never, Never>.sleep(nanoseconds: ns)
    }
}

#endif
