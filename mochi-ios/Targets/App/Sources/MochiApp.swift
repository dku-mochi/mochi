import SwiftUI
import ComposableArchitecture
import Dependencies
import CoreAuth
import CoreNetworking
import CorePersistence
import FeatureOnboarding

@main
struct MochiApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(MochiAppDelegate.self) private var appDelegate

    static let rootStore: StoreOf<RootFeature> =
        Store(initialState: RootFeature.State()) { RootFeature() }

    private let inboundConsumer: InboundQueueConsumer
    private let syncWorker: MochiItemSyncWorker

    init() {
        // **순서 중요**: bootstrap 을 먼저 호출해 라이브 DI 값들을 prepareDependencies 로 등록한 뒤
        // syncWorker 등 init-time consumer 가 그 값을 읽도록 한다.
        // rootStore lazy 평가가 뒤늦게 호출되면 syncWorker 가 NotConfiguredAPIClient 를 잡는 race 가 발생한다.
        AppDependencies.bootstrap()
        _ = RealmStoreFactory.makeConfiguration()
        let repository = RealmMochiItemRepository()
        self.inboundConsumer = InboundQueueConsumer(repository: repository)
        let api = DependencyValues._current.mochiAPIClient
        // tokenProvider = AuthCoordinator (이미 AuthTokenProvider 도 구현). bootstrap 이 등록 보장.
        // 미인증 시 worker 는 즉시 skip — 무인증 ingest 가 `.syncFailed` 영구 strand 를 만들지 않도록.
        let tokenProvider: any AuthTokenProvider = AppDependencies.liveAuthCoordinator!
        self.syncWorker = MochiItemSyncWorker(
            repository: repository,
            apiClient: api,
            tokenProvider: tokenProvider
        )

        // Feature 레이어 (InboxFeature·HomeFeature) 가 pull-to-refresh / quick memo 저장 시 즉시 sync 를
        // 트리거할 수 있게 노출. 또한 MochiItemSyncWorker 가 multipart 분류 흐름에서 Live Activity 를
        // trigger 하도록 coordinator 주입.
        prepareDependencies {
            $0.syncTrigger = self.syncWorker
            $0.liveActivityCoordinator = LiveActivityCoordinatorLive()
        }

        // 2026-05-27: mock prototype 폐기. 실 분류 흐름이 `MochiItemSyncWorker.uploadOne` 안에서
        // `LiveActivityCoordinator` 를 통해 직접 trigger 한다 — 백탭 → ShareExt → 저장 → 모찌 active →
        // multipart 호출 시작 시 `.analyzing` Activity, 응답 도착 시 `.ready(candidates)` update.
        // (이전 호출: `MockUseCaseNotificationPrototype.scheduleAfterLaunch()` — `#if DEBUG` 가드로.)
    }

    var body: some Scene {
        WindowGroup {
            AppRootContainer(rootStore: Self.rootStore)
                .task {
                    await tick()
                    await syncWorker.startForegroundPolling()
                    appDelegate.requestAuthorizationIfNeeded()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task {
                            await tick()
                            await syncWorker.startForegroundPolling()
                        }
                        appDelegate.requestAuthorizationIfNeeded()
                    } else {
                        // background/inactive 진입 시 metadata-only 폴링 중단 (foreground 한정).
                        Task { await syncWorker.stopForegroundPolling() }
                    }
                }
                // Google Sign In 콜백 URL 처리 — Info.plist 에 등록한 reversed client ID 로 돌아온다.
                .onOpenURL { url in
                    Task { @MainActor in
                        AppDependencies.liveAuthCoordinator.map { _ in }
                        // GoogleSignIn 8.x 는 sharedInstance().handle(url) 로 직접 처리.
                        // LiveGoogleAuthClient 의 handle(url:) 을 통해 위임.
                        _ = LiveGoogleAuthClient().handle(url: url)
                    }
                }
        }
    }

    private func tick() async {
        _ = await inboundConsumer.drain()
        await syncWorker.runOnce()
    }
}

/// 스플래시를 짧게 노출한 뒤 메인 `RootView` 로 페이드 전환하는 최상위 컨테이너.
/// `UILaunchScreen` 이 비어 있어 시스템은 흰 화면만 잠깐 보여주므로,
/// 브랜딩은 여기서 일관되게 처리한다.
///
/// **DEBUG 빌드 임시 경로**: 서버 미배포 상태에서 로그인 흐름을 우회하고 온보딩만
/// 작업할 수 있도록 ``OnboardingView`` 를 먼저 노출한다. 온보딩 완료
/// (`OnboardingFeature.Action.Delegate.finished`) 시 정상 ``RootView`` 로 페이드.
/// Release 빌드는 기존 흐름 그대로 (스플래시 → RootView).
private struct AppRootContainer: View {
    let rootStore: StoreOf<RootFeature>

    @State private var isSplashVisible = true

    #if DEBUG
    /// DEBUG 에서 온보딩 노출 → 완료 시 true 로 전환되면 RootView 로 자연스럽게 양보.
    @State private var isOnboardingComplete = false
    private let onboardingStore: StoreOf<OnboardingFeature> =
        Store(initialState: OnboardingFeature.State()) { OnboardingFeature() }
    #else
    private let isOnboardingComplete = true
    #endif

    private static let splashDuration: Duration = .milliseconds(1600)

    var body: some View {
        ZStack {
            mainContent
                .opacity(isSplashVisible ? 0 : 1)

            if isSplashVisible {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            try? await Task.sleep(for: Self.splashDuration)
            withAnimation(.easeInOut(duration: 0.4)) {
                isSplashVisible = false
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        #if DEBUG
        if isOnboardingComplete {
            RootView(store: rootStore)
                .transition(.opacity)
        } else {
            OnboardingView(store: onboardingStore)
                .transition(.opacity)
                .onChange(of: onboardingStore.isFinished) { _, finished in
                    guard finished else { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        isOnboardingComplete = true
                    }
                }
        }
        #else
        RootView(store: rootStore)
        #endif
    }
}
