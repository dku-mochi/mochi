import SwiftUI
import ComposableArchitecture
import CoreDomain
import DesignSystem

/// 캘린더 탭 화면 — 고정 월 헤더 + 월간 캘린더 + 날짜별 모찌 sheet + 다가오는 일정·마감 임박 할 일.
///
/// 시각 언어: 날짜 셀의 점 3종(일정 sky · 할 일 butter · 저장 purple)이 카드 하단 범례와 1:1 로 대응한다.
/// 월 헤더는 `safeAreaInset` 으로 고정해 스크롤 콘텐츠가 상태바(시계·배터리)와 겹치지 않는다.
public struct MochiCalendarView: View {
    @Bindable var store: StoreOf<MochiCalendarFeature>

    /// 첫 진입 시 섹션들이 순서대로 떠오르는 entrance 연출 트리거 (한 번만).
    @State private var hasEntered = false
    /// "완료한 일" 접이식 섹션 펼침 여부 (UI 전용).
    @State private var showsCompleted = false

    public init(store: StoreOf<MochiCalendarFeature>) {
        self.store = store
    }

    public var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HomeDesign.Spacing.xl) {
                calendarCard
                    .riseIn(hasEntered, index: 0)
                upcomingSchedulesSection
                    .riseIn(hasEntered, index: 1)
                upcomingTodosSection
                    .riseIn(hasEntered, index: 2)
                if !completedTodos.isEmpty {
                    completedSection
                        .riseIn(hasEntered, index: 3)
                }
            }
            .padding(.horizontal, HomeDesign.Spacing.lg)
            .padding(.top, HomeDesign.Spacing.sm)
            .padding(.bottom, HomeDesign.Spacing.xxl)
            // 완료 토글 시 행이 미완료↔완료 섹션 사이를 부드럽게 이동.
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.upcomingTodos)
        }
        .safeAreaInset(edge: .top, spacing: 0) { pinnedHeader }
        .background(HomeDesign.Color.bg.ignoresSafeArea())
        .navigationTitle("캘린더")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            store.send(.onAppear)
            hasEntered = true
        }
        .sheet(item: dayBinding) { day in
            DaySheet(
                date: day.date,
                items: Array(store.selectedDayItems),
                onTap: { id, hero in store.send(.mochiItemTapped(id, hero: hero)) },
                onAddSchedule: { store.send(.addScheduleTapped) }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
            // 일정 추가 폼 — DaySheet 위에 sheet-over-sheet 로 띄운다(여기서 store 접근 가능).
            .sheet(item: addScheduleBinding) { draft in
                AddScheduleForm(store: store, date: draft.date)
                    .presentationDetents([.height(360)])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
            }
        }
    }

    /// 일정 추가 폼 sheet 바인딩 — dismiss(set nil) 시 dismissDraft.
    private var addScheduleBinding: Binding<MochiCalendarFeature.ScheduleDraft?> {
        Binding(
            get: { store.addScheduleDraft },
            set: { if $0 == nil { store.send(.dismissDraft) } }
        )
    }

    /// `.sheet(item:)` 바인딩 — dismiss(set nil) 시 daySelected(nil) 로 상태 정리.
    private var dayBinding: Binding<SelectedDay?> {
        Binding(
            get: { store.selectedDay },
            set: { newValue in if newValue == nil { store.send(.daySelected(nil)) } }
        )
    }

    private var incompleteTodos: [TodoRowItem] { store.upcomingTodos.filter { !$0.isCompleted } }
    private var completedTodos: [TodoRowItem] { store.upcomingTodos.filter(\.isCompleted) }

    // MARK: Pinned month header

    /// 고정 헤더 — 연/월 타이틀 + (다른 달일 때) "오늘" 점프 + 월 이동.
    /// 배경이 상태바 영역까지 차올라 스크롤된 콘텐츠가 시계·배터리와 충돌하지 않는다.
    private var pinnedHeader: some View {
        HStack(spacing: HomeDesign.Spacing.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.yearTitle(store.monthAnchor))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                Text(Self.monthTitle(store.monthAnchor))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.monthAnchor)
            }
            if !isCurrentMonth {
                Button { store.send(.todayTapped) } label: {
                    Text("오늘")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(HomeDesign.Color.purple600)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(HomeDesign.Color.purple50))
                        .overlay(Capsule().stroke(HomeDesign.Color.purple200, lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            Spacer()
            stepButton(systemName: "chevron.left", delta: -1)
            stepButton(systemName: "chevron.right", delta: 1)
        }
        .padding(.horizontal, HomeDesign.Spacing.lg)
        .padding(.top, HomeDesign.Spacing.sm)
        .padding(.bottom, HomeDesign.Spacing.sm)
        .background(HomeDesign.Color.bg.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            // 헤더 바로 아래 페이드 — 스크롤 콘텐츠가 헤더 밑을 지날 때 딱 잘려 보이지 않게.
            LinearGradient(
                colors: [HomeDesign.Color.bg, HomeDesign.Color.bg.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 14)
            .offset(y: 14)
            .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isCurrentMonth)
    }

    private var isCurrentMonth: Bool {
        Calendar.mochiSeoul.isDate(store.monthAnchor, equalTo: Date(), toGranularity: .month)
    }

    private func stepButton(systemName: String, delta: Int) -> some View {
        Button { store.send(.monthStepped(delta)) } label: {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HomeDesign.Color.purple600)
                .frame(width: 34, height: 34)
                .background(Circle().fill(HomeDesign.Color.surface))
                .overlay(Circle().stroke(HomeDesign.Color.border, lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: Calendar card

    private var calendarCard: some View {
        VStack(spacing: HomeDesign.Spacing.md) {
            weekdayHeader
            grid
            legend
        }
        .padding(HomeDesign.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .fill(HomeDesign.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .stroke(HomeDesign.Color.border, lineWidth: 1)
        )
        .cardShadow()
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.weekdaySymbols.enumerated()), id: \.offset) { index, symbol in
                Text(symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Self.weekdayColor(index))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
            ForEach(gridCells) { cell in
                if let date = cell.date {
                    DayCell(
                        date: date,
                        summary: cell.summary,
                        isToday: Calendar.mochiSeoul.isDateInToday(date)
                    ) { store.send(.daySelected(date)) }
                } else {
                    Color.clear.frame(height: 44)
                }
            }
        }
    }

    /// 점 3종의 의미를 화면 안에서 해석 가능하게 — 셀 마커와 1:1 대응하는 범례.
    private var legend: some View {
        HStack(spacing: HomeDesign.Spacing.lg) {
            legendItem(color: HomeDesign.Color.sky400, label: "일정")
            legendItem(color: HomeDesign.Color.butter400, label: "할 일")
            legendItem(color: HomeDesign.Color.purple400, label: "저장")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(HomeDesign.Color.textMuted)
        }
    }

    // MARK: Upcoming schedules

    private var upcomingSchedulesSection: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            sectionHeader(
                icon: "calendar",
                tint: HomeDesign.Color.sky400,
                chipBackground: HomeDesign.Color.sky100,
                title: "다가오는 일정",
                count: store.upcomingSchedules.count
            )
            if store.upcomingSchedules.isEmpty {
                Text("예정된 일정이 없어요. 모찌가 날짜 있는 일정을 발견하면 여기 모아둘게요.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, HomeDesign.Spacing.lg)
            } else {
                CollapsibleRows(items: Array(store.upcomingSchedules), spacing: 0, showsDividers: true) { schedule in
                    UpcomingScheduleRow(item: schedule) {
                        store.send(.mochiItemTapped(schedule.id, hero: nil))
                    }
                }
            }
        }
    }

    // MARK: Upcoming todos

    private var upcomingTodosSection: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            sectionHeader(
                icon: "checklist",
                tint: HomeDesign.Color.butter400,
                chipBackground: HomeDesign.Color.butter100,
                title: "마감 임박한 할 일",
                count: incompleteTodos.count
            )
            if incompleteTodos.isEmpty {
                Text("아직 챙길 할 일이 없어요. 모찌가 마감 있는 일을 발견하면 여기 모아둘게요.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, HomeDesign.Spacing.lg)
            } else {
                CollapsibleRows(items: incompleteTodos, spacing: 0, showsDividers: true) { row in
                    UpcomingTodoRow(
                        row: row,
                        onToggle: { store.send(.todoCompletionToggled(row)) },
                        onTap: { store.send(.mochiItemTapped(row.item.id, hero: nil)) }
                    )
                }
            }
        }
    }

    /// 완료한 일 — "마감 임박"과 분리된 접이식 섹션. 잘못 누른 완료를 되돌리는 입구.
    private var completedSection: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showsCompleted.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                    Text("완료한 일")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                    Text("\(completedTodos.count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(HomeDesign.Color.ink100))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.textFaint)
                        .rotationEffect(.degrees(showsCompleted ? -180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())

            if showsCompleted {
                CollapsibleRows(items: completedTodos, spacing: 0, showsDividers: true) { row in
                    UpcomingTodoRow(
                        row: row,
                        onToggle: { store.send(.todoCompletionToggled(row)) },
                        onTap: { store.send(.mochiItemTapped(row.item.id, hero: nil)) }
                    )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func sectionHeader(
        icon: String, tint: Color, chipBackground: Color, title: String, count: Int
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(HomeDesign.Color.textPrimary)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(chipBackground))
            }
            Spacer()
        }
    }

    // MARK: Grid model

    private struct GridCell: Identifiable {
        let id: Int
        let date: Date?
        let summary: CalendarDaySummary?
    }

    private var gridCells: [GridCell] {
        let calendar = Calendar.mochiSeoul
        guard let monthInterval = calendar.dateInterval(of: .month, for: store.monthAnchor) else { return [] }
        let firstDay = calendar.startOfDay(for: monthInterval.start)
        let daysInMonth = calendar.range(of: .day, in: .month, for: firstDay)?.count ?? 30
        let leadingBlanks = calendar.component(.weekday, from: firstDay) - 1  // 1=일 → 0 offset
        let summaryByDay = Dictionary(uniqueKeysWithValues: store.days.map { ($0.date, $0) })

        var cells: [GridCell] = []
        var index = 0
        for _ in 0..<max(0, leadingBlanks) {
            cells.append(GridCell(id: index, date: nil, summary: nil))
            index += 1
        }
        for offset in 0..<daysInMonth {
            if let date = calendar.date(byAdding: .day, value: offset, to: firstDay) {
                cells.append(GridCell(id: index, date: date, summary: summaryByDay[calendar.startOfDay(for: date)]))
                index += 1
            }
        }
        return cells
    }

    // MARK: Static helpers

    private static let weekdaySymbols = ["일", "월", "화", "수", "목", "금", "토"]

    private static func weekdayColor(_ index: Int) -> Color {
        if index == 0 { return HomeDesign.Color.blush400 }   // 일
        if index == 6 { return HomeDesign.Color.sky400 }     // 토
        return HomeDesign.Color.textMuted
    }

    private static func monthTitle(_ date: Date) -> String {
        DateFormatter.mochiSeoul("M월").string(from: date)
    }

    private static func yearTitle(_ date: Date) -> String {
        DateFormatter.mochiSeoul("yyyy년").string(from: date)
    }
}

// MARK: - Day cell

/// 날짜 한 칸 — 숫자 + 점 3종(하루 일정 sky · 할 일 butter · 저장 purple) + 기간 일정 막대(sky).
/// 막대는 시작~끝에 걸친 칸을 가로지르며, 이어지는 쪽은 라운드 없이 옆 칸과 연결돼 보인다.
/// 오늘은 보라 원 채움(흰 숫자), 지난 날짜는 숫자를 옅게 — 점·막대는 그대로 둬 기록 신호를 잃지 않는다.
private struct DayCell: View {
    let date: Date
    let summary: CalendarDaySummary?
    let isToday: Bool
    let onTap: () -> Void

    private var isPast: Bool {
        date < Calendar.mochiSeoul.startOfDay(for: Date())
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                Text("\(Calendar.mochiSeoul.component(.day, from: date))")
                    .font(.system(size: 13, weight: isToday ? .bold : .medium, design: .rounded))
                    .foregroundStyle(numberColor)
                    .frame(width: 27, height: 27)
                    .background {
                        if isToday {
                            Circle()
                                .fill(HomeDesign.Color.purple500)
                                .shadow(color: HomeDesign.Color.purpleGlow.opacity(0.55), radius: 5, x: 0, y: 2)
                        }
                    }
                rangeBarLane
                    .frame(maxWidth: .infinity)
                    .frame(height: 3)
                HStack(spacing: 3) {
                    if summary?.hasScheduleDue == true { dot(HomeDesign.Color.sky400) }
                    if summary?.hasTodoDue == true { dot(HomeDesign.Color.butter400) }
                    if summary?.hasCaptured == true { dot(HomeDesign.Color.purple400) }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        // 빈 날(summary == nil)도 탭 가능해야 한다 — DaySheet 가 빈 상태로 열려 "+ 일정 추가"로
        // 일정을 만들 수 있다(2026-06-15 일정 추가 도입 후 빈 날 비활성은 추가 진입을 막던 버그).
    }

    /// 기간 일정 막대 — 이어지는 쪽은 그리드 간격(4pt)을 음수 패딩으로 메워 연속된 막대로 보인다.
    @ViewBuilder
    private var rangeBarLane: some View {
        if let summary, summary.hasRangeSchedule {
            let leftRadius: CGFloat = summary.rangeConnectsLeft ? 0 : 1.5
            let rightRadius: CGFloat = summary.rangeConnectsRight ? 0 : 1.5
            UnevenRoundedRectangle(
                topLeadingRadius: leftRadius,
                bottomLeadingRadius: leftRadius,
                bottomTrailingRadius: rightRadius,
                topTrailingRadius: rightRadius
            )
            .fill(HomeDesign.Color.sky400)
            .padding(.leading, summary.rangeConnectsLeft ? -2 : 0)
            .padding(.trailing, summary.rangeConnectsRight ? -2 : 0)
        } else {
            Color.clear
        }
    }

    private var numberColor: Color {
        if isToday { return .white }
        if isPast { return HomeDesign.Color.textMuted }
        return HomeDesign.Color.textPrimary
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 5, height: 5)
    }
}

// MARK: - Upcoming todo row

private struct UpcomingTodoRow: View {
    let row: TodoRowItem
    let onToggle: () -> Void
    let onTap: () -> Void

    private var item: MochiItem { row.item }
    private var isCompleted: Bool { row.isCompleted }

    var body: some View {
        HStack(spacing: HomeDesign.Spacing.md) {
            // 완료 체크박스 — 본문과 분리된 탭 타겟. 미완료↔완료를 즉시 토글(잘못 눌러도 다시 해제 가능).
            Button(action: onToggle) {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(isCompleted ? HomeDesign.Color.butter400 : HomeDesign.Color.textFaint)
                    // 아이콘은 22pt 유지, 탭 타겟·좌측 앵커는 44pt(일정 행 날짜 타일과 폭·높이 통일).
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())

            // 본문 — 탭하면 상세로.
            Button(action: onTap) {
                HStack(spacing: HomeDesign.Spacing.md) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.displayTitle)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(isCompleted ? HomeDesign.Color.textMuted : HomeDesign.Color.textPrimary)
                            .strikethrough(isCompleted, color: HomeDesign.Color.textFaint)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isCompleted ? HomeDesign.Color.textFaint : deadlineColor)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.textFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.vertical, HomeDesign.Spacing.md)
        .opacity(isCompleted ? 0.65 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isCompleted)
    }

    private var deadline: Date? { row.deadline }

    /// 본문이 payload.title 일 땐 label(축약 중복)을 빼고 마감만, 캡처 제목 폴백일 땐 label 유지.
    private var subtitle: String {
        if !(row.instance.payload.title ?? "").isEmpty { return deadlineLabel }
        return row.instance.label.map { "\($0) · \(deadlineLabel)" } ?? deadlineLabel
    }

    private var deadlineLabel: String {
        if isCompleted { return "완료함" }
        guard let deadline else { return "마감일 미정" }
        return DueDisplay.deadlineLabel(deadline)
    }

    private var deadlineColor: Color {
        DueDisplay.deadlineColor(deadline)
    }
}

// MARK: - Upcoming schedule row

/// 일정 행 — 왼쪽 날짜 타일(월/일)로 스캔 가능하게, 라벨은 상대 표현(오늘·내일·요일·D-n)과 시각.
/// 기간 일정은 "시작 ~ 끝" 으로, 진행 중(시작 지남·끝 안 옴)이어도 떠 있는다.
private struct UpcomingScheduleRow: View {
    let item: MochiItem
    let onTap: () -> Void

    private var scheduleSpan: (start: Date, end: Date?)? {
        UpcomingScheduleSorter.scheduleSpan(
            of: item, notEndedBefore: Calendar.mochiSeoul.startOfDay(for: Date())
        )
    }

    private var scheduleDate: Date? { scheduleSpan?.start }

    /// 카드 본문 — 일정 자신의 이름(`payload.title`)이 정본, 없으면 캡처 제목 폴백.
    private var title: String {
        let inst = item.instances.first { $0.intentType == .schedule && $0.lifecycle == .active }
        if let title = inst?.payload.title, !title.isEmpty { return title }
        return item.displayTitle
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: HomeDesign.Spacing.md) {
                ScheduleDateTile(date: scheduleDate)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(scheduleLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(HomeDesign.Color.sky400)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.textFaint)
            }
            .padding(.vertical, HomeDesign.Spacing.md)
        }
        .buttonStyle(PressableStyle())
    }

    private var scheduleLabel: String {
        guard let span = scheduleSpan else { return "날짜 미정" }
        guard let end = span.end else { return DueDisplay.scheduleLabel(span.start) }
        return DueDisplay.scheduleRangeLabel(span.start, end)
    }
}

