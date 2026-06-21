import SwiftUI
import ComposableArchitecture
import CoreDomain
import DesignSystem

/// "이번 달 돌아보기" — 모찌가 한 달을 추려 **먼저 말을 거는** 회고 화면.
///
/// 미션("필요한 기억은 쉽게 떠오른다")의 진열장: 사용자가 뒤지는 게 아니라
/// 모찌가 건넨다. 4-Intent 라벨 비노출. 위→아래:
///  - ① 히어로: 월 네비게이터(◀ 2026년 6월 ▶, 과거로 넘겨보기) + 쌓인 기억 수 + 카테고리 요약 바 + 모찌의 한마디
///  - ② 이런 걸 모았어요: 카테고리별 가로 레일 — 그 달 항목 전부를 가로 스크롤, 탭하면 상세.
///    헤더 "전체 보기" → 검색 탭을 그 카테고리로 필터. 카테고리 많으면 아래는 접는다.
///  - ③ 푸터: 회수는 모찌에게 물어보면 된다는 마무리 한 줄
public struct MonthlyDigestView: View {

    @Bindable public var store: StoreOf<MonthlyDigestFeature>
    /// 진입 시 섹션 순차 등장 트리거 (한 번만).
    @State private var hasEntered = false
    /// 카테고리가 많을 때 아래쪽 레일을 접는다 — "더 보기"로 펼침.
    @State private var showsAllCategories = false

    /// 접기 전 항상 보이는 카테고리 수 = digestTint 색 수(5)와 정렬 — 펼침 전엔 색이 안 겹친다.
    private let categoryCollapseLimit = 5

    public init(store: StoreOf<MonthlyDigestFeature>) {
        self.store = store
    }

