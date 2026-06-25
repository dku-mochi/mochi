import Foundation
import ComposableArchitecture
import CoreDomain
import CorePersistence
import CoreNetworking
import DesignSystem

/// "이번 달 정리 보기" 화면 reducer.
///
/// 모찌 미션("필요한 기억은 쉽게 떠오른다")에 맞춰 **모찌가 추려서 말 거는** 회고 화면이다.
/// 4-Intent 라벨은 사용자에게 노출하지 않고 행동·시간 단서로만 드러낸다.
///  - ① 모찌의 한마디: 서버 LLM 1문장(그 달 3건 미만이면 정적 폴백).
///  - ② 이번 달 이런 걸 모았어요: 정규화된 카테고리별 가로 레일(서버가 category 정규화 write).
///    레일 항목 탭 → 상세, 헤더 "전체 보기" → 그 카테고리를 3D 턴테이블(샤라락)로 push(상위 위임).
///
/// `monthOffset` 으로 과거 달을 넘겨볼 수 있다(0=이번 달, -1=지난달, …). 미래 달은 막는다.
/// **현재 달만** 서버 digest(LLM greeting + 카테고리 정규화 write)를 호출하고, 과거 달은 로컬
/// 집계만 보여준다 — 과거를 매번 재정규화하지 않아 비용·흔들림을 막는다(레일·개수는 100% 로컬).
///
/// 서버 응답은 서버 id 기준이라, 로컬(`listCaptured`)에서 `syncState.uploaded` 로 역매핑해
/// 로컬 `MochiItem` 을 확보한다(상세 진입에 로컬 id 가 필요).
@Reducer
public struct MonthlyDigestFeature: Sendable {

    @ObservableState
    public struct State: Equatable, Sendable {
        public var greeting: String = ""
        public var isLoading: Bool = false
        /// 보고 있는 달 — 0=이번 달, 음수면 과거(예: -1 지난달). 미래(양수)는 도달 불가.
        public var monthOffset: Int = 0
        /// 카테고리별 수확(이번 달 모은 기억을 카테고리로 묶음).
        public var groups: [DigestGroup] = []
        /// 그 달 전체 항목(헤드라인 개수·정규화 대상).
        public var allMonthItems: IdentifiedArrayOf<MochiItem> = []
        public var lastError: String?

        public init() {}

        /// 다음 달(더 최근)로 갈 수 있는가 — 이번 달이면 더 못 간다.
        public var canGoNextMonth: Bool { monthOffset < 0 }
    }

    public struct DigestGroup: Equatable, Identifiable, Sendable {
        public var id: String { coarse }
        public let coarse: String
        public let items: [MochiItem]
        /// coarse 가 실제 정규화된 category 값이라 검색 필터(전체 보기)로 갈 수 있는가.
        /// 의도 fallback 라벨·"정리 중"은 표시용이라 false.
        public let isSearchable: Bool
    }

    public enum Action: Sendable {
        case onAppear
        /// 이전 달(더 과거)로.
        case previousMonth
        /// 다음 달(더 최근)로 — 이번 달이 상한.
        case nextMonth
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
        /// 카테고리 레일 "전체 보기" — 그 카테고리를 3D 턴테이블(샤라락)로 연다(상위 위임).
        case categoryViewAllTapped(String)
        case delegate(Delegate)

        public enum Delegate: Sendable, Equatable {
            case mochiItemTapped(MochiItem.ID, hero: HeroSourceFrames?)
            case categoryViewAllRequested(CategoryBucket)
        }
    }

    @Dependency(\.mochiItemRepository) var repository
    @Dependency(\.mochiAPIClient) var apiClient
    @Dependency(\.date) var date

    /// 진행 중 로드 effect id — 달을 빠르게 넘길 때 이전 달 로드를 취소해
    /// 늦게 도착한 stale 응답이 다른 달의 화면·카테고리 정규화 write 를 덮지 않게 한다.
    private enum CancelID { case load }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                return reload(&state)

            case .previousMonth:
                state.monthOffset -= 1
                return reload(&state)

            case .nextMonth:
                guard state.canGoNextMonth else { return .none }
                state.monthOffset += 1
                return reload(&state)

            case let .localLoaded(greeting, needsGreeting, groups, all):
                // 로컬로 즉시 채운다. greeting 보강이 남았으면 isLoading 유지 → 말풍선만 skeleton.
                state.isLoading = needsGreeting
                state.greeting = greeting
                state.groups = groups
                state.allMonthItems = IdentifiedArray(uniqueElements: all)
                return .none

            case let .greetingResolved(greeting, groups, all):
                state.isLoading = false
                state.greeting = greeting
                if let groups { state.groups = groups }
                if let all { state.allMonthItems = IdentifiedArray(uniqueElements: all) }
                return .none

            case let .loadFailed(message):
                state.isLoading = false
                state.lastError = message
                return .none

            case let .mochiItemTapped(id, hero):
                return .send(.delegate(.mochiItemTapped(id, hero: hero)))

