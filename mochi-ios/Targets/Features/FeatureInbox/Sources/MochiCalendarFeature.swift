import Foundation
import ComposableArchitecture
import CoreDomain
import CorePersistence

/// 모찌들(캘린더) 탭 reducer.
///
/// 로컬 Realm(`mochiItemRepository`)을 단일 소스로 ① 월간 캘린더(날짜별 개수·대표 Intent·대표 썸네일),
/// ② 날짜 선택 시 그날 모찌 목록, ③ 하단 "마감 임박 할 일"(미완료 todo) 을 구성한다.
/// 서버 list/calendar API 는 존재하지만(openapi.json), 이 탭은 즉시성·오프라인·실시간 반영
/// (`observeChanges`)을 위해 로컬 구동한다 — `DOMAIN_DESIGN.md §6`("모찌들 탭은 iOS 로컬 Realm 구동")과 정합.
@Reducer
public struct MochiCalendarFeature: Sendable {

    @ObservableState
    public struct State: Equatable, Sendable {
        /// 표시 중인 월의 기준 날짜(해당 월의 임의 날).
        public var monthAnchor: Date
        public var days: [CalendarDaySummary] = []
        public var upcomingTodos: IdentifiedArrayOf<MochiItem> = []
        /// 탭한 날짜(있으면 그날 목록 sheet).
        public var selectedDay: SelectedDay?
        public var selectedDayItems: IdentifiedArrayOf<MochiItem> = []
        public var isLoading: Bool = false

        public init(monthAnchor: Date = Date()) {
            self.monthAnchor = monthAnchor
        }
    }

    public enum Action: Sendable {
        case onAppear
        case repositoryChanged
        case monthStepped(Int)
        case loaded(days: [CalendarDaySummary], todos: [MochiItem])
        case daySelected(Date?)
        case dayItemsLoaded([MochiItem])
        case mochiItemTapped(MochiItem.ID)
    }

    @Dependency(\.mochiItemRepository) var repository

    private enum CancelID { case observe }

    /// 하단 마감 임박 할 일 표시 개수(스캔은 전량, 표시는 상한).
    static let upcomingTodoDisplayLimit = 20

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                state.isLoading = true
                let anchor = state.monthAnchor
                // 최초 load + 저장소 변경 관찰. observer 는 신호만 보내고(.repositoryChanged),
                // 실제 reload 는 reducer 가 '현재' monthAnchor 로 한다(월 이동 후 stale anchor 방지).
                return .merge(
                    .run { send in await loadMonth(anchor, send: send) },
                    .run { send in
                        for await _ in repository.observeChanges() {
                            await send(.repositoryChanged)
                        }
                    }
                    .cancellable(id: CancelID.observe, cancelInFlight: true)
                )

            case .repositoryChanged:
                let anchor = state.monthAnchor
                return .run { send in await loadMonth(anchor, send: send) }

            case let .monthStepped(delta):
                let calendar = Calendar.mochiSeoul
                if let stepped = calendar.date(byAdding: .month, value: delta, to: state.monthAnchor) {
                    state.monthAnchor = stepped
                }
                state.isLoading = true
                let anchor = state.monthAnchor
                return .run { send in await loadMonth(anchor, send: send) }

            case let .loaded(days, todos):
                state.isLoading = false
                state.days = days
                state.upcomingTodos = IdentifiedArray(uniqueElements: todos)
                return .none

            case let .daySelected(date):
                guard let date else {
                    state.selectedDay = nil
                    state.selectedDayItems = []
                    return .none
                }
                state.selectedDay = SelectedDay(date: date)
                let calendar = Calendar.mochiSeoul
                let start = calendar.startOfDay(for: date)
                guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return .none }
                return .run { send in
                    let items = (try? await repository.listCaptured(
                        in: DateInterval(start: start, end: end), limit: 200
                    )) ?? []
                    await send(.dayItemsLoaded(items))
                }

            case let .dayItemsLoaded(items):
                state.selectedDayItems = IdentifiedArray(uniqueElements: items)
                return .none

            case .mochiItemTapped:
                // 상위 Feature(MainTabFeature)가 상세로 라우팅.
                return .none
            }
        }
    }

    // MARK: - Loading

    private func loadMonth(_ anchor: Date, send: Send<Action>) async {
        let calendar = Calendar.mochiSeoul
        guard let monthInterval = calendar.dateInterval(of: .month, for: anchor) else {
            await send(.loaded(days: [], todos: []))
            return
        }
        // active todo 는 (사실상)전량 스캔 후 마감순 정렬 → 상위 N. captured 순으로 먼저 자르면
        // '오래 전 캡처 + 임박 마감' 을 놓친다(백엔드 ListUpcomingTodos 와 동일 정책).
        async let itemsTask: [MochiItem] = (try? await repository.listCaptured(in: monthInterval, limit: 2000)) ?? []
        async let todosTask: [MochiItem] = (try? await repository.listActiveTodos(limit: 500)) ?? []
        let (items, todos) = await (itemsTask, todosTask)
        await send(.loaded(
            days: CalendarDaySummary.group(items, calendar: calendar),
            todos: Array(UpcomingTodoSorter.sort(todos).prefix(Self.upcomingTodoDisplayLimit))
        ))
    }
}

