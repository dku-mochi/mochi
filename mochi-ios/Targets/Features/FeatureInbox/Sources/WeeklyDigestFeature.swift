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
///  - ② 이번 주 이런 걸 모았어요: 정규화된 카테고리별 가로 레일(서버가 category 정규화 write).
///    레일 항목 탭 → 상세, 헤더 "전체 보기" → 검색 탭을 그 카테고리로 필터(상위 위임).
///
/// 서버 응답은 서버 id 기준이라, 로컬(`listCaptured`)에서 `syncState.uploaded` 로 역매핑해
/// 로컬 `MochiItem` 을 확보한다(상세 진입에 로컬 id 가 필요).
@Reducer
public struct WeeklyDigestFeature: Sendable {

    @ObservableState
    public struct State: Equatable, Sendable {
        public var greeting: String = ""
        public var isLoading: Bool = false
        /// 카테고리별 수확(이번 주 모은 기억을 카테고리로 묶음).
        public var groups: [DigestGroup] = []
        /// 그 주 전체 항목(헤드라인 개수·정규화 대상).
        public var allWeekItems: IdentifiedArrayOf<MochiItem> = []
        public var lastError: String?

        public init() {}
    }

    public struct DigestGroup: Equatable, Identifiable, Sendable {
        public var id: String { coarse }
        public let coarse: String
        public let items: [MochiItem]
    }

    public enum Action: Sendable {
        case onAppear
        /// 1단계 — 로컬만으로 즉시 그릴 수 있는 전부. `needsGreeting` 이면 말풍선만 서버 보강 대기.
        case localLoaded(
            greeting: String,
            needsGreeting: Bool,
            groups: [DigestGroup],
            all: [MochiItem]
        )
        /// 2단계 — 서버 digest(LLM) 도착. greeting 과, 카테고리 정규화로 바뀐 groups/all(없으면 nil) 반영.
        case greetingResolved(greeting: String, groups: [DigestGroup]?, all: [MochiItem]?)
        case loadFailed(String)
        case mochiItemTapped(MochiItem.ID, hero: HeroSourceFrames?)
        /// 카테고리 레일 "전체 보기" — 검색 탭을 그 카테고리로 필터해 연다(상위 위임).
        case categoryViewAllTapped(String)
        case delegate(Delegate)

        public enum Delegate: Sendable, Equatable {
            case mochiItemTapped(MochiItem.ID, hero: HeroSourceFrames?)
            case categoryViewAllRequested(String)
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

            case let .localLoaded(greeting, needsGreeting, groups, all):
                // 로컬로 즉시 채운다. greeting 보강이 남았으면 isLoading 유지 → 말풍선만 skeleton.
                state.isLoading = needsGreeting
                state.greeting = greeting
                state.groups = groups
                state.allWeekItems = IdentifiedArray(uniqueElements: all)
                return .none

            case let .greetingResolved(greeting, groups, all):
                state.isLoading = false
                state.greeting = greeting
                if let groups { state.groups = groups }
                if let all { state.allWeekItems = IdentifiedArray(uniqueElements: all) }
                return .none

            case let .loadFailed(message):
                state.isLoading = false
                state.lastError = message
                return .none

            case let .mochiItemTapped(id, hero):
                return .send(.delegate(.mochiItemTapped(id, hero: hero)))

            case let .categoryViewAllTapped(category):
                return .send(.delegate(.categoryViewAllRequested(category)))

