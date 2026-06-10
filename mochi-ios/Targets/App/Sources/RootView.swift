import ComposableArchitecture
import DesignSystem
import FeatureAuth
import FeatureDetail
import FeatureMochiItem
import FeatureInbox
import FeatureOnboarding
import FeatureSearch
import FeatureSettings
import SwiftUI
import UIKit

/// 인증 단계에 따라 ``LoginView`` 또는 메인 ``MainTabView`` 를 노출하는 분기.
///
/// 추가로 ``BackTapModalFeature`` 가 활성화되면 fullScreenCover 로 풀스크린 모달을 띄운다 —
/// 백탭 snippet 의 메모 분기에서 ``OpenBackTapMemoIntent`` 가 marker 를 stash 한 뒤 모찌를
/// foreground 로 깨운 직후 ``RootFeature`` 가 발사.
struct RootView: View {
    @Bindable var store: StoreOf<RootFeature>
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch store.phase {
            case .resolving:
                resolvingPlaceholder
            case .unauthenticated:
                LoginView(store: store.scope(state: \.login, action: \.login))
                    .transition(.opacity)
            case .authenticated:
                MainTabView(store: store.scope(state: \.main, action: \.main))
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.phase)
        .task { store.send(.appLaunched) }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                store.send(.appBecameActive)
            }
        }
        .fullScreenCover(
            item: $store.scope(state: \.backTapModal, action: \.backTapModal)
        ) { backTapStore in
            BackTapModalView(store: backTapStore)
                // memo marker 폐기 invariant 을 깨는 system-driven dismiss 차단.
                // 사용자 의도 종료는 모달 내부의 "취소" 또는 memoSaveFinished delegate.
                .interactiveDismissDisabled(true)
        }
        .fullScreenCover(
            item: $store.scope(state: \.onboarding, action: \.onboarding)
        ) { onboardingStore in
            OnboardingView(store: onboardingStore)
        }
    }

    /// 부팅 직후 Keychain 로딩이 끝나기 전에 잠깐 보이는 빈 화면.
    /// SplashView 가 위에서 덮고 있는 게 일반적이라 사용자는 거의 보지 않는다.
    private var resolvingPlaceholder: some View {
        Color.white.opacity(0.0001)  // ZStack 안에서 빈 자리 채움
            .ignoresSafeArea()
    }
}

/// 메인 탭 UI — iOS 기본 `TabView` 4탭 (홈/채팅/캘린더/검색).
struct MainTabView: View {
    @Bindable var store: StoreOf<MainTabFeature>

    init(store: StoreOf<MainTabFeature>) {
        self._store = Bindable(wrappedValue: store)
        Self.configureTabBarAppearance()
        Self.configureNavigationBarAppearance()
    }

