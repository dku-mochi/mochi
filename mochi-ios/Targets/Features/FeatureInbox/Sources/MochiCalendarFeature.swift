import Foundation
import ComposableArchitecture
import CoreDomain
import CorePersistence

/// 캘린더 탭 reducer.
///
/// 로컬 Realm(`mochiItemRepository`)을 단일 소스로 ① 월간 캘린더(날짜별 개수·대표 Intent·대표 썸네일),
/// ② 날짜 선택 시 그날 모찌 목록, ③ 하단 "마감 임박 할 일"(미완료 todo) 을 구성한다.
/// 서버 list/calendar API 는 존재하지만(openapi.json), 이 탭은 즉시성·오프라인·실시간 반영
/// (`observeChanges`)을 위해 로컬 구동한다 — `DOMAIN_DESIGN.md §6`("캘린더 탭은 iOS 로컬 Realm 구동")과 정합.
@Reducer
public struct MochiCalendarFeature: Sendable {

    @ObservableState
    public struct State: Equatable, Sendable {
        /// 표시 중인 월의 기준 날짜(해당 월의 임의 날).
        public var monthAnchor: Date
        public var days: [CalendarDaySummary] = []
        public var upcomingTodos: IdentifiedArrayOf<MochiItem> = []
        /// 마감(todo)·일정(schedule) 마커 + 날짜 sheet 의 원천 (payload 날짜 기준).
        public var dueItems: [MochiItem] = []
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
        case loaded(days: [CalendarDaySummary], todos: [MochiItem], dueItems: [MochiItem])
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

            case let .loaded(days, todos, dueItems):
                state.isLoading = false
                state.days = days
                state.upcomingTodos = IdentifiedArray(uniqueElements: todos)
                state.dueItems = dueItems
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
                // 그날 마감(todo)·일정(schedule)인 항목 — 다른 날 캡처됐어도 이 날짜에 함께 보여준다.
                let dueOnDay = state.dueItems.filter { item in
                    CalendarDueDate.dueDates(of: item).contains { calendar.isDate($0.date, inSameDayAs: date) }
                }
                return .run { send in
                    let captured = (try? await repository.listCaptured(
                        in: DateInterval(start: start, end: end), limit: 200
                    )) ?? []
                    let capturedIDs = Set(captured.map(\.id))
                    let merged = captured + dueOnDay.filter { !capturedIDs.contains($0.id) }
                    await send(.dayItemsLoaded(merged))
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
            await send(.loaded(days: [], todos: [], dueItems: []))
            return
        }
        // active todo 는 (사실상)전량 스캔 후 마감순 정렬 → 상위 N. captured 순으로 먼저 자르면
        // '오래 전 캡처 + 임박 마감' 을 놓친다(백엔드 ListUpcomingTodos 와 동일 정책).
        // 캘린더 마커는 두 축 — ① 저장 점(capturedAt, 이 달 캡처) ② 마감/일정 마커(todo 마감일·
        // schedule 일정 날짜). ②는 다른 달 캡처라도 날짜가 이 달이면 떠야 해 capturedAt 구간이 아니라
        // active todo·schedule 을 (상위 500 한정) 스캔한다 — 현 데이터 규모엔 충분, 초과분은 누락 가능.
        async let itemsTask: [MochiItem] = (try? await repository.listCaptured(in: monthInterval, limit: 2000)) ?? []
        async let todosTask: [MochiItem] = (try? await repository.listActiveTodos(limit: 500)) ?? []
        async let schedulesTask: [MochiItem] = (try? await repository.listByIntent(.schedule, limit: 500)) ?? []
        let (items, todos, schedules) = await (itemsTask, todosTask, schedulesTask)
        let dueItems = CalendarDueDate.merge(todos: todos, schedules: schedules)
        await send(.loaded(
            days: CalendarDaySummary.group(captured: items, due: dueItems, calendar: calendar),
            todos: Array(UpcomingTodoSorter.sort(todos).prefix(Self.upcomingTodoDisplayLimit)),
            dueItems: dueItems
        ))
    }
}

// MARK: - View models

/// `.sheet(item:)` 용 Identifiable 래퍼(Date 는 Identifiable 이 아니다).
public struct SelectedDay: Identifiable, Equatable, Sendable {
    public let date: Date
    public var id: Date { date }
}

/// 캘린더 한 칸(하루)의 집계 — 두 축을 독립 인코딩한다.
/// ① 저장(capturedAt): 가운데 점(대표 intent 색) + 개수. ② 마감/일정(payload 날짜): 날짜 숫자 강조.
public struct CalendarDaySummary: Equatable, Sendable, Identifiable {
    public let date: Date              // startOfDay(KST)
    /// 그날 **저장(capturedAt)** 개수.
    public let count: Int
    /// 저장 점 색 — 그날 캡처된 것들의 대표 intent (저장 없으면 nil).
    public let representativeIntent: Intent?
    public let thumbnailRelativePath: String?
    /// 그날 **마감(todo)·일정(schedule)** 개수.
    public let dueCount: Int
    /// 마감/일정 강조 색 — `schedule > todo` 우선 (없으면 nil).
    public let dueIntent: Intent?
    public var id: Date { date }

    public var hasCaptured: Bool { count > 0 }
    public var hasDue: Bool { dueCount > 0 }

