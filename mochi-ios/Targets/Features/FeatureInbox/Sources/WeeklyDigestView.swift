import SwiftUI
import ComposableArchitecture
import CoreDomain
import DesignSystem

/// "이번 주 돌아보기" — 모찌가 한 주를 추려 **먼저 말을 거는** 회고 화면.
///
/// 미션("필요한 기억은 쉽게 떠오른다")의 진열장: 사용자가 뒤지는 게 아니라
/// 모찌가 건넨다. 4-Intent 라벨 비노출. 위→아래:
///  - ① 히어로: 주 범위 + 쌓인 기억 수 + 모찌의 한마디(말풍선)
///  - ② 아직 안 끝났어요: 미해결 todo(1-tap 완료) + 다가올 일정
///  - ③ 이런 걸 모았어요: 카테고리 카드 — 접힌 상태에서도 썸네일로 기억이 *보이게*
///  - ④ 푸터: 회수는 모찌에게 물어보면 된다는 마무리 한 줄
public struct WeeklyDigestView: View {

    @Bindable public var store: StoreOf<WeeklyDigestFeature>
    /// 진입 시 섹션 순차 등장 트리거 (한 번만).
    @State private var hasEntered = false

    public init(store: StoreOf<WeeklyDigestFeature>) {
        self.store = store
    }

