import SwiftUI
import CoreDomain
import DesignSystem

/// 검색 탭 *기본* 화면 (.idle phase) — 검색바 빈 상태 + 포커스 X.
///
/// 구조: 필터칩 row (TypeFilter 5개) + 2col 그리드 (filteredItems).
struct SearchDefaultView: View {
    let items: [MochiItem]
    let typeFilter: SearchD5.TypeFilter
    let onTypeFilter: (SearchD5.TypeFilter) -> Void
    let onCardTap: (MochiItem.ID, HeroSourceFrames) -> Void
    let onCardDelete: (MochiItem.ID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            filterChips
                .padding(.top, 10)
                .padding(.bottom, 6)

            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: SearchD5.Sizes.gridGap),
                            GridItem(.flexible()),
                        ],
                        spacing: SearchD5.Sizes.gridGap
                    ) {
                        ForEach(items) { item in
                            SearchGridCard(
                                item: item,
                                onTap: { hero in onCardTap(item.id, hero) },
                                onDelete: { onCardDelete(item.id) }
                            )
                        }
                    }
                    .padding(.horizontal, SearchD5.Sizes.pageH)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.immediately)
            }
        }
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

    // MARK: - 필터칩 row (TypeFilter 5개)

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SearchD5.TypeFilter.allCases) { filter in
                    TypeFilterChip(
                        filter: filter,
                        isActive: typeFilter == filter
                    ) {
                        onTypeFilter(filter)
                    }
                }
            }
            .padding(.horizontal, SearchD5.Sizes.pageH)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - TypeFilter chip (active = filter 색 배경 + border, idle = 흰 + ink border)

struct TypeFilterChip: View {
    let filter: SearchD5.TypeFilter
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: filter.systemImage)
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                Text(filter.label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .tracking(-0.3)
            }
            .padding(.horizontal, 9)
            .frame(height: SearchD5.Sizes.filterChipHeight)
            .foregroundStyle(isActive ? filter.activeFg : SearchD5.Palette.textPrimary.opacity(0.82))
            .background(
                Capsule().fill(isActive ? filter.activeBg : SearchD5.Palette.card)
            )
            .overlay(
                Capsule().stroke(
                    isActive ? filter.activeFg.opacity(0.55) : SearchD5.Palette.cardBorder,
                    lineWidth: isActive ? 1.2 : 1
                )
            )
            .animation(.easeInOut(duration: 0.18), value: isActive)
        }
        .buttonStyle(TypeChipPress())
    }
}

private struct TypeChipPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