    public var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: HomeDesign.Spacing.xl) {
                heroCard
                    .riseIn(hasEntered, index: 0)
                if store.groups.isEmpty {
                    if !store.isLoading {
                        emptyHarvest
                            .riseIn(hasEntered, index: 1)
                    }
                } else {
                    harvestSection
                        .riseIn(hasEntered, index: 1)
                }
                monthFooter
                    .riseIn(hasEntered, index: 2)
            }
            .padding(.horizontal, HomeDesign.Spacing.xl)
            .padding(.top, HomeDesign.Spacing.md)
            .padding(.bottom, 40)
        }
        .background(backgroundLayer.ignoresSafeArea())
        .preferredColorScheme(.light)
        .navigationTitle("이번 달 돌아보기")
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

    // MARK: - ① 히어로 (월 네비게이터 + 기억 수 + 카테고리 요약 + 모찌의 한마디)

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.lg) {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
                monthNavigator
                heroHeadline
            }

            // 카테고리 요약 바 — 2개 이상일 때만(1개면 단색 풀바라 무의미). 아래 레일과 색 일치.
            if store.groups.count >= 2 {
                categorySummaryBar
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

    /// 월 네비게이터 — ◀ [2026년 6월] ▶. 과거로 넘겨보고, 이번 달이면 ▶ 비활성.
    private var monthNavigator: some View {
        HStack(spacing: HomeDesign.Spacing.sm) {
            monthArrow(systemName: "chevron.left", enabled: true) { store.send(.previousMonth) }
            Text(monthLabel)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(HomeDesign.Color.purple600)
                .monospacedDigit()
                .contentTransition(.numericText())
                .frame(minWidth: 92)
            monthArrow(systemName: "chevron.right", enabled: store.canGoNextMonth) { store.send(.nextMonth) }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: store.monthOffset)
    }

    private func monthArrow(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(enabled ? HomeDesign.Color.purple600 : HomeDesign.Color.ink300)
                .frame(width: 30, height: 30)
                .background(Circle().fill(enabled ? HomeDesign.Color.purple50 : HomeDesign.Color.surface))
                .overlay(Circle().stroke(HomeDesign.Color.purple100, lineWidth: enabled ? 1 : 0))
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(systemName == "chevron.left" ? "이전 달" : "다음 달")
    }

    private var heroHeadline: some View {
        Group {
            if store.allMonthItems.isEmpty {
                Text(store.monthOffset == 0 ? "이번 달은 잠깐 쉬어갔어요" : "조용한 한 달이었어요")
            } else {
                Text("기억 ")
                + Text("\(store.allMonthItems.count)개")
                    .foregroundStyle(HomeDesign.Color.purple600)
                + Text("가 쌓였어요")
            }
        }
        .font(.system(size: 21, weight: .heavy, design: .rounded))
        .foregroundStyle(HomeDesign.Color.textPrimary)
        .contentTransition(.numericText(value: Double(store.allMonthItems.count)))
        .animation(.spring(response: 0.6, dampingFraction: 0.9), value: store.allMonthItems.count)
    }

    /// 카테고리 비중을 한 줄 세그먼트 + 레전드로 — 색은 위 레일과 공유. 상위 5개만 색으로,
    /// 나머지는 회색 "기타 N개" 한 조각으로 합쳐 막대 정확성·레전드 길이를 통제(작은 카테고리 많을 때 오버플로 방지).
    private var categorySummaryBar: some View {
        let shown = Array(store.groups.prefix(categoryCollapseLimit))
        let restCount = store.groups.count - shown.count
        let restItems = store.groups.dropFirst(categoryCollapseLimit).reduce(0) { $0 + $1.items.count }
        let total = max(1, store.groups.reduce(0) { $0 + $1.items.count })
        let segCount = shown.count + (restItems > 0 ? 1 : 0)
        return VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
            GeometryReader { geo in
                let gap: CGFloat = 2
                let usable = max(0, geo.size.width - gap * CGFloat(max(0, segCount - 1)))
                HStack(spacing: gap) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, group in
                        digestTint(index).strong
                            .frame(width: max(6, usable * CGFloat(group.items.count) / CGFloat(total)))
                    }
                    if restItems > 0 {
                        HomeDesign.Color.ink300
                            .frame(width: max(6, usable * CGFloat(restItems) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 9)
            .clipShape(Capsule(style: .continuous))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HomeDesign.Spacing.md) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, group in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(digestTint(index).strong)
                                .frame(width: 8, height: 8)
                            Text("\(group.coarse) \(group.items.count)")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(HomeDesign.Color.ink700)
                        }
                    }
                    if restCount > 0 {
                        Text("기타 \(restCount)개")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(HomeDesign.Color.textMuted)
                    }
                }
            }
        }
    }

    private var speechBubble: some View {
        // 로딩 중엔 더미 문장으로 skeleton 폭을 확보(공백 1칸이면 placeholder 가 거의 안 보임).
        Text(store.greeting.isEmpty ? (store.isLoading ? "이번 달 기억을 정리하고 있어요" : " ") : store.greeting)
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

    /// 보고 있는 달 라벨 (예: "2026년 6월").
    private var monthLabel: String {
        let interval = MonthlyDigestFeature.monthInterval(offset: store.monthOffset, now: Date())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy년 M월"
        return formatter.string(from: interval.start)
    }

    // MARK: - ② 이번 달 이런 걸 모았어요 (카테고리 가로 레일)

    private var harvestSection: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.lg) {
            sectionHeader("이런 걸 모았어요", systemImage: "sparkles")
            let visible = showsAllCategories
                ? Array(store.groups.enumerated())
                : Array(store.groups.enumerated().prefix(categoryCollapseLimit))
            ForEach(visible, id: \.element.id) { index, group in
                HarvestRail(
                    group: group,
                    index: index,
                    onTapItem: { store.send(.mochiItemTapped($0, hero: nil)) },
                    onViewAll: { store.send(.categoryViewAllTapped($0)) }
                )
            }
            if !showsAllCategories && store.groups.count > categoryCollapseLimit {
                moreCategoriesButton(remaining: store.groups.count - categoryCollapseLimit)
            }
        }
    }

    private func moreCategoriesButton(remaining: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { showsAllCategories = true }
        } label: {
            HStack(spacing: 6) {
                Text("기타 \(remaining)개 카테고리 더 보기")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(HomeDesign.Color.purple600)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
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

    private var emptyHarvest: some View {
        VStack(spacing: HomeDesign.Spacing.md) {
            VStack(spacing: 5) {
                Text(store.monthOffset == 0 ? "이번 달엔 아직 모은 기억이 없어요" : "그 달엔 모은 기억이 없어요")
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

    /// ③ 마무리 — 회수의 주체는 모찌라는 것을 마지막 한 줄로 남긴다.
    private var monthFooter: some View {
        VStack(spacing: HomeDesign.Spacing.sm) {
            Image("mochi2")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .opacity(0.9)
                .accessibilityHidden(true)
            Text(store.monthOffset == 0
                ? "이번 달 기억은 모찌가 잘 맡아둘게요.\n궁금해지면 언제든 물어봐 주세요!"
                : "그 달의 기억은 모찌가 잘 맡아둘게요.\n궁금해지면 언제든 물어봐 주세요!")
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

// MARK: - 카테고리 색

/// 카테고리 index → 색. 히어로 요약 바와 레일 아이콘이 공유해 같은 카테고리=같은 색.
func digestTint(_ index: Int) -> (soft: Color, strong: Color) {
    let tints: [(Color, Color)] = [
        (HomeDesign.Color.blush100, HomeDesign.Color.blush400),
        (HomeDesign.Color.purple100, HomeDesign.Color.purple500),
        (HomeDesign.Color.mint100, HomeDesign.Color.mint400),
        (HomeDesign.Color.sky100, HomeDesign.Color.sky400),
        (HomeDesign.Color.butter100, HomeDesign.Color.butter400),
    ]
    return tints[index % tints.count]
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

// MARK: - ② 카테고리 가로 레일

/// 한 카테고리 = 헤더(아이콘·이름·개수·전체 보기) + 그 달 항목 전부의 가로 스크롤.
/// 세로 길이는 항목 수와 무관(가로로 흡수) — 카테고리 수로만 늘어난다. 썸네일 탭 → 상세.
private struct HarvestRail: View {
    let group: MonthlyDigestFeature.DigestGroup
    let index: Int
    let onTapItem: (MochiItem.ID) -> Void
    let onViewAll: (String) -> Void

    /// 실제 정규화된 category 묶음만 검색 필터로 갈 수 있다 — "정리 중"·의도 fallback 묶음은 "전체 보기"를 숨긴다.
    private var canViewAll: Bool { group.isSearchable }

    var body: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
            railHeader

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HomeDesign.Spacing.sm) {
                    ForEach(group.items) { item in
                        Button { onTapItem(item.id) } label: {
                            railThumbnail(item)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, HomeDesign.Spacing.xl)
            }
            // 레일만 화면 양끝까지 흘려보낸다(상위 페이지 패딩 상쇄) + 우측 끝 페이드로 "더 있다"를 항상 신호.
            .padding(.horizontal, -HomeDesign.Spacing.xl)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.93),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
    }

    /// 헤더 — 좌측 아이콘·이름·개수는 비대화형, 우측 "전체 보기"만 탭 타겟(퍼플 칩). "정리 중"·fallback 묶음은 칩 숨김.
    private var railHeader: some View {
        HStack(spacing: HomeDesign.Spacing.sm) {
            ZStack {
                Circle().fill(tint.soft)
                Image(systemName: MochiCategoryIcon.icon(for: group.coarse, fallbackIndex: index))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint.strong)
            }
            .frame(width: 32, height: 32)

            Text(group.coarse)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textPrimary)
                .lineLimit(1)
            Text("\(group.items.count)개")
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textMuted)

            Spacer(minLength: HomeDesign.Spacing.sm)

            if canViewAll {
                Button { onViewAll(group.coarse) } label: {
                    HStack(spacing: 3) {
                        Text("전체 보기")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(HomeDesign.Color.purple600)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(HomeDesign.Color.purple50))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    /// 104pt 정사각 썸네일 + 하단 제목 캡션. 캡처 이미지/메모/링크를 형태로 구분.
    private func railThumbnail(_ item: MochiItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            thumbnailBackground(item)
            // 미분석 항목의 시스템 폴백 제목("(분석 대기 중)")이 회고 진열장에 노출되지 않게.
            Text(item.analysis == nil ? "정리 중" : item.displayTitle)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.top, 16)
                .padding(.bottom, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [Color.black.opacity(0.45), Color.black.opacity(0.0)],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
                .allowsHitTesting(false)
        }
        .frame(width: 104, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // OG 이미지가 있는 링크는 사진처럼 렌더되므로 작은 링크 배지로 "링크"임을 표시.
        .overlay(alignment: .topTrailing) {
            if !item.source.imageRefs.isEmpty, item.source.url != nil {
                Image(systemName: "link")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Circle().fill(Color.black.opacity(0.45)))
                    .padding(6)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(HomeDesign.Color.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func thumbnailBackground(_ item: MochiItem) -> some View {
        switch item.viewKind {
        case .screenshot:
            LocalThumbnail(
                relativePath: item.source.imageRefs.first?.displayRelativePath,
                objectKey: item.source.imageRefs.first?.objectKey,
                sha256: item.source.imageRefs.first?.sha256,
                mimeType: item.source.imageRefs.first?.mimeType,
                targetSize: CGSize(width: 104, height: 104)
            ) {
                Rectangle().fill(HomeDesign.Color.purple100)
            }
        case .memo:
            ZStack {
                Rectangle().fill(HomeDesign.Color.butter50)
                Image(systemName: "doc.text")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(HomeDesign.Color.butter400.opacity(0.8))
            }
        case .url:
            ZStack {
                Rectangle().fill(HomeDesign.Color.purple50)
                Image(systemName: "link")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.purple600.opacity(0.75))
            }
        }
    }

    private var tint: (soft: Color, strong: Color) { digestTint(index) }
}
