import SwiftUI
import ComposableArchitecture
import CoreDomain
import CorePersistence
import DesignSystem

/// 모찌 홈 화면 — "자동성의 예외 처리" 인박스 (docs/PRODUCT.md §8.4).
///
/// 위 → 아래:
///  - 빠른 입력(한 줄)          "놓치기 쉬운 순간은 쉽게 남기고"
///  - ① 지금 확인해 주세요        모찌가 혼자 정하기 애매한 것(needsReview)
///  - ② 모찌가 정리하고 있어요     분석 응답 대기(analyzing), 기본 접힘
///  - ③ 질문 진입                회수 탈출구 → 채팅 탭
///  - ④ 최근에 보낸 것들          정리 대상 아닌 안전망(recent)
/// 4-Intent 라벨은 노출하지 않고 행동으로만 드러난다.
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
                    quickInputBar
                    confirmSection
                    processingSection
                    askMochiRow
                    recentSection
                }
                .padding(.horizontal, HomeDesign.Spacing.xl)
                .padding(.top, HomeDesign.Spacing.md)
            }
            .refreshable {
                await store.send(.refresh).finish()
            }
        }
        .background(Color.white.ignoresSafeArea())
        .task { store.send(.onAppear) }
    }

    // MARK: - Background (흰 기조 + 상단 옅은 라벤더 글로우)

    private var backgroundLayer: some View {
        ZStack {
            Color.white

            LinearGradient(
                colors: [
                    HomeDesign.Color.purple200.opacity(0.35),
                    HomeDesign.Color.purple100.opacity(0.12),
                    Color.white.opacity(0.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 240)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Top bar (우측 설정만)

    private var topBar: some View {
        HStack {
            Spacer()
            CircleIconButton(systemName: "gearshape") {
                store.send(.openSettingsTapped)
            }
        }
    }

    // MARK: - 빠른 입력 (한 줄, 탭하면 확장)

    private var quickInputBar: some View {
        HStack(spacing: HomeDesign.Spacing.md) {
            mochiDot(size: 28, glow: 18)

            TextField("까먹기 전에, 빠르게 남겨보세요", text: $store.quickMemoText, axis: .vertical)
                .font(.system(size: 14.5, weight: .regular))
                .foregroundStyle(HomeDesign.Color.textPrimary)
                .lineLimit(1...4)
                .tint(HomeDesign.Color.purple500)
                .focused($quickMemoFocused)

            if canSubmit {
                Button {
                    quickMemoFocused = false
                    store.send(.quickMemoSubmitted)
                } label: {
                    Group {
                        if store.isSaving {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(HomeDesign.Color.purple500))
                }
                .buttonStyle(PressableStyle())
                .disabled(store.isSaving)
            } else {
                HStack(spacing: 4) {
                    InputToolButton(systemName: "link") { store.send(.urlChipTapped) }
                    InputToolButton(systemName: "camera.viewfinder") { store.send(.screenshotChipTapped) }
                }
            }
        }
        .padding(.horizontal, HomeDesign.Spacing.md)
        .padding(.vertical, HomeDesign.Spacing.sm + 2)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .fill(HomeDesign.Color.purple50.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .stroke(HomeDesign.Color.border, lineWidth: 1)
        )
    }

    private var canSubmit: Bool {
        !store.quickMemoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - ① 지금 확인해 주세요 (needsReview)

    private var confirmSection: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            SectionHeader(
                title: "지금 확인해 주세요",
                trailing: store.needsReview.isEmpty ? nil : "전체 보기",
                subtitle: store.needsReview.isEmpty ? nil : "모찌 혼자 정하기 애매한 것만 모았어요"
            )
            if store.needsReview.isEmpty {
                calmEmpty
            } else {
                NeedsReviewCard(
                    mochiItems: Array(store.needsReview),
                    page: $store.needsReviewPage,
                    onClassify: { id, intent in store.send(.classifyTapped(mochiItemID: id, intent: intent)) },
                    onReanalyze: { id, hint in store.send(.reanalyzeTapped(mochiItemID: id, hint: hint)) },
                    onRetry: { id in store.send(.retryAnalysisTapped(id)) }
                )
            }
        }
    }

    /// ① 빈 상태 — "비는 게 정상". 축하·보상 없이 차분하게.
    private var calmEmpty: some View {
        HStack(spacing: HomeDesign.Spacing.md) {
            ZStack {
                Circle().fill(HomeDesign.Color.mint100).frame(width: 38, height: 38)
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.mint400)
            }
            Text("지금은 확인할 게 없어요. 모찌가 알아서 정리하고 있어요.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(HomeDesign.Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HomeDesign.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .fill(HomeDesign.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .stroke(HomeDesign.Color.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    // MARK: - ② 모찌가 정리하고 있어요 (analyzing, 접힘)

    @ViewBuilder
    private var processingSection: some View {
        if !store.analyzing.isEmpty {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                Button {
                    store.send(.toggleProcessing, animation: .spring(response: 0.32, dampingFraction: 0.85))
                } label: {
                    HStack(spacing: HomeDesign.Spacing.sm) {
                        ProgressView().controlSize(.mini)
                        Text("모찌가 정리하고 있어요")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(HomeDesign.Color.textPrimary)
                        Text("\(store.analyzing.count)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HomeDesign.Color.textMuted)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HomeDesign.Color.textMuted)
                            .rotationEffect(.degrees(store.isProcessingExpanded ? 180 : 0))
                    }
                }
                .buttonStyle(.plain)

                if store.isProcessingExpanded {
                    AnalyzingCard(mochiItems: Array(store.analyzing))
                }
            }
        }
    }

    // MARK: - ③ 질문 진입 (회수 탈출구)

    private var askMochiRow: some View {
        Button {
            store.send(.askMochiTapped)
        } label: {
            HStack(spacing: HomeDesign.Spacing.md) {
                mochiDot(size: 34, glow: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("찾는 게 안 떠오르나요?")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                    Text("모찌에게 말로 물어보세요")
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
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

    // MARK: - ④ 최근에 보낸 것들

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            SectionHeader(
                title: "최근에 보낸 것들",
                trailing: store.recent.isEmpty ? nil : "전체 보기",
                subtitle: store.recent.isEmpty ? nil : "언제든 다시 열어보거나 되돌릴 수 있어요"
            )
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
                Text("위에서 빠르게 남겨보세요.")
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

    // MARK: - 모찌 dot (작은 캐릭터 placeholder)

    private func mochiDot(size: CGFloat, glow: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [HomeDesign.Color.purple200, HomeDesign.Color.purple500],
                    center: .init(x: 0.35, y: 0.3),
                    startRadius: 1,
                    endRadius: glow
                )
            )
            .frame(width: size, height: size)
            .shadow(color: HomeDesign.Color.purple500.opacity(0.3), radius: 4, x: 0, y: 2)
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Input tool button (빠른 입력 바의 링크·스크린샷 진입)

private struct InputToolButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HomeDesign.Color.textMuted)
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(HomeDesign.Color.surface)
                )
                .overlay(Circle().stroke(HomeDesign.Color.border, lineWidth: 1))
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
        }
    )
}
