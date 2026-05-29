import ComposableArchitecture
import FeatureAuth
import FeatureDetail
import FeatureMochiItem
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

/// 메인 탭 UI — iOS 기본 `TabView` 4탭 (홈/채팅/일정/검색).
struct MainTabView: View {
    @Bindable var store: StoreOf<MainTabFeature>

    var body: some View {
        TabView(selection: $store.selectedTab.sending(\.tabSelected)) {
            HomeView(store: store.scope(state: \.home, action: \.home))
                .tabItem { Label("홈", systemImage: "house.fill") }
                .tag(MainTabFeature.Tab.home)

            ComingSoonPlaceholder(
                icon: "message",
                title: "곧 만나요, 채팅",
                subtitle: "모찌랑 대화로 정리하는 기능을 준비 중이에요."
            )
            .tabItem { Label("채팅", systemImage: "message") }
            .tag(MainTabFeature.Tab.chat)

            ComingSoonPlaceholder(
                icon: "calendar",
                title: "곧 만나요, 일정",
                subtitle: "캘린더에 동기화된 일정을 한눈에 볼 수 있게 준비 중이에요."
            )
            .tabItem { Label("일정", systemImage: "calendar") }
            .tag(MainTabFeature.Tab.schedule)

            NavigationStack {
                SearchView(store: store.scope(state: \.search, action: \.search))
            }
            .tabItem { Label("검색", systemImage: "magnifyingglass") }
            .tag(MainTabFeature.Tab.search)
        }
        // 홈·받은기록 카드 탭 → 상세. MainTabFeature 가 .detail 을 세팅하면 sheet 로 표시.
        .sheet(item: $store.scope(state: \.detail, action: \.detail)) { detailStore in
            NavigationStack {
                DetailView(store: detailStore)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("닫기") { store.send(.detail(.dismiss)) }
                        }
                    }
            }
        }
        .sheet(isPresented: $store.isSettingsPresented.sending(\.settingsSheetChanged)) {
            NavigationStack {
                SettingsView(store: store.scope(state: \.settings, action: \.settings))
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("닫기") { store.send(.settingsSheetChanged(false)) }
                        }
                        ToolbarItem(placement: .topBarLeading) {
                            // dev-only: 받은 기록 디버그 진입점.
                            Button {
                                store.send(.debugInboxChanged(true))
                            } label: {
                                Label("받은 기록", systemImage: "tray.full")
                            }
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
        }
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
