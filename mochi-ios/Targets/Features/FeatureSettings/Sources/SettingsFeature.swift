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
        /// "전체 동기화" 진행 중 — 버튼에 스피너 표시 + 중복 탭 차단.
        public var isSyncing: Bool = false
        /// 푸시 알림 권한 상태(onAppear 에서 시스템 조회). 켜기 CTA·상태 칩 분기에 쓴다.
        public var notificationStatus: NotificationStatus = .unknown
        /// 민감 캡처를 항상 이 기기에만 저장할지(AppGroup 공유, ShareExtension 이 읽음).
        public var sensitiveAlwaysLocalOnly: Bool

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
        /// 사용자가 "전체 동기화" 탭 — 서버→로컬 복구를 수동 트리거(재설치 복구의 보조 수단).
        case syncAllTapped
        case syncCompleted
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

    @Dependency(\.syncTrigger) var syncTrigger
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

            case .syncAllTapped:
                guard !state.isSyncing else { return .none }
                state.isSyncing = true
                return .run { send in
                    await syncTrigger.pullRemote()
                    await send(.syncCompleted)
                }

            case .syncCompleted:
                state.isSyncing = false
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