// MARK: - Collapsible rows

/// 기본 `limit`개만 보이고 넘치면 "N개 더 보기"로 인라인 펼친다(한번 펼치면 접지 않음 — 스크롤로 충분).
/// 캘린더 하단·DaySheet 의 일정·할 일이 많이 쌓여도 한눈에 들어오게 한다.
private struct CollapsibleRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    var limit: Int = 3
    var spacing: CGFloat = HomeDesign.Spacing.md
    /// 행 *사이*에만 1px 디바이더(마지막 행·"더 보기" 직전 제외). 박스 없는 플랫 리스트용.
    var showsDividers: Bool = false
    @ViewBuilder var row: (Item) -> Row
    @State private var expanded = false

    var body: some View {
        let visible = expanded ? items : Array(items.prefix(limit))
        LazyVStack(spacing: spacing) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                row(item)
                if showsDividers && index < visible.count - 1 {
                    Rectangle()
                        .fill(HomeDesign.Color.ink300.opacity(0.5))
                        .frame(height: 1)
                }
            }
            if items.count > limit {
                expandToggle
            }
        }
    }

    @ViewBuilder
    private var expandToggle: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Text(expanded ? "접기" : "\(items.count - limit)개 더 보기")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(HomeDesign.Color.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, HomeDesign.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Day sheet

/// 날짜 탭 모달 — 날짜 헤더 아래 「일정·마감」 / 「저장한 기억」 두 결로 나눠 보여준다.
/// 셀 탭은 hero frame 을 실어 보내, sheet 위에서 셀이 상세로 자라는 zoom 전환의 시작점이 된다.
private struct DaySheet: View {
    let date: Date
    let items: [MochiItem]
    let onTap: (MochiItem.ID, HeroSourceFrames?) -> Void
    let onAddSchedule: () -> Void

    /// 그날 마감(todo)·일정(schedule)인 항목과 그 외(그날 저장한 기억) 분리.
    /// 기간 일정은 시작~끝에 걸친 모든 날의 「일정·마감」에 포함된다.
    private var partitioned: (due: [MochiItem], captured: [MochiItem]) {
        var due: [MochiItem] = []
        var captured: [MochiItem] = []
        for item in items {
            let isDueOnDay = CalendarDueDate.dueDates(of: item).contains {
                CalendarDueDate.covers($0, day: date, calendar: Calendar.mochiSeoul)
            }
            if isDueOnDay { due.append(item) } else { captured.append(item) }
        }
        return (due, captured)
    }

    var body: some View {
        let groups = partitioned
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                header(dueCount: groups.due.count, capturedCount: groups.captured.count)
                    .padding(.bottom, HomeDesign.Spacing.xs)

                if items.isEmpty {
                    emptyState
                } else {
                    if !groups.due.isEmpty {
                        sectionLabel("이날 일정 · 마감", tint: HomeDesign.Color.sky400)
                        CollapsibleRows(items: groups.due) { item in
                            DayMochiRow(item: item, onTap: onTap)
                        }
                    }
                    if !groups.captured.isEmpty {
                        sectionLabel("이날 저장한 기억", tint: HomeDesign.Color.purple400)
                            .padding(.top, groups.due.isEmpty ? 0 : HomeDesign.Spacing.sm)
                        CollapsibleRows(items: groups.captured) { item in
                            DayMochiRow(item: item, onTap: onTap)
                        }
                    }
                }
            }
            .padding(.horizontal, HomeDesign.Spacing.lg)
            .padding(.top, HomeDesign.Spacing.xl)
            .padding(.bottom, HomeDesign.Spacing.xxl)
        }
        .background(HomeDesign.Color.bg.ignoresSafeArea())
    }

    private func header(dueCount: Int, capturedCount: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(DateFormatter.mochiSeoul("M월 d일 EEEE").string(from: date))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                if dueCount + capturedCount > 0 {
                    Text(countLabel(dueCount: dueCount, capturedCount: capturedCount))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                }
            }
            Spacer(minLength: HomeDesign.Spacing.md)
            addScheduleButton
        }
    }

    /// 이 날짜로 바로 일정 추가 — 칩 문법(퍼플 캡슐)으로 DaySheet 의 회수형 톤과 어울리게.
    private var addScheduleButton: some View {
        Button(action: onAddSchedule) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                Text("일정 추가")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
            }
            .foregroundStyle(HomeDesign.Color.purple600)
            .padding(.horizontal, HomeDesign.Spacing.md)
            .frame(height: 34)
            .background(Capsule().fill(HomeDesign.Color.purple100.opacity(0.7)))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("이 날짜에 일정 추가")
    }

    private func countLabel(dueCount: Int, capturedCount: Int) -> String {
        var parts: [String] = []
        if dueCount > 0 { parts.append("일정·마감 \(dueCount)개") }
        if capturedCount > 0 { parts.append("저장한 기억 \(capturedCount)개") }
        return parts.joined(separator: " · ")
    }

    /// 점 + 라벨 — 캘린더 카드 범례와 같은 시각 언어.
    private func sectionLabel(_ title: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(title)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(HomeDesign.Color.textMuted)
        }
        .padding(.leading, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 26))
                .foregroundStyle(HomeDesign.Color.textFaint)
            Text("이 날 저장한 모찌가 없어요")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(HomeDesign.Color.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }
}