// MARK: - View models

/// `.sheet(item:)` 용 Identifiable 래퍼(Date 는 Identifiable 이 아니다).
public struct SelectedDay: Identifiable, Equatable, Sendable {
    public let date: Date
    public var id: Date { date }
}

/// 캘린더 한 칸(하루)의 집계.
public struct CalendarDaySummary: Equatable, Sendable, Identifiable {
    public let date: Date              // startOfDay(로컬)
    public let count: Int
    public let representativeIntent: Intent?
    public let thumbnailRelativePath: String?
    public var id: Date { date }

    /// capturedAt desc 입력을 startOfDay 로 그룹핑 — 각 그룹 첫 항목이 그날 최신(대표 썸네일).
    static func group(_ items: [MochiItem], calendar: Calendar) -> [CalendarDaySummary] {
        var buckets: [Date: [MochiItem]] = [:]
        var order: [Date] = []
        for item in items {
            let day = calendar.startOfDay(for: item.source.capturedAt)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(item)
        }
        return order.map { day in
            let group = buckets[day] ?? []
            return CalendarDaySummary(
                date: day,
                count: group.count,
                representativeIntent: Self.representative(group),
                thumbnailRelativePath: group.lazy.compactMap { $0.source.imageRefs.first?.relativePath }.first
            )
        }
    }

    /// 그날 대표 Intent = 최빈값. 동률이면 더 최신(group 이 captured_at desc 라 먼저 등장)을
    /// 안정적으로 택한다 — `Dictionary.max` 의 비결정성으로 점 색이 매 로드마다 바뀌는 것 방지.
    private static func representative(_ group: [MochiItem]) -> Intent? {
        var counts: [Intent: Int] = [:]
        var firstIndex: [Intent: Int] = [:]
        for (index, item) in group.enumerated() {
            guard let intent = item.intent else { continue }
            counts[intent, default: 0] += 1
            if firstIndex[intent] == nil { firstIndex[intent] = index }
        }
        return counts.keys.max { lhs, rhs in
            if counts[lhs] != counts[rhs] { return counts[lhs]! < counts[rhs]! }
            return firstIndex[lhs]! > firstIndex[rhs]!   // 동률 → index 작은(최신) 쪽이 큼
        }
    }
}

/// 미완료 todo 를 마감 임박순으로 정렬. 마감일은 `actionCandidate`(reminder due / calendar start)에서 도출.
enum UpcomingTodoSorter {
    static func sort(_ todos: [MochiItem]) -> [MochiItem] {
        todos.sorted { lhs, rhs in
            switch (deadline(of: lhs), deadline(of: rhs)) {
            case let (l?, r?): return l < r                                   // 둘 다 마감 → 임박순
            case (_?, nil):    return true                                    // 마감 있는 것 먼저
            case (nil, _?):    return false
            case (nil, nil):   return lhs.source.capturedAt > rhs.source.capturedAt  // 둘 다 미상 → 최신순
            }
        }
    }

    /// todo 의 마감일 — reminder due 또는 calendar start. 파싱 실패 시 nil(마감 미상).
    static func deadline(of item: MochiItem) -> Date? {
        guard let candidates = item.analysis?.actionCandidates else { return nil }
        for candidate in candidates {
            switch candidate {
            case let .createReminder(_, due):
                if let due, let date = parseISO(due) { return date }
            case let .createCalendarEvent(_, start, _):
                if let date = parseISO(start) { return date }
            default:
                continue
            }
        }
        return nil
    }

    private static func parseISO(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) { return date }
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}

extension Calendar {
    /// 모찌들 탭의 모든 날짜 계산(월 경계·일 그룹·오늘·D-day)은 백엔드 KST 월간 집계와
    /// 일치시키기 위해 Asia/Seoul 로 고정한다. `Calendar.current`(기기 TZ)에 의존하면 월말
    /// UTC 캡처가 다른 날짜로 그룹돼 서버와 어긋난다.
    static let mochiSeoul: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        return calendar
    }()
}

extension DateFormatter {
    /// 모찌들 탭 표시용 한국어·KST 고정 포매터.
    static func mochiSeoul(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = format
        return formatter
    }
}