    public var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: HomeDesign.Spacing.xl) {
                heroCard
                    .riseIn(hasEntered, index: 0)
                if !store.upcoming.isEmpty {
                    unfinishedSection
                        .riseIn(hasEntered, index: 1)
                }
                if store.groups.isEmpty {
                    if !store.isLoading {
                        emptyHarvest
                            .riseIn(hasEntered, index: 2)
                    }
                } else {
                    harvestSection
                        .riseIn(hasEntered, index: 2)
                }
                weekFooter
                    .riseIn(hasEntered, index: 3)
            }
            .padding(.horizontal, HomeDesign.Spacing.xl)
            .padding(.top, HomeDesign.Spacing.md)
            .padding(.bottom, 40)
        }
        .background(backgroundLayer.ignoresSafeArea())
        .preferredColorScheme(.light)
        .navigationTitle("이번 주 돌아보기")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            store.send(.onAppear)
            hasEntered = true
        }
    }

    /// 홈과 같은 기조 — bg 위 상단 라벤더 글로우로 화면 간 연속성을 만든다.
    private var backgroundLayer: some View {
        ZStack {
            HomeDesign.Color.bg
            LinearGradient(
                colors: [
                    HomeDesign.Color.purple200.opacity(0.30),
                    HomeDesign.Color.purple100.opacity(0.10),
                    Color.white.opacity(0.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 220)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - ① 히어로 (주 범위 + 기억 수 + 모찌의 한마디)

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.lg) {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.xs) {
                Text(weekRangeLabel)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(HomeDesign.Color.purple600)
                heroHeadline
            }

            // 한 주 요약 칩 — 숫자만으로 이번 주의 부피가 잡힌다.
            if !store.groups.isEmpty || remainingTodoCount > 0 {
                HStack(spacing: HomeDesign.Spacing.sm) {
                    if !store.groups.isEmpty {
                        statChip(icon: "square.grid.2x2.fill", label: "\(store.groups.count)가지 주제")
                    }
                    if remainingTodoCount > 0 {
                        statChip(icon: "checklist", label: "남은 할 일 \(remainingTodoCount)개")
                    }
                }
            }

            // 모찌의 한마디 — 마스코트가 직접 건네는 말풍선.
            HStack(alignment: .bottom, spacing: HomeDesign.Spacing.lg) {
                speechBubble
                Image("mochi2")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 84, height: 84)
                    .shadow(color: HomeDesign.Color.purple500.opacity(0.16), radius: 12, x: 0, y: 6)
                    .accessibilityHidden(true)
            }
        }
        .padding(HomeDesign.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white, HomeDesign.Color.purple50, HomeDesign.Color.sky100.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .stroke(HomeDesign.Color.purple100, lineWidth: 1.2)
        )
        .cardShadow()
    }

    private var heroHeadline: some View {
        Group {
            if store.allWeekItems.isEmpty {
                Text("이번 주 기억을 기다리고 있어요")
            } else {
                Text("기억 ")
                + Text("\(store.allWeekItems.count)개")
                    .foregroundStyle(HomeDesign.Color.purple600)
                + Text("가 쌓였어요")
            }
        }
        .font(.system(size: 21, weight: .heavy, design: .rounded))
        .foregroundStyle(HomeDesign.Color.textPrimary)
        .contentTransition(.numericText(value: Double(store.allWeekItems.count)))
        .animation(.spring(response: 0.6, dampingFraction: 0.9), value: store.allWeekItems.count)
    }

    private func statChip(icon: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(HomeDesign.Color.purple500)
            Text(label)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundStyle(HomeDesign.Color.ink700)
        }
        .padding(.horizontal, HomeDesign.Spacing.md)
        .padding(.vertical, 7)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.85)))
        .overlay(Capsule(style: .continuous).stroke(HomeDesign.Color.purple100, lineWidth: 1))
    }

    private var speechBubble: some View {
        Text(store.greeting.isEmpty ? " " : store.greeting)
            .font(.system(size: 14.5, weight: .semibold, design: .rounded))
            .foregroundStyle(HomeDesign.Color.ink700)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .redacted(reason: store.isLoading && store.greeting.isEmpty ? .placeholder : [])
            .padding(HomeDesign.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .fill(Color.white.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .stroke(HomeDesign.Color.purple100, lineWidth: 1)
            )
            // 말풍선 꼬리 — 마스코트 쪽(오른쪽 아래)을 가리킨다.
            .overlay(alignment: .bottomTrailing) {
                BubbleTail()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 12, height: 11)
                    .offset(x: 11, y: -16)
            }
    }

    /// 이번 주 월–일 범위 라벨 (예: "6월 9일 – 6월 15일").
    private var weekRangeLabel: String {
        let interval = WeeklyDigestFeature.currentWeekInterval(now: Date())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일"
        let endDay = interval.end.addingTimeInterval(-1)
        return "\(formatter.string(from: interval.start)) – \(formatter.string(from: endDay))"
    }

    private var remainingTodoCount: Int {
        store.upcoming.filter { !$0.isSchedule }.count
    }

    // MARK: - ② 아직 안 끝났어요

    private var unfinishedSection: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            sectionHeader(
                "아직 안 끝났어요",
                systemImage: "checklist",
                badge: store.upcoming.count
            )
            VStack(spacing: HomeDesign.Spacing.sm) {
                ForEach(store.upcoming) { item in
                    UnfinishedRow(
                        item: item,
                        isCompleting: store.completingIDs.contains(item.id),
                        onComplete: {
                            store.send(.todoCompleteTapped(localID: item.id, instanceID: item.instanceID))
                        },
                        onTap: { store.send(.mochiItemTapped(item.id, hero: nil)) }
                    )
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            // 1-tap 완료로 행이 빠질 때 부드럽게 줄어들도록.
            .animation(.spring(response: 0.4, dampingFraction: 0.84), value: store.upcoming)
        }
    }

    // MARK: - ③ 이번 주 이런 걸 모았어요

    private var harvestSection: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            sectionHeader("이런 걸 모았어요", systemImage: "sparkles")
            VStack(spacing: HomeDesign.Spacing.sm) {
                ForEach(Array(store.groups.enumerated()), id: \.element.id) { index, group in
                    HarvestGroupCard(group: group, index: index) { id in
                        store.send(.mochiItemTapped(id, hero: nil))
                    }
                }
            }
        }
    }

    private var emptyHarvest: some View {
        VStack(spacing: HomeDesign.Spacing.md) {
            Image("mochi2")
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .opacity(0.9)
            VStack(spacing: 5) {
                Text("이번 주엔 아직 모은 기억이 없어요")
                    .font(.system(size: 14.5, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                Text("화면을 캡처하거나 링크를 보내면\n다음 돌아보기가 풍성해져요.")
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /// ④ 마무리 — 회수의 주체는 모찌라는 것을 마지막 한 줄로 남긴다.
    private var weekFooter: some View {
        VStack(spacing: HomeDesign.Spacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HomeDesign.Color.purple400.opacity(0.7))
            Text("이번 주 기억은 모찌가 잘 맡아둘게요.\n궁금해지면 언제든 물어봐 주세요!")
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, HomeDesign.Spacing.sm)
    }

    private func sectionHeader(_ title: String, systemImage: String, badge: Int? = nil) -> some View {
        HStack(spacing: HomeDesign.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(HomeDesign.Color.purple500)
            Text(title)
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textPrimary)
            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.purple600)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(HomeDesign.Color.purple100))
            }
        }
    }
}

