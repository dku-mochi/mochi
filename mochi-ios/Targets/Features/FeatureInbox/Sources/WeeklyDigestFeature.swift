import Foundation
import ComposableArchitecture
import CoreDomain
import CorePersistence
import CoreNetworking
import DesignSystem

/// "이번주 정리 보기" 화면 reducer.
///
/// 모찌 미션("필요한 기억은 쉽게 떠오른다")에 맞춰 **모찌가 추려서 말 거는** 회고 화면이다.
/// 4-Intent 라벨은 사용자에게 노출하지 않고 행동·시간 단서로만 드러낸다.
///  - ① 모찌의 한마디: 서버 LLM 1문장(그 주 3건 미만이면 정적 폴백).
///  - ② 아직 안 끝났어요: 미해결 todo + 다가올 일정(서버가 마감 파싱·임박순). todo는 1-tap 완료.
///  - ③ 이번 주 이런 걸 모았어요: 정규화된 카테고리별 묶음(서버가 category 정규화 write).
///  - ④ 전체 보기: 그 주 전체 → 탭하면 상세.
///
/// 서버 응답은 서버 id 기준이라, 로컬(`listRecent`)에서 `syncState.uploaded` 로 역매핑해
/// 로컬 `MochiItem` 을 확보한다(상세 진입·로컬 완료 반영에 로컬 id 가 필요).
@Reducer
public struct WeeklyDigestFeature: Sendable {

    @ObservableState
    public struct State: Equatable, Sendable {
        public var greeting: String = ""
        public var isLoading: Bool = false
        /// ② 아직 안 끝났어요 (미해결 todo + 다가올 일정).
        public var upcoming: IdentifiedArrayOf<UpcomingItem> = []
        /// ③ 카테고리별 수확.
        public var groups: [DigestGroup] = []
        /// ④ 전체 보기.
        public var allWeekItems: IdentifiedArrayOf<MochiItem> = []
        /// 1-tap 완료 진행 중(낙관적 비활성).
        public var completingIDs: Set<UUID> = []
        public var lastError: String?

        public init() {}
    }

    public struct UpcomingItem: Equatable, Identifiable, Sendable {
        public var id: UUID { mochiItem.id }
        public let mochiItem: MochiItem
        /// 마감/일시 원문(서버 파싱 전 텍스트). 표시용.
        public let dueLabel: String?
        /// true=일정(표시·상세만), false=할 일(1-tap 완료 대상).
        public let isSchedule: Bool
        /// 완료 전이 대상 instance(서버=로컬 id 보존).
        public let instanceID: UUID
    }

    public struct DigestGroup: Equatable, Identifiable, Sendable {
        public var id: String { coarse }
        public let coarse: String
        public let items: [MochiItem]
    }

    public enum Action: Sendable {
        case onAppear
        case loaded(greeting: String, upcoming: [UpcomingItem], groups: [DigestGroup], all: [MochiItem])
        case loadFailed(String)
        case todoCompleteTapped(localID: UUID, instanceID: UUID)
        case todoCompleted(localID: UUID)
        case mochiItemTapped(MochiItem.ID, hero: HeroSourceFrames?)
        case delegate(Delegate)

        public enum Delegate: Sendable, Equatable {
            case mochiItemTapped(MochiItem.ID, hero: HeroSourceFrames?)
        }
    }

    @Dependency(\.mochiItemRepository) var repository
    @Dependency(\.mochiAPIClient) var apiClient
    @Dependency(\.date) var date

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                state.isLoading = true
                return .run { send in await load(send: send) }

            case let .loaded(greeting, upcoming, groups, all):
                state.isLoading = false
                state.greeting = greeting
                state.upcoming = IdentifiedArray(uniqueElements: upcoming)
                state.groups = groups
                state.allWeekItems = IdentifiedArray(uniqueElements: all)
                return .none

            case let .loadFailed(message):
                state.isLoading = false
                state.lastError = message
                return .none