            case let .categoryViewAllTapped(coarse):
                // 그 카테고리 묶음을 버킷으로 조립해 3D 턴테이블(샤라락)로 보낸다(홈 카드와 동일 패턴·색·상한).
                guard let index = state.groups.firstIndex(where: { $0.coarse == coarse }) else { return .none }
                let group = state.groups[index]
                let bucket = CategoryBucket(
                    name: group.coarse,
                    count: group.items.count,
                    items: Array(group.items.prefix(MochiHomeFeature.carouselCoverCap)),
                    tintIndex: index
                )
                return .send(.delegate(.categoryViewAllRequested(bucket)))

            case .delegate:
                return .none
            }
        }
    }

    // MARK: - 로드

    /// 달 전환·진입 공통 — 이전 달 잔상을 지우고 isLoading 을 켠 뒤 그 달을 다시 읽는다.
    private func reload(_ state: inout State) -> Effect<Action> {
        state.isLoading = true
        state.groups = []
        state.allMonthItems = []
        let offset = state.monthOffset
        return .run { send in await load(send: send, offset: offset) }
            .cancellable(id: CancelID.load, cancelInFlight: true)
    }

    /// local-first 단계 로드 — 로컬로 즉시 그린 뒤(1단계), **현재 달일 때만** 서버 digest 의 greeting·
    /// 카테고리 정규화를 보강한다(2단계). 과거 달은 로컬 집계 + 정적 회고 인사로 끝낸다.
    private func load(send: Send<Action>, offset: Int) async {
        let now = date.now
        let interval = Self.monthInterval(offset: offset, now: now)
        let monthKey = Self.monthKey(offset: offset, now: now)
        let isCurrentMonth = offset == 0

        let monthItems = (try? await repository.listCaptured(in: interval, limit: Self.monthFetchLimit)) ?? []

        guard isCurrentMonth else {
            // 과거 달 — 로컬만. 서버 호출/정규화 없음(매번 재정규화·LLM 비용 회피).
            await send(.localLoaded(
                greeting: MonthlyDigestCache.pastGreeting,
                needsGreeting: false,
                groups: Self.makeGroups(monthItems),
                all: monthItems
            ))
            return
        }

        // 서버 id → 로컬 item 역매핑(서버가 정규화한 category 를 로컬에 반영할 때 로컬 id 필요).
        let serverToLocal = Self.serverToLocalMap(monthItems)

        // 1단계 — 즉시: 로컬만으로 그릴 수 있는 전부 + LLM 없이 확정되는 greeting(캐시/정적).
        let cache = MonthlyDigestCache.load()
        let immediate = Self.immediateGreeting(cache: cache, monthKey: monthKey, count: monthItems.count)
        await send(.localLoaded(
            greeting: immediate ?? "",
            needsGreeting: immediate == nil,
            groups: Self.makeGroups(monthItems),
            all: monthItems
        ))

        // 2단계 — greeting(LLM) 보강. 서버가 정규화한 category 를 반영해 묶음을 다시 그린다.
        await resolveGreetingRemote(
            send: send,
            interval: interval,
            monthKey: monthKey,
            count: monthItems.count,
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
        monthKey: String,
        count: Int,
        cache: MonthlyDigestCache.Entry?,
        serverToLocal: [UUID: MochiItem],
        needed: Bool
    ) async {
        guard needed else { return }
        guard let digest = try? await apiClient.monthlyDigest(monthStart: interval.start) else {
            // 호출 실패 — 같은 달 캐시가 있으면 재사용, 없으면 정적. groups/all 은 1단계 값 유지.
            let fallback = (cache?.monthKey == monthKey ? cache?.greeting : nil)
                ?? MonthlyDigestCache.staticGreeting
            await send(.greetingResolved(greeting: fallback, groups: nil, all: nil))
            return
        }
        let greeting = digest.generated ? digest.greeting : MonthlyDigestCache.staticGreeting

        // 서버가 정규화한 category 를 로컬 Realm 에 반영(서버 id → 로컬 id 역매핑).
        var updates: [UUID: String] = [:]
        for group in digest.groups {
            for serverID in group.itemIDs {
                if let local = serverToLocal[serverID] { updates[local.id] = group.coarse }
            }
        }
        try? await repository.updateCategories(updates)
        MonthlyDigestCache.save(.init(monthKey: monthKey, itemCount: count, greeting: greeting))

        // 정규화 반영 후 그 달을 다시 읽어 카테고리별로 다시 묶는다(실패하면 1단계 묶음 유지).
        if let refreshed = try? await repository.listCaptured(in: interval, limit: Self.monthFetchLimit) {
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
    /// 트리거는 기존 `resolveGreeting` 의 `shouldCall` 과 동일(달 미만 3건 정적 / 캐시 히트 / 달변경·+3 갱신).
    static func immediateGreeting(
        cache: MonthlyDigestCache.Entry?,
        monthKey: String,
        count: Int
    ) -> String? {
        guard count >= 3 else { return MonthlyDigestCache.staticGreeting }
        guard let cache, cache.monthKey == monthKey else { return nil }
        if count >= cache.itemCount + 3 { return nil }
        return cache.greeting
    }

    // MARK: - Helpers

    /// 한 달 분량 — 홈 월간 리포트(currentMonthInterval, 상한 800)와 같은 기준.
    static let monthFetchLimit = 800

    private static func serverToLocalMap(_ items: [MochiItem]) -> [UUID: MochiItem] {
        var map: [UUID: MochiItem] = [:]
        for item in items {
            if case let .uploaded(serverID, _) = item.syncState { map[serverID] = item }
        }
        return map
    }

    /// 아직 분석 전(`analysis == nil`)이라 카테고리를 모르는 항목의 묶음 라벨.
    /// 곧 분류될 항목이라 영구적 느낌의 "미분류"가 아니라 진행형으로 표시하고, 실제 category 값이
    /// 아니라 검색 필터(전체 보기) 대상이 아니다. 분석이 끝나면 자동으로 제 카테고리로 옮겨간다.
    static let pendingLabel = "정리 중"

    /// 카테고리별 묶음 — category 가 있으면 그 값으로, 없으면: 분석 전(`analysis == nil`)은 "정리 중",
    /// 분석됐지만 category 가 빈 항목은 의도 기반 fallback(홈과 동일: 일정/할 일/학습/기록)으로 분류한다.
    /// 미분류('그 외') 묶음은 만들지 않는다 — 모든 항목이 어딘가에 속한다. 항목 많은 그룹이 위로,
    /// "정리 중"은 분류된 묶음들 뒤(맨 끝).
    static func makeGroups(_ items: [MochiItem]) -> [DigestGroup] {
        var byLabel: [String: [MochiItem]] = [:]
        var order: [String] = []
        var searchable: [String: Bool] = [:]
        for item in items {
            let raw = item.analysis?.category?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label: String
            let isSearchable: Bool
            if let raw, !raw.isEmpty {
                label = raw
                isSearchable = true
            } else if item.analysis == nil {
                label = Self.pendingLabel
                isSearchable = false
            } else {
                label = MochiHomeFeature.fallbackCategory(for: item)
                isSearchable = false
            }
            if byLabel[label] == nil {
                order.append(label)
                searchable[label] = isSearchable
            }
            byLabel[label, default: []].append(item)
        }
        return order
            .map { DigestGroup(coarse: $0, items: byLabel[$0] ?? [], isSearchable: searchable[$0] ?? false) }
            .sorted { lhs, rhs in
                // "정리 중"(분석 전)은 분류된 묶음 뒤로, 나머지는 항목 수 내림차순.
                let lhsPending = lhs.coarse == Self.pendingLabel
                let rhsPending = rhs.coarse == Self.pendingLabel
                if lhsPending != rhsPending { return !lhsPending }
                return lhs.items.count > rhs.items.count
            }
    }

    /// 홈 월간 리포트 집계(MochiHomeFeature.currentMonthInterval)와 동일 기준 — KST 달, ko_KR.
    /// `offset` 으로 과거 달을 가리킨다(0=이번 달, -1=지난달).
    static func monthInterval(offset: Int, now: Date) -> DateInterval {
        let calendar = monthCalendar()
        let base = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let anchor = calendar.date(byAdding: .month, value: offset, to: base) ?? base
        return calendar.dateInterval(of: .month, for: anchor)
            ?? DateInterval(start: anchor, duration: 30 * 24 * 60 * 60)
    }

    static func monthKey(offset: Int, now: Date) -> String {
        let interval = monthInterval(offset: offset, now: now)
        let comps = monthCalendar().dateComponents([.year, .month], from: interval.start)
        return "\(comps.year ?? 0)-\(comps.month ?? 0)"
    }

    private static func monthCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ko_KR")
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }
}

/// 이번 달 정리 greeting 로컬 캐시 — 메인 앱 프로세스 전용이라 UserDefaults 로 안전.
/// 트리거: 달이 바뀌거나 그 달 항목이 마지막 생성 시점 대비 +3 이상이면 서버를 다시 호출한다.
enum MonthlyDigestCache {
    static let staticGreeting = "이번 달은 차분했네요. 모아둔 기록은 제가 잘 정리해 둘게요."
    /// 과거 달 회고 — 서버를 호출하지 않으므로 정적 한 줄로 끝낸다.
    static let pastGreeting = "그 달의 기억은 모찌가 잘 정리해 뒀어요."

    struct Entry: Codable, Equatable {
        let monthKey: String
        let itemCount: Int
        let greeting: String
    }

    private static let key = "mochi.monthlyDigest.v1"

    static func load() -> Entry? {
        guard let data = UserDefaults(suiteName: AppGroup.identifier)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    static func save(_ entry: Entry) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults(suiteName: AppGroup.identifier)?.set(data, forKey: key)
    }
}
