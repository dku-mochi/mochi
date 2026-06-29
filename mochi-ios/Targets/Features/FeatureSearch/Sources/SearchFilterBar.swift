import SwiftUI
import DesignSystem

/// 검색 탭 전 phase 공용 필터 바 — 좌측 고정 종류 드롭다운 + 우측 가로 스크롤 카테고리 칩.
///
/// idle / results / empty 가 **같은 바**를 그려, 검색을 시작해도 상단이 바뀌지 않는다(일관성).
/// 종류 ∧ 카테고리는 AND 로 그리드·검색 양쪽의 scope 를 좁힌다 — 카테고리를 고른 채 검색하면
/// 그 카테고리 안에서만 결과가 나온다.
struct SearchFilterBar: View {
    let typeFilter: SearchD5.TypeFilter
    let onTypeFilter: (SearchD5.TypeFilter) -> Void
    /// 카테고리 칩 — 전체 기록의 정규화 category 많은 순. nil = 전체.
    let categories: [String]
    let selectedCategory: String?
    let onCategory: (String?) -> Void

    var body: some View {
        HStack(spacing: HomeDesign.Spacing.sm) {
            typeDropdown
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
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
        // 칩 선택이 손끝에 닿게 — 선택/해제 순간에만 가벼운 selection 햅틱(iOS 17+).
        .sensoryFeedback(.selection, trigger: selectedCategory)
        .sensoryFeedback(.selection, trigger: typeFilter)
    }

    /// 종류 필터 드롭다운 — "전체" 칩 자리를 Menu 트리거로. 선택 시 그 타입 색으로 활성 표시.
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
                    .foregroundStyle(active ? typeFilter.activeFg.opacity(0.7) : SearchD5.Palette.textTertiary)
            }
            .foregroundStyle(active ? typeFilter.activeFg : SearchD5.Palette.textPrimary.opacity(0.82))
            .padding(.horizontal, 11)
            .frame(height: SearchD5.Sizes.filterChipHeight)
            .background(Capsule().fill(active ? typeFilter.activeBg : SearchD5.Palette.card))
            .overlay(
                Capsule().stroke(
                    active ? typeFilter.activeFg.opacity(0.55) : SearchD5.Palette.cardBorder,
                    lineWidth: active ? 1.2 : 1
                )
            )
            .frame(height: 44)
            .contentShape(Rectangle())
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
            .padding(.horizontal, 11)
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
            // 캡슐은 그대로, 세로 터치 영역만 44.
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
