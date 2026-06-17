import SwiftUI
import CoreDomain
import DesignSystem

/// 검색 탭 *기본* 화면 (.idle phase) — 검색바 빈 상태 + 포커스 X.
///
/// 필터: 타입(전체/링크/스크린샷/메모) 드롭다운 + 카테고리(주간 리포트 정규화 category) 칩 행.
/// 둘은 AND 로 동시 적용(상위 SearchFeature.filteredItems). 2col 모자이크 그리드.
struct SearchDefaultView: View {
    let items: [MochiItem]
    let typeFilter: SearchD5.TypeFilter
    let onTypeFilter: (SearchD5.TypeFilter) -> Void
    /// 카테고리 칩 — 전체 기록의 정규화 category 많은 순. nil = 전체.
    let categories: [String]
    let selectedCategory: String?
    let onCategory: (String?) -> Void
    let onCardTap: (MochiItem.ID, HeroSourceFrames) -> Void
    let onCardDelete: (MochiItem.ID) -> Void
    let onCardToggleFavorite: (MochiItem.ID) -> Void
    let onRefresh: () async -> Void

    var body: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.top, 10)
                .padding(.bottom, 6)

            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    // 카드 높이가 type 별 가변(2:3 이미지 ~275 / 텍스트 타일 138)이라
                    // LazyVGrid(행 정렬) 대신 좌우 독립 column 의 masonry — 높이 균형 분배.
                    HStack(alignment: .top, spacing: SearchD5.Sizes.gridGap) {
                        masonryColumn(columns.left)
                        masonryColumn(columns.right)
                    }
                    // 모자이크 그리드 — 좌우는 칩(pageH 14)보다 살짝 좁은 gridPageH 10.
                    .padding(.horizontal, SearchD5.Sizes.gridPageH)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.immediately)
                .refreshable { await onRefresh() }
            }
        }
    }

    private func masonryColumn(_ columnItems: [MochiItem]) -> some View {
        LazyVStack(spacing: SearchD5.Sizes.gridGap) {
            ForEach(columnItems) { item in
                SearchGridCard(
                    item: item,
                    onTap: { hero in onCardTap(item.id, hero) },
                    onDelete: { onCardDelete(item.id) },
                    onToggleFavorite: { onCardToggleFavorite(item.id) }
                )
                .scrollTransition(.animated(.easeOut(duration: 0.25))) { content, phase in
                    content
                        .opacity(phase.isIdentity ? 1 : 0.55)
                        .scaleEffect(phase.isIdentity ? 1 : 0.96)
                }
            }
        }
    }

    /// 예상 높이 기준 좌우 균형 분배 — 짧은 column 에 다음 카드를 넣는다.
    private var columns: (left: [MochiItem], right: [MochiItem]) {
        var left: [MochiItem] = [], right: [MochiItem] = []
        var leftH: CGFloat = 0, rightH: CGFloat = 0
        for item in items {
            let h = SearchGridCard.estimatedHeight(for: item)
            if leftH <= rightH {
                left.append(item); leftH += h
            } else {
                right.append(item); rightH += h
            }
        }
        return (left, right)
    }

    // MARK: - 빈 상태 (저장된 모찌 0 — 필터 결과 0 도 동일 처리)

    /// 전체 필터에서 비면 "아직 저장 전", 특정 필터에서 비면 "이 종류 없음" 문구로 구분.
    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            FloatingMascot(imageName: "mochi-question", size: 150)
                .padding(.bottom, 20)
            Text(typeFilter == .all ? "아직 저장된 모찌가 없어요" : "\(typeFilter.label) 모찌가 없어요")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .tracking(-0.4)
                .foregroundStyle(SearchD5.Palette.textPrimary)
                .padding(.bottom, 6)
            Text(typeFilter == .all
                 ? "스크린샷·링크·메모를 모찌에게 보내면\n여기에 차곡차곡 모여요"
                 : "다른 종류에서 찾아보세요")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .tracking(-0.2)
                .lineSpacing(3)
                .foregroundStyle(SearchD5.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 필터 바 (타입 드롭다운 + 카테고리 칩)

    /// 좌측 고정 타입 드롭다운 + 우측 가로 스크롤 카테고리 칩. 둘은 AND(상위 filteredItems).
    private var filterBar: some View {
        HStack(spacing: HomeDesign.Spacing.sm) {
            typeDropdown
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    CategoryChip(label: "전체", systemImage: "square.grid.2x2",
                                 isActive: selectedCategory == nil) { onCategory(nil) }
                    ForEach(categories, id: \.self) { category in
                        CategoryChip(
                            label: category,
                            systemImage: MochiCategoryIcon.icon(for: category, fallbackIndex: 0),
                            isActive: selectedCategory == category
                        ) { onCategory(category) }
                    }
                }
                .padding(.trailing, SearchD5.Sizes.pageH)
            }
        }
        .padding(.leading, SearchD5.Sizes.pageH)
    }

    /// 종류 필터 드롭다운 — 기존 "전체" 칩 자리를 Menu 트리거로(미확인 제외). 선택 시 칩 색으로 활성 표시.
    private var typeDropdown: some View {
        let active = typeFilter != .all
        return Menu {
            ForEach([SearchD5.TypeFilter.all, .link, .screenshot, .memo]) { f in
                Button { onTypeFilter(f) } label: { Label(f.label, systemImage: f.systemImage) }
            }
        } label: {
            HStack(spacing: 4) {
                // 타입 선택 시에만 그 타입 아이콘 노출 — 미선택 기본은 "종류"만(카테고리 "전체"와 중복 회피).
                if active {
                    Image(systemName: typeFilter.systemImage)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                }
                Text(active ? typeFilter.label : "종류")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .tracking(-0.3)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(active ? typeFilter.activeFg : SearchD5.Palette.textPrimary.opacity(0.82))
            .padding(.horizontal, 10)
            .frame(height: SearchD5.Sizes.filterChipHeight)
            .background(Capsule().fill(active ? typeFilter.activeBg : SearchD5.Palette.card))
            .overlay(
                Capsule().stroke(
                    active ? typeFilter.activeFg.opacity(0.55) : SearchD5.Palette.cardBorder,
                    lineWidth: active ? 1.2 : 1
                )
            )
        }
        .accessibilityLabel(active ? "종류 필터, 현재 \(typeFilter.label)" : "종류 필터")
    }
}

// MARK: - Category chip (정규화 category — active = 퍼플 캡슐, idle = 흰 + ink border)

private struct CategoryChip: View {
    let label: String
    let systemImage: String
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                Text(label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .tracking(-0.3)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: SearchD5.Sizes.filterChipHeight)
            .foregroundStyle(isActive ? HomeDesign.Color.purple600 : SearchD5.Palette.textPrimary.opacity(0.82))
            .background(
                Capsule().fill(isActive ? HomeDesign.Color.purple50 : SearchD5.Palette.card)
            )
            .overlay(
                Capsule().stroke(
                    isActive ? HomeDesign.Color.purple500.opacity(0.5) : SearchD5.Palette.cardBorder,
                    lineWidth: isActive ? 1.2 : 1
                )
            )
            .animation(.easeInOut(duration: 0.18), value: isActive)
            // 캡슐은 그대로, 세로 터치 영역만 44(검색 필터칩과 동일 규약).
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(TypeChipPress())
        .accessibilityLabel("\(label) 카테고리 필터")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

private struct TypeChipPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