    /// 두 축으로 집계 — ① captured(capturedAt) ② due(todo 마감일·schedule 일정 날짜, `CalendarDueDate`).
    /// captured 는 capturedAt desc 입력이라 각 그룹 첫 항목이 그날 최신(대표 썸네일).
    static func group(captured: [MochiItem], due: [MochiItem], calendar: Calendar) -> [CalendarDaySummary] {
        var capturedByDay: [Date: [MochiItem]] = [:]
        for item in captured {
            let day = calendar.startOfDay(for: item.source.capturedAt)
            capturedByDay[day, default: []].append(item)
        }
        var dueByDay: [Date: [Intent]] = [:]
        for item in due {
            for entry in CalendarDueDate.dueDates(of: item) {
                let day = calendar.startOfDay(for: entry.date)
                dueByDay[day, default: []].append(entry.intent)
            }
        }
        let allDays = Set(capturedByDay.keys).union(dueByDay.keys)
        return allDays.sorted().map { day in
            let group = capturedByDay[day] ?? []
            let dueIntents = dueByDay[day] ?? []
            return CalendarDaySummary(
                date: day,
                count: group.count,
                representativeIntent: Self.representative(group),
                thumbnailRelativePath: group.lazy.compactMap { $0.source.imageRefs.first?.relativePath }.first,
                dueCount: dueIntents.count,
                dueIntent: Self.dueRepresentative(dueIntents)
            )
        }
    }

    /// 그날 대표 Intent = **고정 우선순위** `schedule > todo > knowledge > memo` 중 그날 instance 에
    /// 존재하는 최상위. 최빈값/점수 argmax 폐기 — 의미 우선순위가 점 색의 단일 결정 기준이라
    /// 매 로드마다 점 색이 안정적이다.
    private static func representative(_ group: [MochiItem]) -> Intent? {
        let priority: [Intent] = [.schedule, .todo, .knowledge, .memo]
        let present = Set(group.flatMap { $0.intentTypes })
        return priority.first { present.contains($0) }
    }

    /// 마감/일정 마커 색 — `schedule`(파랑) > `todo`(노랑) 우선.
    private static func dueRepresentative(_ intents: [Intent]) -> Intent? {
        let priority: [Intent] = [.schedule, .todo]
        let present = Set(intents)
        return priority.first { present.contains($0) }
    }
}

/// 미완료 todo 를 마감 임박순으로 정렬. 마감일은 active todo instance 의 `payload.deadline ?? payload.date`.
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

    /// todo 의 마감일 — active todo instance 의 `payload.deadline`(없으면 `payload.date`) 중 가장 이른 것.
    /// 자연어("회의 후" 등) 파싱 실패·마감 미상이면 nil. entities·actionCandidate 는 iOS 응답에서 항상
    /// 비어 있어(`MochiItemDTO+Analysis`) payload 가 유일한 소스다.
    static func deadline(of item: MochiItem) -> Date? {
        item.instances
            .filter { $0.intentType == .todo && $0.lifecycle == .active }
            .compactMap { CalendarDueDate.parse($0.payload.deadline ?? $0.payload.date) }
            .min()
    }
}

/// 캘린더 마커용 마감/일정 날짜 추출 — todo 마감일(active) + schedule 일정 날짜.
/// payload 의 날짜 문자열을 KST 기준 `Date` 로 파싱한다(자연어는 nil).
enum CalendarDueDate {
    /// item 의 마감/일정 날짜들. todo=active instance 의 `deadline ?? date`, schedule=instance 의 `date`.
    /// 한 캡처에 여러 instance(todo 둘, todo+schedule)면 각각 기여한다.
    static func dueDates(of item: MochiItem) -> [(date: Date, intent: Intent)] {
        item.instances.compactMap { inst in
            switch inst.intentType {
            case .todo:
                guard inst.lifecycle == .active,
                      let date = parse(inst.payload.deadline ?? inst.payload.date) else { return nil }
                return (date, .todo)
            case .schedule:
                // active 일정만 — 끝났거나(scheduleEnded) 사용자가 치운(userManual) 일정은 캘린더에서 제외
                // (todo 의 active 가드와 대칭, DOMAIN_DESIGN schedule lifecycle 정합).
                guard inst.lifecycle == .active,
                      let date = parse(inst.payload.date) else { return nil }
                return (date, .schedule)
            case .knowledge, .memo:
                return nil
            }
        }
    }

    /// 마커·sheet 원천 — todo(마감) + schedule(일정) item 을 id 중복 없이 합친다
    /// (한 캡처가 todo·schedule 둘 다일 수 있다).
    static func merge(todos: [MochiItem], schedules: [MochiItem]) -> [MochiItem] {
        var seen = Set<MochiItem.ID>()
        var result: [MochiItem] = []
        for item in todos + schedules where seen.insert(item.id).inserted {
            result.append(item)
        }
        return result
    }

    /// payload 날짜 문자열 → Date. ISO8601 / "yyyy-MM-dd'T'HH:mm" / "yyyy-MM-dd HH:mm" / "yyyy-MM-dd" 를
    /// 지원하고, TZ 미명시(날짜만 등)는 KST 로 해석한다. 파싱 불가(자연어)면 nil.
    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) { return date }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss",
                       "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}

extension Calendar {
    /// 캘린더 탭의 모든 날짜 계산(월 경계·일 그룹·오늘·D-day)은 백엔드 KST 월간 집계와
    /// 일치시키기 위해 Asia/Seoul 로 고정한다. `Calendar.current`(기기 TZ)에 의존하면 월말
    /// UTC 캡처가 다른 날짜로 그룹돼 서버와 어긋난다.
    static let mochiSeoul: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        return calendar
    }()
}

extension DateFormatter {
    /// 캘린더 탭 표시용 한국어·KST 고정 포매터.
    static func mochiSeoul(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = format
        return formatter
    }
}