            case .delegate:
                return .none
            }
        }
    }

    // MARK: - 로드

    /// local-first 단계 로드 — 로컬로 즉시 그린 뒤(1단계), 서버 digest 의 greeting·카테고리 정규화를 보강한다(2단계).
    /// LLM 에 실제로 의존하는 건 말풍선뿐이라, 나머지(카테고리 묶음)는 ~로컬 조회 시간 내 뜬다.
    private func load(send: Send<Action>) async {
        let now = date.now
        let interval = Self.currentWeekInterval(now: now)
        let weekKey = Self.weekKey(now: now)

        let weekItems = (try? await repository.listCaptured(in: interval, limit: 500)) ?? []
        // 서버 id → 로컬 item 역매핑(서버가 정규화한 category 를 로컬에 반영할 때 로컬 id 필요).
        let serverToLocal = Self.serverToLocalMap(weekItems)

        // 1단계 — 즉시: 로컬만으로 그릴 수 있는 전부 + LLM 없이 확정되는 greeting(캐시/정적).
        let cache = WeeklyDigestCache.load()
        let immediate = Self.immediateGreeting(cache: cache, weekKey: weekKey, count: weekItems.count)
        await send(.localLoaded(
            greeting: immediate ?? "",
            needsGreeting: immediate == nil,
            groups: Self.makeGroups(weekItems),
            all: weekItems
        ))

        // 2단계 — greeting(LLM) 보강. 서버가 정규화한 category 를 반영해 묶음을 다시 그린다.
        await resolveGreetingRemote(
            send: send,
            interval: interval,
            weekKey: weekKey,
            count: weekItems.count,
            cache: cache,
            serverToLocal: serverToLocal,
            needed: immediate == nil
        )
    }

    /// 2단계 greeting 보강 — 1단계에서 확정 못한 경우(`needed`)에만 서버 digest 를 호출한다.
    /// 서버가 정규화한 category 를 로컬에 반영하고, 바뀐 묶음을 다시 그린다.
    private func resolveGreetingRemote(
        send: Send<Action>,
        interval: DateInterval,
        weekKey: String,
        count: Int,
        cache: WeeklyDigestCache.Entry?,
        serverToLocal: [UUID: MochiItem],
        needed: Bool
    ) async {
        guard needed else { return }
        guard let digest = try? await apiClient.weeklyDigest(weekStart: interval.start) else {
            // 호출 실패 — 같은 주 캐시가 있으면 재사용, 없으면 정적. groups/all 은 1단계 값 유지.
            let fallback = (cache?.weekKey == weekKey ? cache?.greeting : nil)
                ?? WeeklyDigestCache.staticGreeting
            await send(.greetingResolved(greeting: fallback, groups: nil, all: nil))
            return
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

        // 정규화 반영 후 그 주를 다시 읽어 카테고리별로 다시 묶는다(실패하면 1단계 묶음 유지).
        if let refreshed = try? await repository.listCaptured(in: interval, limit: 500) {
            await send(.greetingResolved(
                greeting: greeting,
                groups: Self.makeGroups(refreshed),
                all: refreshed
            ))
        } else {
            await send(.greetingResolved(greeting: greeting, groups: nil, all: nil))
        }
    }

    /// 1단계용 — LLM 없이 즉시 결정되는 greeting. nil 이면 서버 보강이 필요하다.
    /// 트리거는 기존 `resolveGreeting` 의 `shouldCall` 과 동일(주 미만 3건 정적 / 캐시 히트 / 주변경·+3 갱신).
    static func immediateGreeting(
        cache: WeeklyDigestCache.Entry?,
        weekKey: String,
        count: Int
    ) -> String? {
        guard count >= 3 else { return WeeklyDigestCache.staticGreeting }
        guard let cache, cache.weekKey == weekKey else { return nil }
        if count >= cache.itemCount + 3 { return nil }
        return cache.greeting
    }

    // MARK: - Helpers

    private static func serverToLocalMap(_ items: [MochiItem]) -> [UUID: MochiItem] {
        var map: [UUID: MochiItem] = [:]
        for item in items {
            if case let .uploaded(serverID, _) = item.syncState { map[serverID] = item }
        }
        return map
    }

    /// 카테고리 없는 항목의 묶음 라벨 — 실제 category 값이 아니라 표시용이라 검색 필터 대상이 아니다.
    static let uncategorizedLabel = "그 외"

    /// 카테고리별 묶음 — 빈/없는 카테고리는 "그 외". 항목 많은 그룹이 위로.
    static func makeGroups(_ items: [MochiItem]) -> [DigestGroup] {
        var byCategory: [String: [MochiItem]] = [:]
        var order: [String] = []
        for item in items {
            let raw = item.analysis?.category?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = (raw?.isEmpty == false) ? raw! : Self.uncategorizedLabel
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