// MARK: - Day mochi row

/// 모달의 항목 행 — 탭 시점의 글로벌 frame(행·썸네일)을 hero 로 넘겨 셀→상세 zoom 의 출발점을 만든다.
private struct DayMochiRow: View {
    let item: MochiItem
    let onTap: (MochiItem.ID, HeroSourceFrames?) -> Void

    @State private var cardFrame: CGRect = .zero
    /// 썸네일 영역의 글로벌 frame — 스크린샷 hero 가 상세 이미지로 자라는 시작점.
    @State private var mediaFrame: CGRect = .zero

    var body: some View {
        Button {
            onTap(item.id, HeroSourceFrames(
                card: cardFrame,
                cardImage: (item.viewKind == .screenshot && mediaFrame != .zero) ? mediaFrame : nil,
                imageRelativePath: item.source.imageRefs.first?.relativePath
            ))
        } label: {
            HStack(spacing: HomeDesign.Spacing.md) {
                thumbnail
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { mediaFrame = geo.frame(in: .global) }
                                .onChange(of: geo.frame(in: .global)) { _, newFrame in
                                    mediaFrame = newFrame
                                }
                        }
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        if let intent = item.representativeIntent {
                            IntentChip(intent: MochiViewIntent(intent))
                        }
                        Text(item.source.channel.shortLabel)
                            .font(.system(size: 10.5))
                            .foregroundStyle(HomeDesign.Color.textMuted)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.textFaint)
            }
            .padding(HomeDesign.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .fill(HomeDesign.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .stroke(HomeDesign.Color.border, lineWidth: 1)
            )
        }
        .buttonStyle(PressableStyle())
        // 행의 글로벌 frame 추적 — 탭 시점에 hero 출발 frame 으로 넘긴다.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { cardFrame = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, newFrame in
                        cardFrame = newFrame
                    }
            }
        )
    }

    @ViewBuilder
    private var thumbnail: some View {
        if item.viewKind == .screenshot {
            LocalThumbnail(
                relativePath: item.source.imageRefs.first?.relativePath,
                objectKey: item.source.imageRefs.first?.objectKey,
                sha256: item.source.imageRefs.first?.sha256,
                mimeType: item.source.imageRefs.first?.mimeType,
                targetSize: CGSize(width: 48, height: 48)
            ) {
                placeholderIcon
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous))
        } else {
            placeholderIcon
        }
    }

    private var placeholderIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                .fill(HomeDesign.Color.cream100)
            Image(systemName: item.viewKind.icon)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(item.viewKind.tint)
        }
        .frame(width: 48, height: 48)
    }
}

