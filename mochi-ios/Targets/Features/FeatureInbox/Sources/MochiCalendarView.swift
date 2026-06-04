import SwiftUI
import ComposableArchitecture
import CoreDomain

/// 모찌들(캘린더) 탭 화면 — 월간 캘린더 + 날짜별 모찌 sheet + 마감 임박 할 일.
public struct MochiCalendarView: View {
    @Bindable var store: StoreOf<MochiCalendarFeature>

    public init(store: StoreOf<MochiCalendarFeature>) {
        self.store = store
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: HomeDesign.Spacing.xl) {
                monthHeader
                calendarCard
                upcomingTodosSection
            }
            .padding(.horizontal, HomeDesign.Spacing.lg)
            .padding(.vertical, HomeDesign.Spacing.lg)
        }
        .background(HomeDesign.Color.bg.ignoresSafeArea())
        .navigationTitle("모찌들")
        .navigationBarTitleDisplayMode(.inline)
        .task { store.send(.onAppear) }
        .sheet(item: dayBinding) { day in
            DaySheet(
                date: day.date,
                items: Array(store.selectedDayItems),
                onTap: { store.send(.mochiItemTapped($0)) }
            )
            .presentationDetents([.medium, .large])
        }
    }

    /// `.sheet(item:)` 바인딩 — dismiss(set nil) 시 daySelected(nil) 로 상태 정리.
    private var dayBinding: Binding<SelectedDay?> {
        Binding(
            get: { store.selectedDay },
            set: { newValue in if newValue == nil { store.send(.daySelected(nil)) } }
        )
    }

    // MARK: Month header

    private var monthHeader: some View {
        HStack {
            stepButton(systemName: "chevron.left", delta: -1)
            Spacer()
            Text(Self.monthTitle(store.monthAnchor))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textPrimary)
            Spacer()
            stepButton(systemName: "chevron.right", delta: 1)
        }
    }

    private func stepButton(systemName: String, delta: Int) -> some View {
        Button { store.send(.monthStepped(delta)) } label: {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(HomeDesign.Color.purple600)
                .frame(width: 36, height: 36)
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
                    Color.clear.frame(height: 46)
                }
            }
        }
    }

    // MARK: Upcoming todos

    private var upcomingTodosSection: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.butter400)
                Text("마감 임박 할 일")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
            }
            if store.upcomingTodos.isEmpty {
                Text("아직 챙길 할 일이 없어요. 모찌가 마감 있는 일을 발견하면 여기 모아둘게요.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, HomeDesign.Spacing.lg)
            } else {
                ForEach(store.upcomingTodos) { todo in
                    UpcomingTodoRow(item: todo) { store.send(.mochiItemTapped(todo.id)) }
                }
            }
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
        DateFormatter.mochiSeoul("yyyy년 M월").string(from: date)
    }
}

// MARK: - Day cell

private struct DayCell: View {
    let date: Date
    let summary: CalendarDaySummary?
    let isToday: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                Text("\(Calendar.mochiSeoul.component(.day, from: date))")
                    .font(.system(size: 12.5, weight: isToday ? .bold : .medium))
                    .foregroundStyle(isToday ? HomeDesign.Color.purple600 : HomeDesign.Color.textPrimary)
                if let summary {
                    Circle()
                        .fill(MochiViewIntent(summary.representativeIntent ?? .memo).dotColor)
                        .frame(width: 6, height: 6)
                    Text("\(summary.count)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                } else {
                    Spacer().frame(height: 15)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                    .fill(isToday ? HomeDesign.Color.purple50 : Color.clear)
            )
        }
        .buttonStyle(PressableStyle())
        .disabled(summary == nil)
    }
}

// MARK: - Upcoming todo row

private struct UpcomingTodoRow: View {
    let item: MochiItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: HomeDesign.Spacing.md) {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.butter400)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(HomeDesign.Color.butter50))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(deadlineLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(deadlineColor)
                }
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
    }

    private var deadline: Date? { UpcomingTodoSorter.deadline(of: item) }

    private var deadlineLabel: String {
        guard let deadline else { return "마감일 미정" }
        let calendar = Calendar.mochiSeoul
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: deadline)
        ).day ?? 0
        if days < 0 { return "\(-days)일 지남" }
        if days == 0 { return "오늘 마감" }
        if days == 1 { return "내일 마감" }
        return "D-\(days)"
    }

    private var deadlineColor: Color {
        guard let deadline else { return HomeDesign.Color.textMuted }
        return deadline < Date() ? HomeDesign.Color.blush400 : HomeDesign.Color.butter400
    }
}

// MARK: - Day sheet

private struct DaySheet: View {
    let date: Date
    let items: [MochiItem]
    let onTap: (MochiItem.ID) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: HomeDesign.Spacing.md) {
                    if items.isEmpty {
                        Text("이 날 저장한 모찌가 없어요.")
                            .font(.system(size: 13))
                            .foregroundStyle(HomeDesign.Color.textMuted)
                            .padding(.top, 40)
                    } else {
                        ForEach(items) { item in
                            DayMochiRow(item: item) { onTap(item.id) }
                        }
                    }
                }
                .padding(HomeDesign.Spacing.lg)
            }
            .background(HomeDesign.Color.bg.ignoresSafeArea())
            .navigationTitle(Self.title(date))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private static func title(_ date: Date) -> String {
        DateFormatter.mochiSeoul("M월 d일 (E)").string(from: date)
    }
}

// MARK: - Day mochi row

private struct DayMochiRow: View {
    let item: MochiItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: HomeDesign.Spacing.md) {
                thumbnail
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
    }

    @ViewBuilder
    private var thumbnail: some View {
        if item.viewKind == .screenshot {
            LocalThumbnail(
                relativePath: item.source.imageRefs.first?.relativePath,
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
