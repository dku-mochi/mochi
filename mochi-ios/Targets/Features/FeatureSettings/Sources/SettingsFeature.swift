import Foundation
import UserNotifications
import ComposableArchitecture
import CoreAuth
import CoreDomain
import CorePersistence

@Reducer
public struct SettingsFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        /// 로그인 계정(이메일·이름). onAppear 에서 Keychain 세션을 읽어 채운다. nil = 미해결/로그아웃.
        public var account: Account?
        /// 푸시 알림 권한 상태(onAppear 에서 시스템 조회). 켜기 CTA·상태 칩 분기에 쓴다.
        public var notificationStatus: NotificationStatus = .unknown
        /// 민감 캡처를 항상 이 기기에만 저장할지(AppGroup 공유, ShareExtension 이 읽음).
        public var sensitiveAlwaysLocalOnly: Bool
        /// 회원 탈퇴 확인 다이얼로그 표시 여부.
        public var confirmingDelete: Bool = false
        /// 탈퇴 진행 중 — 중복 탭·이중 호출 차단.
        public var isDeletingAccount: Bool = false
        /// 탈퇴 실패 메시지(있으면 alert).
        public var deleteAccountError: String?

        public init() {
            self.sensitiveAlwaysLocalOnly = SensitiveCapturePreference.load()
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
        case sensitiveLocalOnlyChanged(Bool)
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

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .run { send in
                    let session = await authCoordinator.currentSession()
                    await send(.accountResolved(session.map { Account(user: $0.user) }))
                    let settings = await UNUserNotificationCenter.current().notificationSettings()
                    await send(.notificationStatusResolved(NotificationStatus(settings.authorizationStatus)))
                }

            case let .accountResolved(account):
                state.account = account
                return .none

            case let .notificationStatusResolved(status):
                state.notificationStatus = status
                return .none

            case let .sensitiveLocalOnlyChanged(value):
                state.sensitiveAlwaysLocalOnly = value
                SensitiveCapturePreference.save(value)
                return .none

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