// MARK: - 일정 추가 폼

/// 캘린더 날짜에서 일정을 직접 만드는 폼 — 제목 + (선택)시간, 날짜는 선택일 고정.
/// 저장 시 confirmedInstances ingest(채팅 일정 확정과 같은 경로) + 시스템 캘린더 등록.
/// 디자인: HomeDesign 토큰·둥근 surface 카드·퍼플 액센트로 캘린더 톤과 일치.
private struct AddScheduleForm: View {
    let store: StoreOf<MochiCalendarFeature>
    let date: Date

    @FocusState private var titleFocused: Bool

    private var draft: MochiCalendarFeature.ScheduleDraft? { store.addScheduleDraft }

    private var title: Binding<String> {
        Binding(get: { draft?.title ?? "" }, set: { store.send(.draftTitleChanged($0)) })
    }
    private var hasTime: Binding<Bool> {
        Binding(
            get: { draft?.time != nil },
            set: { store.send(.draftTimeChanged($0 ? Self.defaultTime(on: date) : nil)) }
        )
    }
    private var time: Binding<Date> {
        Binding(
            get: { draft?.time ?? Self.defaultTime(on: date) },
            set: { store.send(.draftTimeChanged($0)) }
        )
    }
    private var canSave: Bool {
        let empty = draft?.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        return !empty && !(draft?.isSaving ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.lg) {
            HStack {
                Text("일정 추가")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                Spacer()
                Text(DateFormatter.mochiSeoul("M월 d일 EEE").string(from: date))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.purple600)
                    .padding(.horizontal, HomeDesign.Spacing.sm)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(HomeDesign.Color.purple100.opacity(0.7)))
            }

