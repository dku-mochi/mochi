import SwiftUI
import ComposableArchitecture
import Dependencies
import CoreAuth
import CoreNetworking
import CorePersistence

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
        // 트리거할 수 있게 노출. 또한 MochiItemSyncWorker 가 분류 흐름에서 Live Activity 를 trigger 하도록
        // coordinator 주입 — apiClient/환경은 LA push 토큰을 백엔드에 등록하는 데 쓴다.
        #if DEBUG
        let pushEnvironment: PushEnvironment = .sandbox
        #else
        let pushEnvironment: PushEnvironment = .production
        #endif
        prepareDependencies {
            $0.syncTrigger = self.syncWorker
            $0.liveActivityCoordinator = LiveActivityCoordinatorLive(apiClient: api, environment: pushEnvironment)
        }

        // 실 분류 흐름이 `MochiItemSyncWorker.uploadOne` 안에서 `LiveActivityCoordinator` 를 통해 직접
        // trigger 한다 — 저장 → 모찌 active → ingest 시작 시 `.analyzing` Activity, 분석 완료(SSE/폴링) 시
        // `.ready` update. background 갱신은 ingest 후 등록한 LA push 토큰으로 백엔드가 직접 push.
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
/// Release 빌드는 기존 흐름 그대로 (스플래시 → RootView).
private struct AppRootContainer: View {
    let rootStore: StoreOf<RootFeature>

    @State private var isSplashVisible = true

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
        RootView(store: rootStore)
    }
}
