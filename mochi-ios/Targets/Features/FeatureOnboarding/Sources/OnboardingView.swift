import ComposableArchitecture
import SwiftUI

/// 온보딩 진입 화면 — 4개 페이지를 TabView 로 가로 스와이프.
///
/// **레이아웃**:
/// - 배경: 그라데이션 (LoginView 와 동일)
/// - 페이지: TabView (PageStyle, 시스템 인디케이터는 끄고 커스텀 ``PageIndicator`` 사용)
/// - 하단 푸터: 인디케이터 + 동적 CTA
///
/// **CTA 동작**:
/// - 일반 페이지: `nextTapped` → 다음 / 마지막 페이지면 `delegate(.finished)`
/// - 백탭 페이지: 단계 진행(추가/연결/검증)은 ``BackTapPage`` 내부 버튼이 담당하고,
///   footer 는 검증 성공 시 "다음"(`backTapStepCompleted`), 그 전엔 "나중에 할게요"(skip)만 보인다.
public struct OnboardingView: View {
    @Bindable var store: StoreOf<OnboardingFeature>

    public init(store: StoreOf<OnboardingFeature>) {
        self.store = store
    }

    public var body: some View {
        ZStack {
            OnboardingTheme.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                pager
                footer
            }
        }
    }

    // MARK: - Pager

    private var pager: some View {
        TabView(selection: pageBinding) {
            IntroPage()                 .tag(0)
            BackTapPage(store: store)   .tag(1)
            SharePage()                 .tag(2)
            AutoSortPage()              .tag(3)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .indexViewStyle(.page(backgroundDisplayMode: .never))
        .animation(.easeInOut(duration: 0.25), value: store.currentPage)
    }

    private var pageBinding: Binding<Int> {
        Binding(
            get: { store.currentPage },
            set: { store.send(.pageChanged($0)) }
        )
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 24) {
            PageIndicator(
                current: store.currentPage,
                visibleCount: OnboardingPage.allCases.count,
                total: OnboardingPage.totalSteps
            )

            footerCTA
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var footerCTA: some View {
        if store.currentSpec == .backTap && store.verifyPhase != .detected {
            // 백탭 미해결: footer 는 약한 "나중에 할게요" 만. 단계 진행은 카드 내부 버튼이 담당.
            Button("나중에 할게요") {
                store.send(.skipVerificationTapped)
            }
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(OnboardingTheme.mutedTextColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .accessibilityHint(Text("백탭 설정을 건너뛰고 다음으로 넘어갑니다"))
        } else {
            OnboardingButton(title: footerTitle) {
                handlePrimaryTap()
            }
        }
    }

    private var footerTitle: String {
        // 백탭 페이지에서 이 분기에 오는 경우는 검증 성공(.detected) 뿐 → "다음".
        store.currentSpec == .backTap ? "다음" : store.currentSpec.primaryCTA
    }

    private func handlePrimaryTap() {
        if store.currentSpec == .backTap {
            store.send(.backTapStepCompleted)
        } else {
            store.send(.nextTapped)
        }
    }
}

#if DEBUG
#Preview {
    OnboardingView(
        store: Store(initialState: OnboardingFeature.State()) {
            OnboardingFeature()
        }
    )
}
#endif