            TextField("무슨 일정인가요?", text: title)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .focused($titleFocused)
                .submitLabel(.done)
                .onSubmit { if canSave { titleFocused = false; store.send(.saveDraftTapped) } }
                .padding(HomeDesign.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                        .fill(HomeDesign.Color.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                        .stroke(HomeDesign.Color.border, lineWidth: 1)
                )

            HStack(spacing: HomeDesign.Spacing.sm) {
                Image(systemName: "clock")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.purple500)
                Text(hasTime.wrappedValue ? "시간" : "종일")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                Spacer()
                if hasTime.wrappedValue {
                    DatePicker("", selection: time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                Toggle("", isOn: hasTime)
                    .labelsHidden()
                    .tint(HomeDesign.Color.purple500)
            }
            .padding(.horizontal, HomeDesign.Spacing.md)
            .padding(.vertical, HomeDesign.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .fill(HomeDesign.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .stroke(HomeDesign.Color.border, lineWidth: 1)
            )

            if let error = draft?.error {
                Text(error)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(HomeDesign.Color.blush400)
            }

            Spacer(minLength: 0)

            Button {
                titleFocused = false
                store.send(.saveDraftTapped)
            } label: {
                Group {
                    if draft?.isSaving == true {
                        ProgressView().tint(.white)
                    } else {
                        Text("저장").font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    Capsule().fill(
                        LinearGradient(
                            colors: [HomeDesign.Color.purple400, HomeDesign.Color.purple600],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
                .opacity(canSave ? 1 : 0.5)
            }
            .buttonStyle(PressableStyle())
            .disabled(!canSave)
        }
        .padding(HomeDesign.Spacing.xl)
        .background(HomeDesign.Color.bg.ignoresSafeArea())
        .onAppear { titleFocused = true }
    }

    static func defaultTime(on date: Date) -> Date {
        Calendar.mochiSeoul.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
    }
}
