import ComposableArchitecture
import SwiftUI

/// 온보딩 진입 화면 — 4개 페이지를 TabView 로 가로 스와이프.
///
/// **레이아웃**:
/// - 배경: 그라데이션 (LoginView 와 동일)
/// - 페이지: TabView (PageStyle, 시스템 인디케이터는 끄고 커스텀 ``PageIndicator`` 사용)
/// - 하단 푸터: 인디케이터 + primary CTA
///
/// **CTA 동작**:
/// - 일반 페이지: `nextTapped` → 다음 페이지로
/// - 마지막 페이지: `nextTapped` → ``OnboardingFeature.Action.Delegate.finished``
/// - 백탭 페이지: `registerShortcutTapped` → `shortcuts://` 오픈
public struct OnboardingView: View {
    @Bindable var store: StoreOf<OnboardingFeature>
    @Environment(\.openURL) private var openURL

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
        // Delegate.openShortcutsApp 수신 → 실제 URL 오픈은 View 책임.
        // (Reducer 에서 UIApplication 직접 접근하면 effect 테스트가 깨진다.)
        .onChange(of: store.currentPage) { _, _ in /* 페이지 전환 시 향후 추가 effect 자리 */ }
    }

    // MARK: - Pager

    private var pager: some View {
        TabView(selection: pageBinding) {
            IntroPage()       .tag(0)
            BackTapPage()     .tag(1)
            SharePage()       .tag(2)
            AutoSortPage()    .tag(3)
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

            OnboardingButton(title: store.currentSpec.primaryCTA) {
                handlePrimaryTap()
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
        .padding(.top, 8)
    }

    private func handlePrimaryTap() {
        switch store.currentSpec {
        case .backTap:
            store.send(.registerShortcutTapped)
            // Delegate 가 발행되는 즉시 shortcuts:// 를 연다. 단축어 등록 후 사용자가
            // 다시 돌아오면 그 다음 페이지로 자연스럽게 진행시킨다.
            if let url = URL(string: "shortcuts://") {
                openURL(url) { _ in
                    // openURL 콜백은 메인 스레드 보장. 성공/실패 무관하게 다음 페이지로.
                    store.send(.nextTapped)
                }
            } else {
                store.send(.nextTapped)
            }
        default:
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
