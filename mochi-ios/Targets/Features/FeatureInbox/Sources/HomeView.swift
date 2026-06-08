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
///  - ③ 최근에 보낸 것들          정리 대상 아닌 안전망(recent)
/// 4-Intent 라벨은 노출하지 않고 행동으로만 드러난다.
/// 자연어 회수(질문)는 홈에 진입점을 두지 않고 채팅·검색 탭이 담당한다.
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
        // 홈 토큰(HomeDesign)이 light 하드코딩이라 다크모드에선 배경만 흰색이고
        // 시스템 placeholder/텍스트색이 어긋나 안 보인다 → 홈은 light 로 고정한다.
        .preferredColorScheme(.light)
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

    // MARK: - Top bar (좌측 워드마크 + 우측 설정)

    private var topBar: some View {
        HStack(spacing: 2) {
            Text("mochi")
                .font(.system(size: 22, weight: .heavy))
                .tracking(-0.8)
                .foregroundStyle(HomeDesign.Color.purple500)
            Spacer()
            CircleIconButton(systemName: "gearshape") {
                store.send(.openSettingsTapped)
            }
        }
    }

    // MARK: - 빠른 입력 (한 줄, 탭하면 확장)

    private var quickInputBar: some View {
        HStack(spacing: HomeDesign.Spacing.md) {
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
        .padding(.vertical, HomeDesign.Spacing.sm + 3)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .fill(HomeDesign.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .stroke(HomeDesign.Color.border, lineWidth: 1)
        )
        // 상단 라벤더 글로우에 묻히지 않게 흰 작업바를 살짝 띄운다.
        .shadow(color: HomeDesign.Color.ink900.opacity(0.05), radius: 10, x: 0, y: 3)
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

    /// ① 빈 상태 — "비는 게 정상". 축하·보상 없이 차분한 상태 패널.
    /// 홈의 기본 화면이므로 비어 있어도 가장 큰 비중을 갖되, 행동을 요구하지 않는다.
    private var calmEmpty: some View {
        VStack(spacing: HomeDesign.Spacing.md) {
            ZStack {
                Circle().fill(HomeDesign.Color.mint100).frame(width: 50, height: 50)
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.mint400)
            }
            VStack(spacing: 5) {
                Text("지금은 확인할 게 없어요")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                Text("모찌가 새로 보낸 기억을 조용히 정리하고 있어요")
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HomeDesign.Spacing.xxl + 6)
        .padding(.horizontal, HomeDesign.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .fill(HomeDesign.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .stroke(HomeDesign.Color.border, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
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

    // MARK: - ③ 최근에 보낸 것들

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
            // 카드 그림자가 스크롤 영역 상·하단에서 잘리지 않게 세로 여백 확보.
            .padding(.vertical, HomeDesign.Spacing.sm)
        }
        .padding(.horizontal, -HomeDesign.Spacing.xl)
        .padding(.vertical, -HomeDesign.Spacing.sm)
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
