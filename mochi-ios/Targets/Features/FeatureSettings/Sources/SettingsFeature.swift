import Foundation
import UserNotifications
import ComposableArchitecture
import CoreAuth
import CoreDomain
import CoreIntegrations
import CoreNetworking
import CorePersistence

@Reducer
public struct SettingsFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        /// 로그인 계정(이메일·이름). onAppear 에서 Keychain 세션을 읽어 채운다. nil = 미해결/로그아웃.
        public var account: Account?
        /// 푸시 알림 권한 상태(onAppear 에서 시스템 조회). 켜기 CTA·상태 칩 분기에 쓴다.
        public var notificationStatus: NotificationStatus = .unknown
        /// 서버 알림 전역 선호(회수 푸시 / 분석 확인). nil = 미로드(로드 실패 포함) — 토글 비표시.
        /// 발송 시점 게이트만 바꾸는 가역 밸브라 끄면 조용해지고 다시 켜면 재개된다.
        public var notificationPreferences: NotificationPreferencesDTO?
        /// 선호 저장 실패 — 낙관 반영을 롤백한 뒤 alert 로 알린다.
        public var preferenceSaveFailed: Bool = false
        /// 민감 캡처를 항상 이 기기에만 저장할지(AppGroup 공유, ShareExtension 이 읽음).
        public var sensitiveAlwaysLocalOnly: Bool
        /// 확정 일정·할 일의 시스템 캘린더·미리알림 자동 등록(기기 로컬 밸브, 기본 on — §1.5 자동 관리).
        /// off 는 신규 등록·갱신 중단만 — 이미 등록된 EK 항목은 건드리지 않는다.
        public var calendarAutoRegistration: Bool
        /// 회원 탈퇴 확인 다이얼로그 표시 여부.
        public var confirmingDelete: Bool = false
        /// 탈퇴 진행 중 — 중복 탭·이중 호출 차단.
        public var isDeletingAccount: Bool = false
        /// 탈퇴 실패 메시지(있으면 alert).
        public var deleteAccountError: String?

        public init() {
            self.sensitiveAlwaysLocalOnly = SensitiveCapturePreference.load()
            self.calendarAutoRegistration = SystemCalendarAutoRegistrationPreference.load()
        }
    }

    public struct Account: Equatable, Sendable {
        public let name: String
        public let email: String

        public init(user: AuthUser) {
            let trimmed = user.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            self.name = trimmed.isEmpty ? "모찌 사용자" : trimmed
            self.email = user.email
        }

        /// 계정 보조 줄 — Apple 비공개 릴레이 이메일은 의미 없는 주소 대신 "Apple로 로그인" 으로 보여준다.
        public var detail: String {
            if email.hasSuffix("@privaterelay.appleid.com") { return "Apple로 로그인" }
            return email
        }
    }

    public enum NotificationStatus: Equatable, Sendable {
        case unknown, notDetermined, denied, authorized
    }

    public enum Action: Sendable {
        case onAppear
        case accountResolved(Account?)
        case notificationStatusResolved(NotificationStatus)
        case notificationPreferencesResolved(NotificationPreferencesDTO?)
        case recallNotificationsToggled(Bool)
        case analysisNotificationsToggled(Bool)
        case recallPreferenceRollback(Bool)
        case analysisPreferenceRollback(Bool)
        case preferenceErrorDismissed
        case sensitiveLocalOnlyChanged(Bool)
        case calendarAutoRegistrationToggled(Bool)
        case deleteAccountTapped
        case confirmingDeleteChanged(Bool)
        case deleteAccountConfirmed
        case deleteAccountSucceeded
        case deleteAccountFailed(String)
        case deleteErrorDismissed
        case onboardingButtonTapped
        case logoutButtonTapped
        case delegate(Delegate)

        public enum Delegate: Equatable, Sendable {
            case onboardingRequested
            /// 로그아웃 요청 — 실제 세션 해제(토큰 revoke + 로컬 clear)는 상위
            /// ``RootFeature.requestSignOut`` 이 수행한다. 여기선 신호만 올린다.
            case logoutRequested
        }
    }

    @Dependency(\.authCoordinator) var authCoordinator
    @Dependency(\.mochiAPIClient) var apiClient
    @Dependency(\.calendarSyncer) var calendarSyncer
    @Dependency(\.systemCalendarSyncEngine) var calendarSyncEngine

    private enum CancelID { case recallPreference, analysisPreference }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .run { [apiClient] send in
                    let session = await authCoordinator.currentSession()
                    await send(.accountResolved(session.map { Account(user: $0.user) }))
                    let settings = await UNUserNotificationCenter.current().notificationSettings()
                    await send(.notificationStatusResolved(NotificationStatus(settings.authorizationStatus)))
                    // 서버 선호는 best-effort — 실패하면 nil 유지(토글 비표시), 권한 칩·딥링크는 그대로.
                    let preferences = try? await apiClient.notificationPreferences()
                    await send(.notificationPreferencesResolved(preferences))
                }

            case let .accountResolved(account):
                state.account = account
                return .none

            case let .notificationStatusResolved(status):
                state.notificationStatus = status
                return .none

            case let .notificationPreferencesResolved(preferences):
                state.notificationPreferences = preferences
                return .none

            case let .recallNotificationsToggled(enabled):
                guard let current = state.notificationPreferences else { return .none }
                // 낙관 반영 → 서버 PATCH(해당 필드만), 실패 시 그 필드만 롤백(FavoriteSync 관례의 축소판).
                // 롤백은 현재 상태 위에 얹는다 — 병행 중인 다른 토글의 성공을 덮어쓰지 않게(codex P1).
                // 같은 필드 연타는 cancelInFlight 로 마지막 요청만 살아 stale 롤백이 없다(취소는 catch 미호출).
                let previousValue = current.recallEnabled
                state.notificationPreferences = NotificationPreferencesDTO(
                    recallEnabled: enabled, analysisEnabled: current.analysisEnabled
                )
                return .run { [apiClient] _ in
                    _ = try await apiClient.updateNotificationPreferences(
                        recallEnabled: enabled, analysisEnabled: nil
                    )
                } catch: { _, send in
                    await send(.recallPreferenceRollback(previousValue))
                }
                .cancellable(id: CancelID.recallPreference, cancelInFlight: true)

            case let .analysisNotificationsToggled(enabled):
                guard let current = state.notificationPreferences else { return .none }
                let previousValue = current.analysisEnabled
                state.notificationPreferences = NotificationPreferencesDTO(
                    recallEnabled: current.recallEnabled, analysisEnabled: enabled
                )
                return .run { [apiClient] _ in
                    _ = try await apiClient.updateNotificationPreferences(
                        recallEnabled: nil, analysisEnabled: enabled
                    )
                } catch: { _, send in
                    await send(.analysisPreferenceRollback(previousValue))
                }
                .cancellable(id: CancelID.analysisPreference, cancelInFlight: true)

            case let .recallPreferenceRollback(previousValue):
                if let current = state.notificationPreferences {
                    state.notificationPreferences = NotificationPreferencesDTO(
                        recallEnabled: previousValue, analysisEnabled: current.analysisEnabled
                    )
                }
                state.preferenceSaveFailed = true
                return .none

            case let .analysisPreferenceRollback(previousValue):
                if let current = state.notificationPreferences {
                    state.notificationPreferences = NotificationPreferencesDTO(
                        recallEnabled: current.recallEnabled, analysisEnabled: previousValue
                    )
                }
                state.preferenceSaveFailed = true
                return .none

            case .preferenceErrorDismissed:
                state.preferenceSaveFailed = false
                return .none

            case let .sensitiveLocalOnlyChanged(value):
                state.sensitiveAlwaysLocalOnly = value
                SensitiveCapturePreference.save(value)
                return .none

            case let .calendarAutoRegistrationToggled(enabled):
                state.calendarAutoRegistration = enabled
                SystemCalendarAutoRegistrationPreference.save(enabled)
                // off 는 신규 등록·갱신 중단만 — 이미 등록된 EK 항목은 건드리지 않는다(§3.4d).
                guard enabled else { return .none }
                return .run { [calendarSyncer, calendarSyncEngine] _ in
                    // 켜는 순간이 자연스러운 권한 프롬프트 시점(엔진은 스스로 묻지 않는 규약).
                    // 거부해도 토글은 유지 — 이후 권한이 열리면 다음 동기화가 따라잡는다(best-effort).
                    try? await calendarSyncer.requestEventAccess()
                    try? await calendarSyncer.requestReminderAccess()
                    await calendarSyncEngine.syncNow()   // 밀린 확정 일정·할 일 즉시 따라잡기
                }

            case .deleteAccountTapped:
                state.confirmingDelete = true
                return .none

            case let .confirmingDeleteChanged(value):
                state.confirmingDelete = value
                return .none

            case .deleteAccountConfirmed:
                guard !state.isDeletingAccount else { return .none }
                state.confirmingDelete = false
                state.isDeletingAccount = true
                return .run { send in
                    do {
                        try await authCoordinator.deleteAccount()
                        await send(.deleteAccountSucceeded)
                    } catch {
                        await send(.deleteAccountFailed(String(describing: error)))
                    }
                }

            case .deleteAccountSucceeded:
                // 서버 삭제 완료 → 로그아웃 경로로 로컬 세션 정리 + 로그인 화면 복귀(refresh 도 함께 revoke).
                return .send(.delegate(.logoutRequested))

            case let .deleteAccountFailed(message):
                state.isDeletingAccount = false
                state.deleteAccountError = message
                return .none

            case .deleteErrorDismissed:
                state.deleteAccountError = nil
                return .none

            case .onboardingButtonTapped:
                return .send(.delegate(.onboardingRequested))

            case .logoutButtonTapped:
                return .send(.delegate(.logoutRequested))

            case .delegate:
                return .none
            }
        }
    }
}

extension SettingsFeature.NotificationStatus {
    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional, .ephemeral: self = .authorized
        case .denied: self = .denied
        case .notDetermined: self = .notDetermined
        @unknown default: self = .unknown
        }
    }
}