            case let .todoCompleteTapped(localID, instanceID):
                guard !state.completingIDs.contains(localID) else { return .none }
                state.completingIDs.insert(localID)
                return .run { send in
                    do {
                        // 서버에 존재(업로드됨)하면 서버 전이 먼저, 이어 로컬 반영. 미업로드면 로컬만.
                        if let item = try await repository.find(id: localID),
                           case let .uploaded(serverID, _) = item.syncState {
                            _ = try await apiClient.updateInstanceLifecycle(
                                mochiServerID: serverID,
                                instanceID: instanceID,
                                to: .archived(reason: .todoCompleted)
                            )
                        }
                        try await repository.updateInstanceLifecycle(
                            mochiItemID: localID,
                            instanceID: instanceID,
                            to: .archived(reason: .todoCompleted)
                        )
                        await send(.todoCompleted(localID: localID))
                    } catch {
                        await send(.loadFailed(String(describing: error)))
                    }
                }

            case let .todoCompleted(localID):
                state.completingIDs.remove(localID)
                state.upcoming.remove(id: localID)
                return .none

            case let .mochiItemTapped(id, hero):
                return .send(.delegate(.mochiItemTapped(id, hero: hero)))

            case .delegate:
                return .none
            }
        }
    }

    // MARK: - 로드

    private func load(send: Send<Action>) async {
        let now = date.now
        let interval = Self.currentWeekInterval(now: now)
        let weekKey = Self.weekKey(now: now)

        let weekItems = (try? await repository.listCaptured(in: interval, limit: 500)) ?? []
        // 서버 id → 로컬 item 역매핑 풀(upcoming 은 그 주 밖일 수 있어 최근 전체에서 모은다).
        let recentLocal = (try? await repository.listRecent(limit: 300)) ?? []
        let serverToLocal = Self.serverToLocalMap(recentLocal + weekItems)

        // ① 모찌의 한마디 + 카테고리 정규화(필요 시 서버 호출).
        let greeting = await resolveGreeting(
            weekStart: interval.start,
            weekKey: weekKey,
            count: weekItems.count,
            serverToLocal: serverToLocal
        )

        // 정규화 반영 후 그 주를 다시 읽어 카테고리별로 묶는다.
        let refreshed = (try? await repository.listCaptured(in: interval, limit: 500)) ?? weekItems
        let groups = Self.makeGroups(refreshed)
        let upcoming = await loadUpcoming(serverToLocal: serverToLocal)

        await send(.loaded(greeting: greeting, upcoming: upcoming, groups: groups, all: refreshed))
    }

    /// 캐시 트리거(+3) 판정 후 필요하면 서버 digest 를 호출하고 category 를 로컬에 반영한다.
    private func resolveGreeting(
        weekStart: Date,
        weekKey: String,
        count: Int,
        serverToLocal: [UUID: MochiItem]
    ) async -> String {
        guard count >= 3 else { return WeeklyDigestCache.staticGreeting }
        let cache = WeeklyDigestCache.load()
        let shouldCall =
            cache == nil
            || cache?.weekKey != weekKey
            || count >= (cache?.itemCount ?? 0) + 3
        if !shouldCall, let cache, cache.weekKey == weekKey {
            return cache.greeting
        }
        guard let digest = try? await apiClient.weeklyDigest(weekStart: weekStart) else {
            // 호출 실패 — 같은 주 캐시가 있으면 재사용, 없으면 정적.
            if let cache, cache.weekKey == weekKey { return cache.greeting }
            return WeeklyDigestCache.staticGreeting
        }
        let greeting = digest.generated ? digest.greeting : WeeklyDigestCache.staticGreeting

        // 서버가 정규화한 category 를 로컬 Realm 에 반영(서버 id → 로컬 id 역매핑).
        var updates: [UUID: String] = [:]
        for group in digest.groups {
            for serverID in group.itemIDs {
                if let local = serverToLocal[serverID] { updates[local.id] = group.coarse }
            }
        }
        try? await repository.updateCategories(updates)

        WeeklyDigestCache.save(.init(weekKey: weekKey, itemCount: count, greeting: greeting))
        return greeting
    }

    /// ② 아직 안 끝났어요 — 서버 upcoming(todo+일정, 임박순)을 로컬 item 으로 역매핑.
    /// 서버 실패 시 로컬 미완료 todo 로 폴백한다(오프라인 안전망).
    private func loadUpcoming(serverToLocal: [UUID: MochiItem]) async -> [UpcomingItem] {
        if let dtos = try? await apiClient.upcomingActionables() {
            return dtos.compactMap { dto in
                guard let local = serverToLocal[dto.item.id] else { return nil }
                return UpcomingItem(
                    mochiItem: local,
                    dueLabel: dto.dueLabel,
                    isSchedule: dto.isSchedule,
                    instanceID: dto.instanceID
                )
            }
        }
        let todos = (try? await repository.listActiveTodos(limit: 20)) ?? []
        return todos.compactMap { item in
            guard let inst = item.instances.first(where: {
                $0.intentType == .todo && $0.lifecycle == .active
            }) else { return nil }
            return UpcomingItem(
                mochiItem: item,
                dueLabel: inst.payload.deadline ?? inst.payload.date,
                isSchedule: false,
                instanceID: inst.id
            )
        }
    }

    // MARK: - Helpers

    private static func serverToLocalMap(_ items: [MochiItem]) -> [UUID: MochiItem] {
        var map: [UUID: MochiItem] = [:]
        for item in items {
            if case let .uploaded(serverID, _) = item.syncState { map[serverID] = item }
        }
        return map
    }

    /// 카테고리별 묶음 — 빈/없는 카테고리는 "그 외". 항목 많은 그룹이 위로.
    static func makeGroups(_ items: [MochiItem]) -> [DigestGroup] {
        var byCategory: [String: [MochiItem]] = [:]
        var order: [String] = []
        for item in items {
            let raw = item.analysis?.category?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = (raw?.isEmpty == false) ? raw! : "그 외"
            if byCategory[label] == nil { order.append(label) }
            byCategory[label, default: []].append(item)
        }
        return order
            .map { DigestGroup(coarse: $0, items: byCategory[$0] ?? []) }
            .sorted { $0.items.count > $1.items.count }
    }

    /// 홈 카드 집계(HomeFeature.currentWeekInterval)와 동일 기준 — 월요일 시작, ko_KR.
    static func currentWeekInterval(now: Date) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ko_KR")
        calendar.timeZone = .autoupdatingCurrent
        calendar.firstWeekday = 2
        return calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: now, duration: 7 * 24 * 60 * 60)
    }

    static func weekKey(now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ko_KR")
        calendar.timeZone = .autoupdatingCurrent
        calendar.firstWeekday = 2
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        return "\(comps.yearForWeekOfYear ?? 0)-W\(comps.weekOfYear ?? 0)"
    }
}

/// 이번주 정리 greeting 로컬 캐시 — 메인 앱 프로세스 전용이라 UserDefaults 로 안전.
/// 트리거: 주가 바뀌거나 그 주 항목이 마지막 생성 시점 대비 +3 이상이면 서버를 다시 호출한다.
enum WeeklyDigestCache {
    static let staticGreeting = "이번 주는 차분했네요. 모아둔 기록은 제가 잘 정리해 둘게요."

    struct Entry: Codable, Equatable {
        let weekKey: String
        let itemCount: Int
        let greeting: String
    }

    private static let key = "mochi.weeklyDigest.v1"

    static func load() -> Entry? {
        guard let data = UserDefaults(suiteName: AppGroup.identifier)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    static func save(_ entry: Entry) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults(suiteName: AppGroup.identifier)?.set(data, forKey: key)
    }
}
