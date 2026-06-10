import Dependencies
import Foundation
import UserNotifications

/// 채팅 reminder proposal 확정 → **iOS 로컬 알림** 등록.
///
/// 백엔드 테이블·스케줄러·푸시 배선 없음(journal 2026-06-10 설계 — 크로스디바이스 필요가
/// 생기면 그때 서버 푸시로 승격). 권한 거부는 에러가 아니라 명시적 실패 상태로 — 카드가
/// "설정에서 알림 허용"을 안내한다.
public protocol ReminderScheduler: Sendable {
    /// 권한 미결정이면 요청부터, 거부 상태면 ``ReminderSchedulingError/permissionDenied``.
    func schedule(id: UUID, title: String, fireAt: Date, relatedMochiItemID: UUID?) async throws
}

public enum ReminderSchedulingError: Error, Equatable, Sendable {
    case permissionDenied
    case invalidFireDate
}

public enum ReminderSchedulerKey: DependencyKey {
    public static let liveValue: any ReminderScheduler = LocalNotificationReminderScheduler()
    public static let testValue: any ReminderScheduler = UnimplementedReminderScheduler()
}

public extension DependencyValues {
    var reminderScheduler: any ReminderScheduler {
        get { self[ReminderSchedulerKey.self] }
        set { self[ReminderSchedulerKey.self] = newValue }
    }
}

public struct UnimplementedReminderScheduler: ReminderScheduler {
    public init() {}
    public func schedule(id: UUID, title: String, fireAt: Date, relatedMochiItemID: UUID?) async throws {
        throw ReminderSchedulingError.permissionDenied
    }
}

public struct LocalNotificationReminderScheduler: ReminderScheduler {
    public init() {}

    public func schedule(id: UUID, title: String, fireAt: Date, relatedMochiItemID: UUID?) async throws {
        guard fireAt > Date() else { throw ReminderSchedulingError.invalidFireDate }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { throw ReminderSchedulingError.permissionDenied }
        case .denied:
            throw ReminderSchedulingError.permissionDenied
        default:
            break
        }

        let content = UNMutableNotificationContent()
        content.title = "모찌 알림"
        content.body = title
        content.sound = .default
        if let relatedMochiItemID {
            // 딥링크 후속 작업용 — 현재는 보존만 (related id 실재 미검증은 알려진 nit).
            content.userInfo = ["mochiItemID": relatedMochiItemID.uuidString]
        }

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: fireAt
        )
        let request = UNNotificationRequest(
            identifier: "chat-reminder-\(id.uuidString)",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        try await center.add(request)
    }
}