    var body: some View {
        // 탭바를 바깥 단일 NavigationStack 안의 TabView 로 둬, 상세 push 시 탭바를 포함한
        // 전체가 함께 슬라이드(아웃)되게 한다(UIKit hidesBottomBarWhenPushed 와 동일한 자연스러운 전환).
        NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
            TabView(selection: $store.selectedTab.sending(\.tabSelected)) {
                HomeView(store: store.scope(state: \.home, action: \.home))
                    .tabItem { Label("홈", image: "tab_home") }
                    .tag(MainTabFeature.Tab.home)

                MochiCalendarView(store: store.scope(state: \.mochiCalendar, action: \.mochiCalendar))
                    .tabItem { Label("캘린더", image: "tab_mochis") }
                    .tag(MainTabFeature.Tab.mochis)

                ComingSoonPlaceholder(
                    icon: "message",
                    title: "곧 만나요, 채팅",
                    subtitle: "모찌랑 대화로 정리하는 기능을 준비 중이에요."
                )
                .tabItem { Label("채팅", image: "tab_chat") }
                .tag(MainTabFeature.Tab.chat)

                SearchView(store: store.scope(state: \.search, action: \.search))
                    .background(
                        TabBarReselect {
                            // 키보드 내려가게 + state reset.
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                            )
                            store.send(.searchTabReselected)
                        }
                    )
                    .tabItem { Label("검색", image: "tab_search") }
                    .tag(MainTabFeature.Tab.search)
            }
            // 선택 탭 = 모찌 퍼플(MochiTheme.primary). 비선택·배경·레이블 폰트는 configureTabBarAppearance 담당.
            .tint(MochiTheme.Palette.primary)
        } destination: { pathStore in
            switch pathStore.case {
            case let .settings(settingsStore):
                // 설정은 push — back 버튼이 닫기를 대체한다. 받은 기록(디버그)은 설정 화면 위 sheet 로 띄운다.
                SettingsView(store: settingsStore)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            // dev-only: 받은 기록 디버그 진입점.
                            Button {
                                store.send(.debugInboxChanged(true))
                            } label: {
                                Label("받은 기록", systemImage: "tray.full")
                            }
                        }
                    }
                    .sheet(isPresented: $store.isDebugInboxPresented.sending(\.debugInboxChanged)) {
                        NavigationStack {
                            InboxView(store: store.scope(state: \.inbox, action: \.inbox))
                                .toolbar {
                                    ToolbarItem(placement: .topBarTrailing) {
                                        Button("닫기") { store.send(.debugInboxChanged(false)) }
                                    }
                                }
                        }
                    }

            case let .weeklyDigest(digestStore):
                // 이번주 정리 — 설정과 동일하게 push. 항목 탭은 delegate 로 상세 present.
                WeeklyDigestView(store: digestStore)
            }
        }
        // push 화면(설정)의 바 버튼·back tint = 모찌 퍼플.
        // TabView 의 .tint 는 TabView 하위(탭바)에만 닿아 destination 까지 상속되지 않으므로
        // NavigationStack 전체에 한 번 더 걸어 push 화면의 toolbar/back 색을 브랜드 색으로 맞춘다.
        .tint(MochiTheme.Palette.primary)
        // 기록 카드 → 상세: UIKit 커스텀 hero present (path push 아님). 풀스크린이라 탭바를 덮는다.
        .zoomDetailPresentation(
            store: $store.scope(state: \.detail, action: \.detail),
            hero: store.detailHero
        )
    }

    // MARK: - Tab bar appearance

    /// 시스템 `TabView` 의 비선택 색·배경·레이블 폰트를 디자인 시스템에 맞춘다.
    /// 선택 색은 `.tint` 가, 여기선 비선택(textSecondary)·불투명 흰색 배경(라이트 고정)·rounded 레이블을 담당.
    private static func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        // 글래스모피즘(translucent material) 제거 — 불투명 흰색 배경(라이트 고정).
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .white
        // 탭바 상단 1px(1 physical pixel) 회색 hairline 구분선.
        appearance.shadowColor = UIColor(white: 0.82, alpha: 1.0)

        let selected = UIColor(MochiTheme.Palette.primary)
        let normal = UIColor(MochiTheme.Palette.textSecondary)
        let labelFont = roundedSystemFont(ofSize: 10, weight: .semibold)

        // 아이콘 + 레이블 탭바. 레이블 폰트는 rounded·semibold 로 디자인 시스템에 맞춘다.
        let item = UITabBarItemAppearance()
        item.selected.iconColor = selected
        item.selected.titleTextAttributes = [.foregroundColor: selected, .font: labelFont]
        item.normal.iconColor = normal
        item.normal.titleTextAttributes = [.foregroundColor: normal, .font: labelFont]

        appearance.stackedLayoutAppearance = item
        appearance.inlineLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    /// `MochiTheme.Typography` 가 `.rounded` 를 쓰므로 탭 레이블 폰트도 rounded 로 맞춘다.
    private static func roundedSystemFont(ofSize size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    /// 시스템 `NavigationStack` 의 navigation bar 를 디자인 시스템에 맞춘다.
    /// 불투명 흰색(스크롤 내려도 material 블러 없음·라이트 고정) + 하단 hairline/shadow 제거 +
    /// tint(back·바 버튼) = 모찌 퍼플. 상세 화면 흰 배경과 seamless 하게 이어진다.
    private static func configureNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        // 글래스모피즘(translucent material) 제거 — 스크롤 위치와 무관하게 불투명 흰색 유지(블러 없음).
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .white
        // 하단 1px hairline/shadow 제거.
        appearance.shadowColor = .clear

        // standard·scrollEdge·compact 를 모두 같은 외형으로 — 스크롤 내려도 블러로 전환되지 않는다.
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        // back 버튼·바 버튼 색 = 모찌 서비스 색(MochiTheme.primary).
        UINavigationBar.appearance().tintColor = UIColor(MochiTheme.Palette.primary)
    }
}

// MARK: - Placeholder

private struct ComingSoonPlaceholder: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [.purple.opacity(0.15), .purple.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 96, height: 96)
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.purple)
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}
