import ComposableArchitecture
import FeatureAuth
import FeatureCapture
import FeatureInbox
import FeatureSearch
import FeatureSettings
import SwiftUI

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
    }

    /// 부팅 직후 Keychain 로딩이 끝나기 전에 잠깐 보이는 빈 화면.
    /// SplashView 가 위에서 덮고 있는 게 일반적이라 사용자는 거의 보지 않는다.
    private var resolvingPlaceholder: some View {
        Color.white.opacity(0.0001)  // ZStack 안에서 빈 자리 채움
            .ignoresSafeArea()
    }
}

/// 메인 탭 UI.
struct MainTabView: View {
    @Bindable var store: StoreOf<MainTabFeature>

    var body: some View {
        TabView(selection: $store.selectedTab.sending(\.tabSelected)) {
            NavigationStack {
                InboxView(store: store.scope(state: \.inbox, action: \.inbox))
            }
            .tabItem { Label("받은 기록", systemImage: "tray.full") }
            .tag(MainTabFeature.Tab.inbox)

            NavigationStack {
                SearchView(store: store.scope(state: \.search, action: \.search))
            }
            .tabItem { Label("검색", systemImage: "magnifyingglass") }
            .tag(MainTabFeature.Tab.search)

            NavigationStack {
                SettingsView(store: store.scope(state: \.settings, action: \.settings))
            }
            .tabItem { Label("설정", systemImage: "gear") }
            .tag(MainTabFeature.Tab.settings)
        }
    }
}
