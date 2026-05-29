import SwiftUI
import ComposableArchitecture
import CoreDomain
import CorePersistence

/// 모찌 홈 화면 — `_workspace/home-mockup/index.html` 시안의 SwiftUI 구현.
///
/// 시안 대비 추가: "중요해 보여요" 섹션 (`dailyImportanceAnalyzer` 가 1일 1회 lazy 갱신).
public struct HomeView: View {

    @Bindable public var store: StoreOf<HomeFeature>
    @FocusState private var quickMemoFocused: Bool

    public init(store: StoreOf<HomeFeature>) {
        self.store = store
    }

    public var body: some View {
        ZStack {
            backgroundLayer.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: HomeDesign.Spacing.xl) {
                    topBar
                        .padding(.top, HomeDesign.Spacing.sm)
                    quickMemoCard
                    analyzingSection
                    needsReviewSection
                    importantSection
                    recentSection
                }
                .padding(.horizontal, HomeDesign.Spacing.xl)
                .padding(.top, HomeDesign.Spacing.md)
            }
            .refreshable {
                await store.send(.refresh).finish()
            }
        }
        .background(HomeDesign.Color.bg.ignoresSafeArea())
        .task { store.send(.onAppear) }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        ZStack {
            HomeDesign.Color.bg

            LinearGradient(
                colors: [
                    HomeDesign.Color.purple200.opacity(0.85),
                    HomeDesign.Color.purpleGlow.opacity(0.55),
                    HomeDesign.Color.bg.opacity(0.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 320)
            .frame(maxHeight: .infinity, alignment: .top)

            RadialGradient(
                colors: [HomeDesign.Color.purple400.opacity(0.55), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 260
            )
            .frame(maxHeight: .infinity, alignment: .top)
            .blendMode(.plusLighter)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: HomeDesign.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("안녕하세요 👋")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(HomeDesign.Color.ink700.opacity(0.7))
                Text("오늘도 모찌가 정리해뒀어요")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .tracking(-0.4)
            }
            Spacer()
            HStack(spacing: HomeDesign.Spacing.sm) {
                CircleIconButton(systemName: "bell", showsBadge: !store.ambiguous.isEmpty) {
                    store.send(.openNotificationsTapped)
                }
                CircleIconButton(systemName: "gearshape", showsBadge: false) {
                    store.send(.openSettingsTapped)
                }
            }
        }
    }

    // MARK: - Quick memo

    private var quickMemoCard: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            Text("빠르게 메모하기")
                .font(.system(size: 15, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(HomeDesign.Color.textPrimary)

            QuickMemoField(text: $store.quickMemoText, isFocused: $quickMemoFocused)

            Divider()
                .overlay(HomeDesign.Color.border)

            HStack(spacing: HomeDesign.Spacing.sm) {
                ChipButton(systemName: "link", label: "URL") {
                    store.send(.urlChipTapped)
                }
                ChipButton(systemName: "camera.viewfinder", label: "스크린샷") {
                    store.send(.screenshotChipTapped)
                }
                Spacer()
                Button {
                    quickMemoFocused = false
                    store.send(.quickMemoSubmitted)
                } label: {
                    HStack(spacing: 6) {
                        if store.isSaving {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.white)
                        }
                        Text(store.isSaving ? "저장 중…" : "저장하고 정리하기")
                            .font(.system(size: 13, weight: .bold))
                            .tracking(-0.1)
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: ctaGradient,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    )
                    .shadow(color: HomeDesign.Color.purple500.opacity(0.3), radius: 12, x: 0, y: 6)
                }
                .buttonStyle(PressableStyle())
                .disabled(store.isSaving || store.quickMemoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(canSubmit ? 1.0 : 0.55)
            }
        }
        .padding(HomeDesign.Spacing.lg)
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

    private var canSubmit: Bool {
        !store.isSaving && !store.quickMemoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var ctaGradient: [Color] {
        canSubmit
            ? [HomeDesign.Color.purple500, HomeDesign.Color.purple600]
            : [HomeDesign.Color.purple200, HomeDesign.Color.purple400.opacity(0.7)]
    }

    // MARK: - 모찌가 분석 중이에요

    @ViewBuilder
    private var analyzingSection: some View {
        if !store.analyzing.isEmpty {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                SectionHeader(title: "모찌가 분석 중이에요", trailing: nil, subtitle: "잠깐만 기다려 주세요")
                AnalyzingCard(mochiItems: Array(store.analyzing))
            }
        }
    }

    // MARK: - 모찌가 헷갈려요

    @ViewBuilder
    private var needsReviewSection: some View {
        if !store.ambiguous.isEmpty {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                SectionHeader(title: "모찌가 헷갈려요", trailing: "전체 보기", subtitle: "둘 중 하나를 골라주세요")
                NeedsReviewCard(
                    mochiItems: Array(store.ambiguous),
                    page: $store.needsReviewPage,
                    onClassify: { id, intent in store.send(.classifyTapped(mochiItemID: id, intent: intent)) },
                    onRetry: { id in store.send(.retryAnalysisTapped(id)) }
                )
            }
        }
    }

    // MARK: - 중요해 보여요

    @ViewBuilder
    private var importantSection: some View {
        if !store.important.isEmpty {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                SectionHeader(title: "중요해 보여요", trailing: "전체 보기", subtitle: "오늘 모찌가 골랐어요")
                horizontalCardRow(mochiItems: Array(store.important))
            }
        }
    }

    // MARK: - 최근 추가한 모찌

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            SectionHeader(title: "최근 추가한 모찌", trailing: "전체 보기")
            if store.recent.isEmpty {
                emptyRecent
            } else {
                horizontalCardRow(mochiItems: Array(store.recent))
            }
        }
    }

    private var emptyRecent: some View {
        VStack(spacing: HomeDesign.Spacing.md) {
            ZStack {
                Circle()
                    .fill(HomeDesign.Color.cream200)
                    .frame(width: 56, height: 56)
                Image(systemName: "tray")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(HomeDesign.Color.ink500)
            }
            VStack(spacing: 4) {
                Text("아직 모찌가 없어요")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                Text("위에서 빠르게 메모를 남겨보세요.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(HomeDesign.Color.textMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HomeDesign.Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .fill(HomeDesign.Color.surface.opacity(0.7))
        )
    }

    private func horizontalCardRow(mochiItems: [MochiItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HomeDesign.Spacing.md) {
                ForEach(mochiItems) { mochiItem in
                    RecentMochiCard(mochiItem: mochiItem) {
                        store.send(.mochiItemTapped(mochiItem.id))
                    }
                }
            }
            .padding(.horizontal, HomeDesign.Spacing.xl)
        }
        .padding(.horizontal, -HomeDesign.Spacing.xl)
    }
}

