import ComposableArchitecture
import SwiftUI

/// 온보딩 진입 화면 — 4개 페이지를 **NavigationStack push** 로 한 방향 진행.
///
/// **TabView(.page) → NavigationStack 전환 이유**: 스와이프 pager 는 (1) 백탭 미해결 시 스와이프로
/// 단계를 건너뛸 수 있고(거부하면 TabView 내부상태와 `currentPage` 가 desync), (2) 페이지 전환
/// 애니메이션이 뚝뚝 끊겼다. NavigationStack 은 push 가 버튼으로만 일어나 게이트가 자연히
/// 강제되고(스와이프로 건너뛸 surface 자체가 없음), 전환도 네이티브 push 라 매끄럽다.
/// 하단 점 인디케이터는 플로우를 흐리게 해 제거. 디자인 유지를 위해 네비게이션 바는 숨긴다.
///
/// **레이아웃**: 각 페이지 = 배경 그라데이션 + (콘텐츠 + 하단 동적 CTA). 콘텐츠 뷰(`IntroPage`
/// 등)는 일러스트만 담당하고, footer CTA 는 페이지 종류에 따라 본 뷰가 결정한다.
public struct OnboardingView: View {
    @Bindable var store: StoreOf<OnboardingFeature>

    public init(store: StoreOf<OnboardingFeature>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack(path: pathBinding) {
            page(.intro)
                .navigationDestination(for: OnboardingPage.self) { page($0) }
        }
        .tint(OnboardingTheme.primary)
    }

    /// `currentPage`(0-based) ↔ 루트(intro) 뒤에 쌓인 페이지 배열.
    /// 전진은 `nextTapped` 가 `currentPage` 를 올리면 get 이 더 긴 배열을 돌려줘 push 가 일어나고,
    /// 뒤로(엣지 스와이프)는 set 으로 `currentPage` 를 따라 내린다.
    private var pathBinding: Binding<[OnboardingPage]> {
        Binding(
            get: {
                guard store.currentPage > 0 else { return [] }
                return (1...store.currentPage).compactMap(OnboardingPage.init(rawValue:))
            },
            set: { store.send(.pageChanged($0.count)) }
        )
    }

    // MARK: - Page screen (콘텐츠 + footer)

    @ViewBuilder
    private func page(_ spec: OnboardingPage) -> some View {
        ZStack {
            OnboardingTheme.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                content(spec)
                footer(spec)
            }
        }
        // 네비게이션 바는 숨기지 않고 **배경만 투명** — 그라데이션 위에 시스템 뒤로 버튼만
        // 뜬다(push 한 페이지는 자동 제공). 커스텀 뒤로 버튼은 불필요해 제거. 디자인 유지.
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(_ spec: OnboardingPage) -> some View {
        switch spec {
        case .intro:    IntroPage()
        case .backTap:  BackTapPage(store: store)
        case .share:    SharePage()
        case .autoSort: AutoSortPage()
        }
    }

    // MARK: - Footer CTA

    @ViewBuilder
    private func footer(_ spec: OnboardingPage) -> some View {
        Group {
            if spec == .backTap && store.verifyPhase != .detected {
                // 백탭 미해결: 약한 "나중에 할게요" 만. 단계 진행은 카드 내부 버튼이 담당.
                Button("나중에 할게요") {
                    store.send(.skipVerificationTapped)
                }
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(OnboardingTheme.mutedTextColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .accessibilityHint(Text("백탭 설정을 건너뛰고 다음으로 넘어갑니다"))
            } else {
                OnboardingButton(title: spec == .backTap ? "다음" : spec.primaryCTA) {
                    if spec == .backTap {
                        store.send(.backTapStepCompleted)
                    } else {
                        store.send(.nextTapped)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
        .padding(.top, 8)
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
