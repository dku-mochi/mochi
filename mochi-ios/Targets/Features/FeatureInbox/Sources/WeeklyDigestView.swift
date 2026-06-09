import SwiftUI
import ComposableArchitecture
import CoreDomain
import DesignSystem

/// "이번주 정리 보기" — 모찌가 한 주를 추려 건네는 회고 화면.
/// 4-Intent 라벨 비노출. 위→아래: 모찌 한마디 → 아직 안 끝났어요 → 이런 걸 모았어요.
public struct WeeklyDigestView: View {

    @Bindable public var store: StoreOf<WeeklyDigestFeature>

    public init(store: StoreOf<WeeklyDigestFeature>) {
        self.store = store
    }

    public var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: HomeDesign.Spacing.xl) {
                greetingCard
                if !store.upcoming.isEmpty {
                    unfinishedSection
                }
                if store.groups.isEmpty {
                    emptyHarvest
                } else {
                    harvestSection
                }
            }
            .padding(.horizontal, HomeDesign.Spacing.xl)
            .padding(.top, HomeDesign.Spacing.md)
            .padding(.bottom, 40)
        }
        .background(HomeDesign.Color.bg.ignoresSafeArea())
        .preferredColorScheme(.light)
        .navigationTitle("이번 주 돌아보기")
        .navigationBarTitleDisplayMode(.inline)
        .task { store.send(.onAppear) }
    }

    // MARK: - ① 모찌의 한마디

    private var greetingCard: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white, HomeDesign.Color.purple50, HomeDesign.Color.sky100.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
                Text("이번 주 \(store.allWeekItems.count)개의 기억")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.purple600)
                Text(store.greeting.isEmpty ? " " : store.greeting)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .redacted(reason: store.isLoading && store.greeting.isEmpty ? .placeholder : [])
            }
            .padding(HomeDesign.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)

            Image("mochi2")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .padding(.trailing, HomeDesign.Spacing.md)
                .padding(.bottom, 2)
                .allowsHitTesting(false)
        }
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .stroke(HomeDesign.Color.purple100, lineWidth: 1.2)
        )
        .cardShadow()
    }

    // MARK: - ② 아직 안 끝났어요

    private var unfinishedSection: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            sectionHeader("아직 안 끝났어요", systemImage: "checklist")
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
                }
            }
        }
    }

    // MARK: - ③ 이번 주 이런 걸 모았어요

    private var harvestSection: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            sectionHeader("이번 주 이런 걸 모았어요", systemImage: "sparkles")
            VStack(spacing: HomeDesign.Spacing.sm) {
                ForEach(store.groups) { group in
                    HarvestGroupRow(group: group) { id in
                        store.send(.mochiItemTapped(id, hero: nil))
                    }
                }
            }
        }
    }

    private var emptyHarvest: some View {
        VStack(spacing: HomeDesign.Spacing.md) {
            Image(systemName: "tray")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(HomeDesign.Color.textFaint)
            Text("이번 주엔 아직 모은 기억이 없어요")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: HomeDesign.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(HomeDesign.Color.purple500)
            Text(title)
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textPrimary)
        }
    }
}

// MARK: - ② 행 (미해결 todo / 다가올 일정)

private struct UnfinishedRow: View {
    let item: WeeklyDigestFeature.UpcomingItem
    let isCompleting: Bool
    let onComplete: () -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: HomeDesign.Spacing.md) {
            // 할 일만 완료 체크 — 일정은 완료 개념이 어색해 점 아이콘으로 표시만.
            if item.isSchedule {
                Image(systemName: "calendar")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.sky400)
                    .frame(width: 28, height: 28)
            } else {
                Button(action: onComplete) {
                    Image(systemName: isCompleting ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(isCompleting ? HomeDesign.Color.mint400 : HomeDesign.Color.purple400)
                }
                .buttonStyle(PressableStyle())
                .disabled(isCompleting)
            }

            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.mochiItem.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let due = item.dueLabel, !due.isEmpty {
                        Text(due)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(HomeDesign.Color.blush400)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, HomeDesign.Spacing.md)
        .padding(.vertical, HomeDesign.Spacing.md)
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
}

// MARK: - ③ 카테고리 묶음 (펼치면 항목)

private struct HarvestGroupRow: View {
    let group: WeeklyDigestFeature.DigestGroup
    let onTapItem: (MochiItem.ID) -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: HomeDesign.Spacing.md) {
                    Text(group.coarse)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(group.items.count)개")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.purple600)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(HomeDesign.Color.textFaint)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, HomeDesign.Spacing.lg)
                .padding(.vertical, 14)
            }
            .buttonStyle(PressableStyle())

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(group.items) { item in
                        Divider().padding(.leading, HomeDesign.Spacing.lg)
                        Button { onTapItem(item.id) } label: {
                            HStack(spacing: HomeDesign.Spacing.md) {
                                Image(systemName: Self.icon(item.viewKind))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(HomeDesign.Color.purple400)
                                    .frame(width: 22)
                                Text(item.displayTitle)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(HomeDesign.Color.ink700)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, HomeDesign.Spacing.lg)
                            .padding(.vertical, 11)
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

    private static func icon(_ kind: MochiItemKind) -> String {
        switch kind {
        case .screenshot: return "photo"
        case .memo: return "note.text"
        case .url: return "link"
        }
    }
}