// MARK: - 말풍선 꼬리

/// 오른쪽 아래로 뻗는 작은 꼬리 — 말풍선이 마스코트의 발화임을 드러낸다.
private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.maxX * 0.7, y: rect.maxY * 0.2)
        )
        path.addQuadCurve(
            to: CGPoint(x: 0, y: rect.maxY * 0.55),
            control: CGPoint(x: rect.maxX * 0.25, y: rect.maxY * 0.9)
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - ② 행 (미해결 todo / 다가올 일정)

/// 캘린더 탭과 같은 시각 언어 — 일정은 날짜 타일(월/일) + 상대 라벨(sky),
/// 할 일은 체크 + 긴급도 색 D-day(`DueDisplay`).
private struct UnfinishedRow: View {
    let item: WeeklyDigestFeature.UpcomingItem
    let isCompleting: Bool
    let onComplete: () -> Void
    let onTap: () -> Void

    /// 마감/일시 원문을 날짜로 파싱(자연어는 nil → 원문 그대로 표시).
    private var dueDate: Date? { CalendarDueDate.parse(item.dueLabel) }

    var body: some View {
        HStack(spacing: HomeDesign.Spacing.md) {
            // 할 일만 완료 체크 — 일정은 완료 개념이 어색해 날짜 타일로 표시만.
            if item.isSchedule {
                ScheduleDateTile(date: dueDate)
            } else {
                Button(action: onComplete) {
                    ZStack {
                        Circle()
                            .strokeBorder(
                                isCompleting ? HomeDesign.Color.mint400 : HomeDesign.Color.purple200,
                                lineWidth: 2
                            )
                        if isCompleting {
                            Circle().fill(HomeDesign.Color.mint400).padding(3)
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 26, height: 26)
                    // 체크 터치영역 44pt 보장.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .disabled(isCompleting)
                .accessibilityLabel("할 일 완료")
            }

            Button(action: onTap) {
                HStack(spacing: HomeDesign.Spacing.sm) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.mochiItem.displayTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(HomeDesign.Color.textPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let due = dueText {
                            Text(due)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(dueColor)
                                .lineLimit(1)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.textFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.leading, item.isSchedule ? HomeDesign.Spacing.md : HomeDesign.Spacing.sm)
        .padding(.trailing, HomeDesign.Spacing.lg)
        .padding(.vertical, item.isSchedule ? HomeDesign.Spacing.md : HomeDesign.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .fill(HomeDesign.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .stroke(HomeDesign.Color.border, lineWidth: 1)
        )
        .opacity(isCompleting ? 0.55 : 1)
    }

    /// 파싱되면 캘린더 탭과 같은 표현(상대 라벨/D-day), 안 되면 원문 그대로.
    private var dueText: String? {
        if let dueDate {
            return item.isSchedule ? DueDisplay.scheduleLabel(dueDate) : DueDisplay.deadlineLabel(dueDate)
        }
        guard let raw = item.dueLabel, !raw.isEmpty else { return nil }
        return raw
    }

    private var dueColor: Color {
        if item.isSchedule { return HomeDesign.Color.sky400 }
        return DueDisplay.deadlineColor(dueDate)
    }
}

// MARK: - ③ 카테고리 카드 (썸네일 미리보기 + 펼침)

/// 접힌 상태에서도 겹친 썸네일로 "뭘 모았는지"가 보인다 — 텍스트가 아니라 기억이 떠오르게.
private struct HarvestGroupCard: View {
    let group: WeeklyDigestFeature.DigestGroup
    let index: Int
    let onTapItem: (MochiItem.ID) -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: HomeDesign.Spacing.md) {
                    ZStack {
                        Circle().fill(tint.soft)
                        Image(systemName: MochiCategoryIcon.icon(for: group.coarse, fallbackIndex: index))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(tint.strong)
                    }
                    .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.coarse)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(HomeDesign.Color.textPrimary)
                            .lineLimit(1)
                        Text("\(group.items.count)개의 기억")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundStyle(HomeDesign.Color.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !isExpanded {
                        thumbnailFan
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(HomeDesign.Color.textFaint)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, HomeDesign.Spacing.lg)
                .padding(.vertical, HomeDesign.Spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(group.items) { item in
                        Divider().padding(.leading, HomeDesign.Spacing.lg)
                        Button { onTapItem(item.id) } label: {
                            HStack(spacing: HomeDesign.Spacing.md) {
                                itemThumbnail(item, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayTitle)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(HomeDesign.Color.ink700)
                                        .lineLimit(1)
                                    Text(item.displaySubtitle)
                                        .font(.system(size: 10.5, weight: .regular))
                                        .foregroundStyle(HomeDesign.Color.textMuted)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(HomeDesign.Color.textFaint)
                            }
                            .padding(.horizontal, HomeDesign.Spacing.lg)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .fill(HomeDesign.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .stroke(HomeDesign.Color.border, lineWidth: 1)
        )
    }

    /// 최대 3개를 살짝 겹쳐 보여주는 미리보기 — 펼치기 전의 시각적 단서.
    private var thumbnailFan: some View {
        HStack(spacing: -10) {
            ForEach(Array(group.items.prefix(3).enumerated()), id: \.element.id) { _, item in
                itemThumbnail(item, size: 30)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(HomeDesign.Color.surface, lineWidth: 2)
                    )
            }
        }
    }

    @ViewBuilder
    private func itemThumbnail(_ item: MochiItem, size: CGFloat) -> some View {
        Group {
            switch item.viewKind {
            case .screenshot:
                LocalThumbnail(
                    relativePath: item.source.imageRefs.first?.relativePath,
                    targetSize: CGSize(width: size, height: size)
                ) {
                    Rectangle().fill(HomeDesign.Color.purple100)
                }
            case .memo:
                ZStack {
                    Rectangle().fill(HomeDesign.Color.butter50)
                    Image(systemName: "doc.text")
                        .font(.system(size: size * 0.4, weight: .medium))
                        .foregroundStyle(HomeDesign.Color.butter400.opacity(0.8))
                }
            case .url:
                ZStack {
                    Rectangle().fill(HomeDesign.Color.purple50)
                    Image(systemName: "link")
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.purple600.opacity(0.75))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var tint: (soft: Color, strong: Color) {
        let tints: [(Color, Color)] = [
            (HomeDesign.Color.blush100, HomeDesign.Color.blush400),
            (HomeDesign.Color.purple100, HomeDesign.Color.purple500),
            (HomeDesign.Color.mint100, HomeDesign.Color.mint400),
            (HomeDesign.Color.sky100, HomeDesign.Color.sky400),
            (HomeDesign.Color.butter100, HomeDesign.Color.butter400),
        ]
        return tints[index % tints.count]
    }
}