// MARK: - Section header

private struct SectionHeader: View {
    let title: String
    let trailing: String?
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                }
            }
            Spacer()
            if let trailing {
                Button(action: {}) {
                    HStack(spacing: 2) {
                        Text(trailing)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(HomeDesign.Color.textMuted)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(HomeDesign.Color.textMuted.opacity(0.7))
                    }
                }
                .buttonStyle(PressableStyle())
            }
        }
    }
}

// MARK: - Circle icon button

private struct CircleIconButton: View {
    let systemName: String
    let showsBadge: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle()
                            .fill(HomeDesign.Color.surface)
                            .shadow(color: HomeDesign.Color.ink900.opacity(0.05), radius: 6, x: 0, y: 2)
                    )
                    .overlay(Circle().stroke(HomeDesign.Color.border, lineWidth: 1))

                if showsBadge {
                    Circle()
                        .fill(HomeDesign.Color.peach400)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(HomeDesign.Color.surface, lineWidth: 2))
                        .offset(x: -8, y: 6)
                }
            }
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Quick memo field

private struct QuickMemoField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("까먹기 전에 모찌에게 알려주세요")
                    .font(.system(size: 14.5, weight: .regular))
                    .foregroundStyle(HomeDesign.Color.textFaint)
                    .padding(.top, 2)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 14.5, weight: .regular))
                .foregroundStyle(HomeDesign.Color.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 44, maxHeight: 88)
                .padding(.leading, -5)
                .focused(isFocused)
        }
    }
}

// MARK: - Chip button

private struct ChipButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(HomeDesign.Color.surface)
            )
            .overlay(Capsule().stroke(HomeDesign.Color.border, lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Preview

#Preview {
    HomeView(
        store: Store(initialState: HomeFeature.State()) {
            HomeFeature()
        } withDependencies: {
            $0.mochiItemRepository = InMemoryMochiItemRepository()
            $0.dailyImportanceAnalyzer = StubDailyImportanceAnalyzer()
        }
    )
}
