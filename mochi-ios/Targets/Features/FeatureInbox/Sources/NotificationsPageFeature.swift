import Foundation
import ComposableArchitecture
import CoreNetworking

/// 알림 페이지 reducer — 홈에서 분리해온 "예정 알림" + 새 "지난 알림" 2탭.
///
/// **예정 탭**: 모찌가 보낼 예정인 미래 알림(마감/일정). 홈에서 통째로 옮겨와 veto(끄기)·
/// reschedule(미루기) 액션을 그대로 들고 온다("모찌가 정하고, 나는 조정한다").
/// **지난 탭**: 모찌가 이미 보낸 알림. 읽기 전용 — opened/dismissed 상태만 표시한다.
///
/// 두 탭은 별도 effect 로 로드하고 각각 실패 격리(`(try?…) ?? []`)한다 — 한쪽이 실패해도
/// 다른 탭은 채워진다. 빈손은 정상(cold-start).
@Reducer
public struct NotificationsPageFeature: Sendable {

    public enum Tab: String, Equatable, Sendable, CaseIterable {
        case upcoming   // 예정
        case sent       // 지난
    }

    @ObservableState
    public struct State: Equatable, Sendable {
        public var selectedTab: Tab = .upcoming
        /// "예정된 알림" — 모찌가 보낼 예정인 미래 마감·일정 알림(fire_at 오름차순).
        public var upcoming: [UpcomingNotificationDTO] = []
        /// "지난 알림" — 모찌가 이미 보낸 알림(sent_at 내림차순). 읽기 전용.
        public var sent: [SentNotificationDTO] = []
        public var isLoading: Bool = false

        public init(selectedTab: Tab = .upcoming) {
            self.selectedTab = selectedTab
        }
    }

    public enum Action: Sendable, BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        /// "예정" 로드(실패 격리 — 빈손이면 빈 상태).
        case upcomingLoaded([UpcomingNotificationDTO])
        /// "지난" 로드(실패 격리 — 빈손이면 빈 상태).
        case sentLoaded([SentNotificationDTO])
        /// 예정 알림 끄기 — 낙관적 즉시 제거 후 서버 veto 보고.
        case upcomingVetoed(eventID: UUID)
        /// 예정 알림 시각 조정 — 낙관적 즉시 반영(프리셋·DatePicker 공용) 후 서버 reschedule 보고.
        case upcomingRescheduled(eventID: UUID, fireAt: Date)
    }

    @Dependency(\.mochiAPIClient) var apiClient

    /// 두 로드는 별도 CancelID — 한쪽 재진입이 다른 쪽 in-flight 를 취소하지 않게.
    private enum CancelID { case upcoming, sent }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .onAppear:
                state.isLoading = true
                return .merge(
                    .run { send in await send(.upcomingLoaded((try? await apiClient.upcomingNotifications(limit: 50)) ?? [])) }
                        .cancellable(id: CancelID.upcoming, cancelInFlight: true),
                    .run { send in await send(.sentLoaded((try? await apiClient.sentNotifications(limit: 50)) ?? [])) }
                        .cancellable(id: CancelID.sent, cancelInFlight: true)
                )

            case let .upcomingLoaded(entries):
                state.isLoading = false
                state.upcoming = entries
                return .none

            case let .sentLoaded(entries):
                state.isLoading = false
                state.sent = entries
                return .none

            case let .upcomingVetoed(eventID):
                // 낙관적 UI — 즉시 목록에서 제거하고 서버에는 백그라운드 보고(undo 없음).
                state.upcoming.removeAll { $0.eventID == eventID }
                return .run { _ in try? await apiClient.vetoUpcoming(eventID: eventID) }

            case let .upcomingRescheduled(eventID, fireAt):
                // 낙관적 UI — 즉시 새 시각 반영(원안은 최초 1회 보존). 서버에는 백그라운드 보고.
                if let index = state.upcoming.firstIndex(where: { $0.eventID == eventID }) {
                    let current = state.upcoming[index]
                    state.upcoming[index] = UpcomingNotificationDTO(
                        eventID: current.eventID,
                        kind: current.kind,
                        fireAt: fireAt,
                        title: current.title,
                        body: current.body,
                        originalFireAt: current.originalFireAt ?? current.fireAt,
                        itemID: current.itemID,
                        intentID: current.intentID
                    )
                    // fire_at 오름차순 정합 유지 — 옮긴 항목이 새 시각 위치로 재정렬되게.
                    state.upcoming.sort { $0.fireAt < $1.fireAt }
                }
                return .run { _ in try? await apiClient.rescheduleUpcoming(eventID: eventID, fireAt: fireAt) }
            }
        }
    }
}
