import Foundation
import ComposableArchitecture
import CoreNetworking
import CoreDomain
import CorePersistence

/// 알림 페이지 reducer — 홈에서 분리해온 "예정 알림" + 새 "지난 알림" 2탭.
///
/// **예정 탭**: 모찌가 보낼 예정인 미래 알림(마감/일정). 홈에서 통째로 옮겨와 veto(끄기)·
/// reschedule(미루기) 액션을 그대로 들고 온다("모찌가 정하고, 나는 조정한다").
/// **지난 탭**: 모찌가 이미 보낸 알림. 행 탭 → 원본 기록 상세를 열고 그 알림을 읽음 처리(opened 보고
/// + 낙관적 디밍)한다. opened/dismissed 는 회색·흐리게로 가라앉혀 안읽음과 구분한다.
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
        /// 알림 itemID(원본 캡처 server PK) → 썸네일·카테고리. 알림 DTO엔 없어, 회수와 같은 server PK
        /// 역매핑으로 로컬 기록에서 채운다(왼쪽 작은 캡처 썸네일 / 이미지 없으면 카테고리 아이콘 폴백).
        public var thumbnails: [UUID: ImageRef] = [:]
        public var categories: [UUID: String] = [:]
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
        /// itemID → 썸네일·카테고리 역매핑 결과(예정·받음 양쪽 itemID 분, 기존 맵에 머지).
        case metaResolved(thumbnails: [UUID: ImageRef], categories: [UUID: String])
        /// 예정 알림 끄기 — 낙관적 즉시 제거 후 서버 veto 보고.
        case upcomingVetoed(eventID: UUID)
        /// 예정 알림 시각 조정 — 낙관적 즉시 반영(프리셋·DatePicker 공용) 후 서버 reschedule 보고.
        case upcomingRescheduled(eventID: UUID, fireAt: Date)
        /// 받은 알림 행 탭 — 원본 기록 상세를 열고(상위 위임) 그 알림을 읽음 처리(opened 보고 + 낙관적 디밍).
        case sentNotificationTapped(SentNotificationDTO)
        case delegate(Delegate)

        public enum Delegate: Sendable, Equatable {
            /// 원본 기록 상세 열기 요청 — 상위(MainTab)가 server PK 로 present 한다.
            case openItemRequested(serverID: UUID)
        }
    }

    @Dependency(\.mochiAPIClient) var apiClient
    @Dependency(\.mochiItemRepository) var repository
    @Dependency(\.date) var date

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
                return resolveMetas(itemIDs: entries.compactMap(\.itemID))

            case let .sentLoaded(entries):
                state.isLoading = false
                state.sent = Self.sortedSent(entries)
                return resolveMetas(itemIDs: entries.compactMap(\.itemID))

            case let .metaResolved(thumbnails, categories):
                state.thumbnails.merge(thumbnails) { _, new in new }
                state.categories.merge(categories) { _, new in new }
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

            case let .sentNotificationTapped(entry):
                // 낙관적 읽음 — 즉시 디밍(서버 mark_opened 는 best-effort, kind 무관). 이미 읽음이면 그대로.
                if let i = state.sent.firstIndex(where: { $0.eventID == entry.eventID }), state.sent[i].openedAt == nil {
                    let e = state.sent[i]
                    state.sent[i] = SentNotificationDTO(
                        eventID: e.eventID, kind: e.kind, sentAt: e.sentAt, openedAt: date.now,
                        dismissedAt: e.dismissedAt, title: e.title, body: e.body,
                        itemID: e.itemID, intentID: e.intentID
                    )
                    // 읽음 처리된 카드는 즉시 아래로 — 안읽음을 위로 모은다(애니메이션 트랜잭션 안에서 재정렬돼 슬라이드).
                    state.sent = Self.sortedSent(state.sent)
                }
                return .merge(
                    .run { _ in try? await apiClient.recordRecallReaction(eventID: entry.eventID, reaction: .opened) },
                    entry.itemID.map { Effect.send(.delegate(.openItemRequested(serverID: $0))) } ?? .none
                )

            case .delegate:
                return .none
            }
        }
    }

    /// 받은 알림 정렬 — 안읽음이 위, 읽음(opened/dismissed)은 아래로. 각 그룹 내에선 최신(sent_at) 순.
    static func sortedSent(_ entries: [SentNotificationDTO]) -> [SentNotificationDTO] {
        entries.sorted { a, b in
            let aUnread = a.openedAt == nil && a.dismissedAt == nil
            let bUnread = b.openedAt == nil && b.dismissedAt == nil
            if aUnread != bUnread { return aUnread }
            return a.sentAt > b.sentAt
        }
    }

    /// itemID(server PK)로 로컬 기록을 찾아 썸네일(원본 캡처 이미지)·카테고리를 채운다(회수와 같은 경로).
    private func resolveMetas(itemIDs: [UUID]) -> Effect<Action> {
        .run { send in
            var thumbnails: [UUID: ImageRef] = [:]
            var categories: [UUID: String] = [:]
            for id in Set(itemIDs) {
                guard let item = try? await repository.find(serverID: id) else { continue }
                if let ref = item.source.imageRefs.first { thumbnails[id] = ref }
                if let category = item.analysis?.category?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !category.isEmpty {
                    categories[id] = category
                }
            }
            await send(.metaResolved(thumbnails: thumbnails, categories: categories))
        }
    }
}
