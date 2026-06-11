import SwiftUI
import CoreDomain
import DesignSystem

/// 검색 탭 *포커스* 화면 (.focused phase) — 검색바 active + query 빈 상태.
///
/// 구조: 모찌(♥) + 인사 → 최근 검색 + "모두 지우기" → divider → 빠른 검색 (출처 3 칩).
struct SearchFocusedView: View {
    let recentSearches: [String]
    let onRecent: (String) -> Void
    let onRemoveRecent: (String) -> Void
    let onClearRecents: () -> Void
    let onQuickFilter: (SearchD5.TypeFilter) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 0) {
                hello
                    .padding(.top, 72)
                    .padding(.bottom, 60)

                VStack(alignment: .leading, spacing: 16) {
                    if !recentSearches.isEmpty {
                        recentSection
                        Rectangle()
                            .fill(SearchD5.Palette.divider)
                            .frame(height: 1)
                            .padding(.vertical, 4)
                    }
                    quickSection
                }
                .padding(.horizontal, SearchD5.Sizes.pageH)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: - 모찌 + 인사

    private var hello: some View {
        VStack(spacing: 22) {
            FloatingMascot(imageName: "mochi-hello", size: SearchD5.Sizes.helloMascotSize)

            VStack(spacing: 8) {
                Text("어떤 모찌를 찾고 있나요?")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .tracking(-0.6)
                    .foregroundStyle(SearchD5.Palette.textPrimary)
                Text("모찌가 필요한 정보를 도와드릴게요!")
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .tracking(-0.2)
                    .foregroundStyle(SearchD5.Palette.textSecondary)
            }
            .multilineTextAlignment(.center)
        }
    }

    // MARK: - 최근 검색

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("최근 검색")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .tracking(-0.4)
                    .foregroundStyle(SearchD5.Palette.textPrimary)
                Spacer()
                Button(action: onClearRecents) {
                    Text("모두 지우기")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .tracking(-0.2)
                        .foregroundStyle(SearchD5.Palette.primary)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(recentSearches, id: \.self) { term in
                        RecentChip(term: term) { onRecent(term) }
                            .contextMenu {
                                Button(role: .destructive) {
                                    onRemoveRecent(term)
                                } label: {
                                    Label("이 검색어 지우기", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - 빠른 검색 (link / screenshot / memo)

    private var quickSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("빠른 검색")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .tracking(-0.2)
                .foregroundStyle(SearchD5.Palette.textSecondary)

            HStack(spacing: 10) {
                QuickFilterChip(filter: .link)        { onQuickFilter(.link) }
                QuickFilterChip(filter: .screenshot)  { onQuickFilter(.screenshot) }
                QuickFilterChip(filter: .memo)        { onQuickFilter(.memo) }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Floating mascot (focused·empty 공용 — 아주 약한 둥둥)

struct FloatingMascot: View {
    let imageName: String
    let size: CGFloat
    @State private var isFloating = false

    var body: some View {
        Image(imageName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .offset(y: isFloating ? -4 : 4)
            .animation(
                .easeInOut(duration: 2.6).repeatForever(autoreverses: true),
                value: isFloating
            )
            .onAppear { isFloating = true }
            .accessibilityHidden(true)
    }
}

// MARK: - Recent chip (검색어 칩)

private struct RecentChip: View {
    let term: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(term)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .tracking(-0.2)
                .foregroundStyle(SearchD5.Palette.textPrimary.opacity(0.84))
                .padding(.horizontal, 20)
                .frame(height: 46)
                .background(Capsule().fill(SearchD5.Palette.card))
                .overlay(Capsule().stroke(SearchD5.Palette.cardBorder, lineWidth: 1))
                .shadow(color: SearchD5.Palette.cardShadow, radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Quick filter chip (시안 #35 — 보라 tile 아이콘 + 텍스트)

private struct QuickFilterChip: View {
    let filter: SearchD5.TypeFilter
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(filter.activeBg)
                        .frame(width: 26, height: 26)
                    Image(systemName: filter.systemImage)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(filter.activeFg)
                }
                Text(filter.label)
                    .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                    .tracking(-0.2)
                    .foregroundStyle(SearchD5.Palette.textPrimary.opacity(0.84))
            }
            .padding(.leading, 8)
            .padding(.trailing, 16)
            .frame(height: 46)
            .background(Capsule().fill(SearchD5.Palette.card))
            .overlay(Capsule().stroke(SearchD5.Palette.cardBorder, lineWidth: 1))
            .shadow(color: SearchD5.Palette.cardShadow, radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
    }
}
