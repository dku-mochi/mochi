import Foundation
import ComposableArchitecture
import CoreDomain
import CorePersistence
import CoreNetworking
import CoreIntegrations
import DesignSystem

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
        /// 하단 "할 일" — **todo instance 단위** 행(한 아이템에 todo 여럿이면 각각 행). 미완료(마감임박순) + 완료(맨 밑).
        public var upcomingTodos: IdentifiedArrayOf<TodoRowItem> = []
        /// 표시에서 합쳐진 중복 todo — 대표 행 id → 숨겨진 쌍둥이 행들. 완료 토글 시 함께 전이된다.
        public var duplicateTodos: [UUID: [TodoRowItem]] = [:]
        /// 하단 "다가오는 일정" — 오늘 이후 일정 빠른순(시간축).
        public var upcomingSchedules: IdentifiedArrayOf<MochiItem> = []
        /// 마감(todo)·일정(schedule) 마커 + 날짜 sheet 의 원천 (payload 날짜 기준).
        public var dueItems: [MochiItem] = []
        /// 탭한 날짜(있으면 그날 목록 sheet).
        public var selectedDay: SelectedDay?
        public var selectedDayItems: IdentifiedArrayOf<MochiItem> = []
        public var isLoading: Bool = false
        /// 날짜에서 "일정 추가" 폼 — 있으면 폼 sheet 노출. nil = 닫힘.
        public var addScheduleDraft: ScheduleDraft?

        public init(monthAnchor: Date = Date()) {
            self.monthAnchor = monthAnchor
        }
    }

    /// 캘린더 날짜에서 직접 만드는 일정 폼 상태. `id` 는 ingest Idempotency-Key 로도 쓴다
    /// (폼 열 때 1회 생성 → 더블탭 저장이 같은 키라 중복 일정이 안 생긴다).
    public struct ScheduleDraft: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let date: Date     // 선택일 고정(비편집)
        public var title: String = ""
        public var time: Date?    // nil = 종일
        public var isSaving: Bool = false
        public var error: String?
    }

    public enum Action: Sendable {
        case onAppear
        case repositoryChanged
        case monthStepped(Int)
        /// 헤더 "오늘" — 현재 월로 점프.
        case todayTapped
        case loaded(
            days: [CalendarDaySummary],
            todos: [TodoRowItem],
            duplicateTodos: [UUID: [TodoRowItem]],
            schedules: [MochiItem],
            dueItems: [MochiItem]
        )
        case daySelected(Date?)
        case dayItemsLoaded([MochiItem])
        /// 항목 탭 — DaySheet 셀은 hero frame 을 실어 보내 셀→상세 zoom 전환의 시작점이 된다.
        case mochiItemTapped(MochiItem.ID, hero: HeroSourceFrames?)
        /// 할 일 체크박스 탭 — 그 todo instance 를 완료↔미완료 토글(로컬 낙관적 + 서버 push, 실패 시 롤백).
        case todoCompletionToggled(TodoRowItem)
        case operationFailed(String)
        // 날짜에서 일정 직접 추가 폼.
        case addScheduleTapped
        case draftTitleChanged(String)
        case draftTimeChanged(Date?)
        case saveDraftTapped
        case draftSaveFinished(String?)   // nil = 성공(폼 닫기), 값 = 저장 실패(폼 유지 + 메시지)
        case dismissDraft
    }

    @Dependency(\.mochiItemRepository) var repository
    @Dependency(\.mochiAPIClient) var apiClient
    @Dependency(\.syncTrigger) var syncTrigger
    @Dependency(\.calendarSyncer) var calendarSyncer
    @Dependency(\.uuid) var uuid

    private enum CancelID { case observe, load }

    /// 하단 마감 임박 할 일 표시 개수(스캔은 전량, 표시는 상한).
    static let upcomingTodoDisplayLimit = 20
    /// 완료한 일(접이식) 표시 상한 — 잘못 누른 완료를 되돌릴 수 있는 최근 분량만.
    static let completedTodoDisplayLimit = 10

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
                    .run { send in await loadMonth(anchor, send: send) }
                        .cancellable(id: CancelID.load, cancelInFlight: true),
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
                    .cancellable(id: CancelID.load, cancelInFlight: true)

            case let .monthStepped(delta):
                let calendar = Calendar.mochiSeoul
                if let stepped = calendar.date(byAdding: .month, value: delta, to: state.monthAnchor) {
                    state.monthAnchor = stepped
                }
                state.isLoading = true
                let anchor = state.monthAnchor
                // 빠른 연타 시 늦게 도착한 stale loaded 가 최신 월을 덮지 않게 직전 로드를 취소.
                return .run { send in await loadMonth(anchor, send: send) }
                    .cancellable(id: CancelID.load, cancelInFlight: true)

            case .todayTapped:
                state.monthAnchor = Date()
                state.isLoading = true
                let anchor = state.monthAnchor
                return .run { send in await loadMonth(anchor, send: send) }
                    .cancellable(id: CancelID.load, cancelInFlight: true)

            case let .loaded(days, todos, duplicateTodos, schedules, dueItems):
                state.isLoading = false
                state.days = days
                state.upcomingTodos = IdentifiedArray(uniqueElements: todos)
                state.duplicateTodos = duplicateTodos
                state.upcomingSchedules = IdentifiedArray(uniqueElements: schedules)
                state.dueItems = dueItems
                // 날짜 sheet 가 열려 있으면 그 날짜 목록도 같이 갱신한다 — 상세에서 수정/완료 후
                // repositoryChanged → loadMonth → loaded 흐름에서 sheet 가 stale 로 남던 것을 막는다
                // (재탭 불필요). SelectedDay.id == date 라 같은 날짜 재설정은 sheet 를 재present 하지 않는다.
                if let selected = state.selectedDay {
                    return .send(.daySelected(selected.date))
                }
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
                // 기간 일정은 시작~끝에 걸치는 모든 날에 뜬다(covers).
                let dueOnDay = state.dueItems.filter { item in
                    CalendarDueDate.dueDates(of: item).contains {
                        CalendarDueDate.covers($0, day: date, calendar: calendar)
                    }
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

            case let .todoCompletionToggled(row):
                // 표시에서 합쳐진 중복(같은 제목·마감)도 함께 전이 — 하나만 완료하면
                // 숨었던 쌍둥이가 미완료로 되살아나는 혼란을 막는다.
                let rows = [row] + (state.duplicateTodos[row.id] ?? [])
                return .merge(rows.map { toggleEffect(for: $0) })

            case .operationFailed:
                // 롤백은 이미 수행됨 — 현재는 silent(추후 토스트). observeChanges 가 최신 상태로 복구.
                return .none

            case .addScheduleTapped:
                guard let day = state.selectedDay?.date else { return .none }
                // id = 폼 1개당 1 UUID → ingest Idempotency-Key 로 재사용(더블탭 중복 방지).
                state.addScheduleDraft = ScheduleDraft(id: uuid(), date: day)
                return .none

            case let .draftTitleChanged(title):
                state.addScheduleDraft?.title = title
                return .none

            case let .draftTimeChanged(time):
                state.addScheduleDraft?.time = time
                return .none

            case .saveDraftTapped:
                // 저장 중 재탭 차단 — ingest 는 idempotencyKey 로 멱등이나 EventKit save 는 비멱등이라
                // 더블탭 시 시스템 캘린더에 같은 일정이 중복 등록된다(SystemCalendarRegistrar 주석 경고).
                guard let draft = state.addScheduleDraft, !draft.isSaving else { return .none }
                let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return .none }   // 폼 버튼도 비활성 병행
                state.addScheduleDraft?.isSaving = true
                state.addScheduleDraft?.error = nil
                let payload = Self.schedulePayload(date: draft.date, time: draft.time, title: title)
                let idempotencyKey = draft.id.uuidString
                return .run { [apiClient, syncTrigger, calendarSyncer] send in
                    do {
                        // 채팅 createSchedule 과 같은 경로 — confirmedInstances 직행(분석 생략, analyzed).
                        _ = try await apiClient.ingestMochiItem(
                            MochiItemIngestRequest(
                                channel: .appCalendar,
                                text: title,   // 검색·카드 제목 일관(propose.py 선례)
                                confirmedInstances: [
                                    ConfirmedInstanceIngestDTO(intentType: "schedule", payload: payload)
                                ]
                            ),
                            idempotencyKey: idempotencyKey
                        )
                    } catch {
                        // ingest 실패(네트워크 등) — 아무것도 안 생김. 폼 유지 + 재시도(같은 키라 멱등).
                        await send(.draftSaveFinished("저장에 실패했어요. 잠시 후 다시 시도해 주세요"))
                        return
                    }
                    await syncTrigger.pullRemote()   // 캘린더 점·DaySheet 즉시 반영(1a 가 sheet 갱신)
                    // 시스템 캘린더 등록은 best-effort — iOS 권한 프롬프트가 동의를 받고, 거부 시 모찌
                    // 기록은 이미 저장됐으므로 조용히 건너뛴다(채팅 createEvent 의 try? 규약과 동일).
                    try? await SystemCalendarRegistrar.register(
                        instances: [.init(intentType: "schedule", payload: payload)],
                        fallbackTitle: title,
                        using: calendarSyncer
                    )
                    await send(.draftSaveFinished(nil))
                }

            case let .draftSaveFinished(error):
                if let error {
                    state.addScheduleDraft?.isSaving = false
                    state.addScheduleDraft?.error = error
                } else {
                    state.addScheduleDraft = nil   // 성공 → 폼 닫기(목록은 pullRemote→observeChanges→1a 갱신)
                }
                return .none

            case .dismissDraft:
                state.addScheduleDraft = nil
                return .none
            }
        }
    }

    /// 한 todo instance 의 완료↔미완료 토글 effect — 로컬 낙관적 전이 + 서버 push(실패 시 롤백).
    /// push·레거시 치유·롤백은 기록 상세와 공용인 `TodoLifecycleSync`(CorePersistence)가 맡는다.
    private func toggleEffect(for row: TodoRowItem) -> Effect<Action> {
        let todo = row.instance
        let item = row.item
        let isCompleted = todo.lifecycle.kind == .archived
        let target: InstanceLifecycle = isCompleted ? .active : .archived(reason: .todoCompleted)
        return .run { send in
            // 낙관적 로컬 전이 — observeChanges 가 즉시 리스트를 다시 그린다.
            try? await repository.updateInstanceLifecycle(mochiItemID: item.id, instanceID: todo.id, to: target)
            if let failure = await TodoLifecycleSync.pushToggle(
                item: item, instance: todo, target: target,
                repository: repository, apiClient: apiClient
            ) {
                await send(.operationFailed(failure))
            }
        }
    }

    // MARK: - 일정 추가 폼

    /// 폼 입력 → confirmedInstances schedule payload(키는 백엔드/EventKit 규약과 1:1).
    /// date 는 항상 채운다(캘린더 점·시스템 등록의 소스). time 없으면 종일.
    static func schedulePayload(date: Date, time: Date?, title: String) -> [String: String] {
        let calendar = Calendar.mochiSeoul
        func formatter(_ format: String) -> DateFormatter {
            let f = DateFormatter()
            f.calendar = calendar
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = calendar.timeZone
            f.dateFormat = format
            return f
        }
        var payload = ["title": title, "date": formatter("yyyy-MM-dd").string(from: date)]
        if let time {
            payload["time"] = formatter("HH:mm").string(from: time)
        }
        return payload
    }

    // MARK: - Loading

    private func loadMonth(_ anchor: Date, send: Send<Action>) async {
        let calendar = Calendar.mochiSeoul
        guard let monthInterval = calendar.dateInterval(of: .month, for: anchor) else {
            await send(.loaded(days: [], todos: [], duplicateTodos: [:], schedules: [], dueItems: []))
            return
        }
        // active todo 는 (사실상)전량 스캔 후 마감순 정렬 → 상위 N. captured 순으로 먼저 자르면
        // '오래 전 캡처 + 임박 마감' 을 놓친다(백엔드 ListUpcomingTodos 와 동일 정책).
        // 캘린더 마커는 두 축 — ① 저장 점(capturedAt, 이 달 캡처) ② 마감/일정 마커(todo 마감일·
        // schedule 일정 날짜). ②는 다른 달 캡처라도 날짜가 이 달이면 떠야 해 capturedAt 구간이 아니라
        // active todo·schedule 을 (상위 500 한정) 스캔한다 — 현 데이터 규모엔 충분, 초과분은 누락 가능.
        async let itemsTask: [MochiItem] = (try? await repository.listCaptured(in: monthInterval, limit: 2000)) ?? []
        // active + 완료(archived) todo 를 함께 — 완료한 것도 리스트 맨 밑에 남기려면 active-only 로는 부족.
        async let todosTask: [MochiItem] = (try? await repository.listByIntent(.todo, limit: 500)) ?? []
        async let schedulesTask: [MochiItem] = (try? await repository.listByIntent(.schedule, limit: 500)) ?? []
        let (items, todos, schedules) = await (itemsTask, todosTask, schedulesTask)
        // 마커·sheet 원천은 active todo·active schedule 만 기여(CalendarDueDate.dueDates 가 거른다).
        let dueItems = CalendarDueDate.merge(todos: todos, schedules: schedules)
        // 같은 화면을 두 번 캡처해 todo 가 쌍둥이로 잡힌 경우 — 표시는 하나로 합치되,
        // 숨겨진 중복은 duplicateTodos 로 보존해 완료 토글이 함께 전이되게 한다.
        let (todoRows, duplicateTodos) = CalendarTodoSorter.dedupForDisplay(CalendarTodoSorter.rows(todos))
        let incomplete = todoRows.filter { !$0.isCompleted }.prefix(Self.upcomingTodoDisplayLimit)
        let completed = todoRows.filter(\.isCompleted).prefix(Self.completedTodoDisplayLimit)
        await send(.loaded(
            days: CalendarDaySummary.group(captured: items, due: dueItems, calendar: calendar),
            todos: Array(incomplete) + Array(completed),
            duplicateTodos: duplicateTodos,
            schedules: Array(UpcomingScheduleSorter.sort(schedules).prefix(Self.upcomingTodoDisplayLimit)),
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

/// "마감 임박 할 일" 리스트의 한 행 — **todo instance 단위**. 한 아이템에 todo 가 여럿이면 각각 행이 된다.
/// (이전엔 MochiItem 단위라 한 아이템의 여러 todo 가 1행으로 접혀, 2개 중 1개만 보였다.)
public struct TodoRowItem: Identifiable, Equatable, Sendable {
    public let item: MochiItem
    public let instance: IntentInstance
    public var id: UUID { instance.id }
    public var isCompleted: Bool { instance.lifecycle.kind == .archived }
    /// 그 instance 의 마감일 — `payload.deadline ?? payload.date` 파싱(자연어/미상은 nil).
    public var deadline: Date? { CalendarDueDate.parse(instance.payload.deadline ?? instance.payload.date) }
    /// 카드 본문 — todo 자신의 이름(`payload.title`)이 정본, 없으면 캡처 제목 폴백.
    public var displayTitle: String {
        if let title = instance.payload.title, !title.isEmpty { return title }
        return item.displayTitle
    }
}

/// 캘린더 한 칸(하루)의 집계 — 점 일정(sky 점) · 할 일 마감(butter 점) · 저장(purple 점)은
/// 같은 시각 언어(점)로, **기간 일정**(`endDate` 있는 schedule)만 날짜를 가로지르는 막대(sky)로
/// 인코딩한다 — 하루짜리 일정은 기존대로 점.
public struct CalendarDaySummary: Equatable, Sendable, Identifiable {
    public let date: Date              // startOfDay(KST)
    /// 그날 **저장(capturedAt)** 개수.
    public let count: Int
    public let thumbnailRelativePath: String?
    /// 그날 **마감(todo)·일정(schedule)** 개수 (기간 일정이 걸친 날 포함).
    public let dueCount: Int
    /// 그날 점 일정(schedule, 하루짜리) 있음 — sky 점.
    public let hasScheduleDue: Bool
    /// 그날 할 일 마감(todo) 있음 — butter 점.
    public let hasTodoDue: Bool
    /// 그날이 기간 일정(시작~끝)에 걸림 — sky 막대.
    public let hasRangeSchedule: Bool
    /// 막대가 전날에서 이어짐(왼끝 라운드 없음) / 다음날로 이어짐(오른끝 라운드 없음).
    public let rangeConnectsLeft: Bool
    public let rangeConnectsRight: Bool
    public var id: Date { date }

    public var hasCaptured: Bool { count > 0 }
    public var hasDue: Bool { dueCount > 0 }

    /// 비정상 데이터(끝이 수년 뒤 등)가 캘린더 전체를 칠하지 않게 기간 펼침 상한을 둔다.
    static let rangeSpanCapDays = 93

    /// 두 축으로 집계 — ① captured(capturedAt) ② due(todo 마감일·schedule 일정 날짜, `CalendarDueDate`).
    /// captured 는 capturedAt desc 입력이라 각 그룹 첫 항목이 그날 최신(대표 썸네일).
    /// 기간 schedule 은 걸치는 모든 날에 펼치고, 겹치는 기간들은 하나의 연속 막대로 합쳐진다.
    static func group(captured: [MochiItem], due: [MochiItem], calendar: Calendar) -> [CalendarDaySummary] {
        var capturedByDay: [Date: [MochiItem]] = [:]
        for item in captured {
            let day = calendar.startOfDay(for: item.source.capturedAt)
            capturedByDay[day, default: []].append(item)
        }
        var pointDueByDay: [Date: [Intent]] = [:]
        var rangeDays: Set<Date> = []
        for item in due {
            for entry in CalendarDueDate.dueDates(of: item) {
                let startDay = calendar.startOfDay(for: entry.start)
                guard entry.intent == .schedule, let end = entry.end else {
                    pointDueByDay[startDay, default: []].append(entry.intent)
                    continue
                }
                let endDay = calendar.startOfDay(for: end)
                var day = startDay
                var span = 0
                while day <= endDay, span < Self.rangeSpanCapDays {
                    rangeDays.insert(day)
                    guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                    day = next
                    span += 1
                }
            }
        }
        let allDays = Set(capturedByDay.keys).union(pointDueByDay.keys).union(rangeDays)
        return allDays.sorted().map { day in
            let group = capturedByDay[day] ?? []
            let dueIntents = pointDueByDay[day] ?? []
            let inRange = rangeDays.contains(day)
            let prevInRange = calendar.date(byAdding: .day, value: -1, to: day).map(rangeDays.contains) ?? false
            let nextInRange = calendar.date(byAdding: .day, value: 1, to: day).map(rangeDays.contains) ?? false
            return CalendarDaySummary(
                date: day,
                count: group.count,
                thumbnailRelativePath: group.lazy.compactMap { $0.source.imageRefs.first?.displayRelativePath }.first,
                dueCount: dueIntents.count + (inRange ? 1 : 0),
                hasScheduleDue: dueIntents.contains(.schedule),
                hasTodoDue: dueIntents.contains(.todo),
                hasRangeSchedule: inRange,
                rangeConnectsLeft: inRange && prevInRange,
                rangeConnectsRight: inRange && nextInRange
            )
        }
    }
}

/// 캘린더 하단 "할 일" 정렬 — todo instance 단위로 펼쳐 미완료(마감임박순)를 위에, 완료(archived)를 맨 밑에.
/// 사용자가 잘못 누른 완료도 맨 밑에 남아 다시 체크 해제(역전이)할 수 있다.
enum CalendarTodoSorter {
    /// todo instance 단위로 펼쳐(한 아이템 여러 todo → 각 행) 미완료(마감임박순)를 위에, 완료(archived)를 맨 밑(최근순)에.
    static func rows(_ todos: [MochiItem]) -> [TodoRowItem] {
        let rows = todos.flatMap { item in
            item.instances
                .filter { $0.intentType == .todo }
                .map { TodoRowItem(item: item, instance: $0) }
        }
        return rows.sorted { lhs, rhs in
            if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }  // 미완료가 항상 위
            if !lhs.isCompleted {                                              // 둘 다 미완료 → 마감 임박순(미상은 뒤)
                switch (lhs.deadline, rhs.deadline) {
                case let (l?, r?): return l != r ? l < r : lhs.item.source.capturedAt > rhs.item.source.capturedAt
                case (_?, nil):    return true
                case (nil, _?):    return false
                case (nil, nil):   return lhs.item.source.capturedAt > rhs.item.source.capturedAt
                }
            }
            // 둘 다 완료 → 최근 완료 먼저(동률은 instance id 로 안정 정렬해 리로드 flicker 방지).
            return lhs.item.updatedAt != rhs.item.updatedAt
                ? lhs.item.updatedAt > rhs.item.updatedAt
                : lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// 표시용 dedup — 같은 (제목, 라벨, 마감일, 완료여부) 행은 하나로 합친다(같은 화면 중복 캡처).
    /// 숨겨진 쌍둥이는 대표 행 id 로 매핑해 돌려준다 — 완료 토글이 함께 전이돼야
    /// 하나만 완료한 뒤 숨었던 쌍둥이가 미완료로 되살아나지 않는다.
    static func dedupForDisplay(_ rows: [TodoRowItem]) -> (display: [TodoRowItem], duplicates: [UUID: [TodoRowItem]]) {
        var ownerByKey: [String: UUID] = [:]
        var display: [TodoRowItem] = []
        var duplicates: [UUID: [TodoRowItem]] = [:]
        for row in rows {
            let key = dedupKey(row)
            if let ownerID = ownerByKey[key] {
                duplicates[ownerID, default: []].append(row)
            } else {
                ownerByKey[key] = row.id
                display.append(row)
            }
        }
        return (display, duplicates)
    }

    private static func dedupKey(_ row: TodoRowItem) -> String {
        let day = row.deadline.map { Calendar.mochiSeoul.startOfDay(for: $0).timeIntervalSince1970 }
        return [
            normalizedDedupComponent(row.displayTitle),
            normalizedDedupComponent(row.instance.label ?? ""),
            day.map { String($0) } ?? "-",
            String(row.isCompleted),
        ].joined(separator: "|")
    }
}

/// dedup 키용 문자열 정규화 — 공백 트림 + 소문자(같은 화면 재캡처의 사소한 흔들림 흡수).
/// 캘린더 탭과 "이번 주 돌아보기"가 같은 정책을 쓴다.
func normalizedDedupComponent(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

/// 캘린더 하단 "다가오는 일정" 정렬 — 아직 안 끝난 일정만, 시작 빠른순.
/// 일정은 시각 고정·완료 개념 없음이라 todo(긴급도축)와 다른 시간축으로 떠오른다.
/// 기간 일정은 시작이 지났어도 끝(`endDate`)이 오늘 이후면 "진행 중"으로 포함된다.
enum UpcomingScheduleSorter {
    static func sort(_ schedules: [MochiItem]) -> [MochiItem] {
        let calendar = Calendar.mochiSeoul
        let todayStart = calendar.startOfDay(for: Date())
        var seen = Set<String>()
        return schedules
            .compactMap { item -> (item: MochiItem, start: Date)? in
                guard let span = scheduleSpan(of: item, notEndedBefore: todayStart) else { return nil }
                return (item, span.start)
            }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.item.id.uuidString < $1.item.id.uuidString }
            // 같은 화면 중복 캡처(같은 제목·같은 날) 표시 dedup — 일정은 완료 개념이 없어 표시만 합치면 충분.
            .filter { pair in
                let day = calendar.startOfDay(for: pair.start).timeIntervalSince1970
                return seen.insert("\(normalizedDedupComponent(pair.item.displayTitle))|\(day)").inserted
            }
            .map(\.item)
    }

    /// 일정 구간 — active schedule instance 중 끝(점이면 시작)이 `notEndedBefore` 이상인 가장 이른 것.
    static func scheduleSpan(of item: MochiItem, notEndedBefore: Date) -> (start: Date, end: Date?)? {
        item.instances
            .filter { $0.intentType == .schedule && $0.lifecycle == .active }
            .compactMap { inst -> (start: Date, end: Date?)? in
                guard let start = CalendarDueDate.parse(inst.payload.date) else { return nil }
                let end = CalendarDueDate.scheduleEnd(of: inst, start: start)
                guard (end ?? start) >= notEndedBefore else { return nil }
                return (start, end)
            }
            .min { $0.start < $1.start }
    }
}

/// 캘린더 마커용 마감/일정 날짜 추출 — todo 마감일(active) + schedule 일정 날짜.
/// payload 의 날짜 문자열을 KST 기준 `Date` 로 파싱한다(자연어는 nil).
enum CalendarDueDate {
    /// item 의 마감/일정 날짜들. todo=active instance 의 `deadline ?? date`, schedule=instance 의
    /// `date`(시작). 기간형 schedule 은 `endDate` 를 `end` 로 함께 돌려준다(점이면 nil).
    /// 한 캡처에 여러 instance(todo 둘, todo+schedule)면 각각 기여한다.
    static func dueDates(of item: MochiItem) -> [(start: Date, end: Date?, intent: Intent)] {
        item.instances.compactMap { inst in
            switch inst.intentType {
            case .todo:
                guard inst.lifecycle == .active,
                      let date = parse(inst.payload.deadline ?? inst.payload.date) else { return nil }
                return (date, nil, .todo)
            case .schedule:
                // active 일정만 — 끝났거나(scheduleEnded) 사용자가 치운(userManual) 일정은 캘린더에서 제외
                // (todo 의 active 가드와 대칭, DOMAIN_DESIGN schedule lifecycle 정합).
                guard inst.lifecycle == .active,
                      let start = parse(inst.payload.date) else { return nil }
                return (start, scheduleEnd(of: inst, start: start), .schedule)
            case .knowledge, .memo:
                return nil
            }
        }
    }

    /// 기간형 일정의 끝 — `payload.endDate` 파싱. 실패하거나 시작보다 앞서면(역전 데이터) nil
    /// 로 점 일정에 수렴시킨다(백엔드 search_items 의 graceful 철학과 동일).
    static func scheduleEnd(of inst: IntentInstance, start: Date) -> Date? {
        guard let end = parse(inst.payload.endDate), end > start else { return nil }
        return end
    }

    /// `day` 가 entry 의 시작~끝(달력 날짜 기준, 양 끝 포함)에 걸리는가 — 점 일정은 같은 날만.
    static func covers(
        _ entry: (start: Date, end: Date?, intent: Intent), day: Date, calendar: Calendar
    ) -> Bool {
        let target = calendar.startOfDay(for: day)
        let startDay = calendar.startOfDay(for: entry.start)
        let endDay = calendar.startOfDay(for: entry.end ?? entry.start)
        return target >= startDay && target <= endDay
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

    /// payload 날짜 문자열 → Date — `PayloadDate.parse`(CoreDomain, 단일 원천)에 위임.
    /// 채팅 proposal 확정(시스템 캘린더 등록)과 해석 규칙이 갈라지지 않게 한 곳에 둔다.
    static func parse(_ raw: String?) -> Date? {
        PayloadDate.parse(raw)
    }
}

// Calendar.mochiSeoul / DateFormatter.mochiSeoul / DueDisplay / ScheduleDateTile 은
// 기록 상세와 공유하기 위해 DesignSystem(DueDisplay.swift)으로 승격됐다 (2026-06-11).
