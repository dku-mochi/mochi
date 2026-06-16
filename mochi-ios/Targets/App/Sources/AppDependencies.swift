import Dependencies
import Foundation
import UIKit
import CoreDomain
import CoreAuth
import CorePersistence
import CoreIntegrations
import CoreNetworking
import CoreAgentClient
import FeatureInbox
import FeatureMochiItem
import FeatureSearch
import FeatureDetail
import FeatureOnboarding

/// 앱 셸이 모든 모듈의 `DependencyKey` 를 한 곳에서 라이브 구현으로 묶는다.
///
/// 환경변수 또는 컴파일 시 설정으로 `MOCHI_API_BASE_URL` 을 지정한다.
/// Debug 기본값 `http://localhost:8000`(시뮬)·LAN host(실기기), Release 기본값은 배포 백엔드(nip.io TLS).
enum AppDependencies {
    /// 부팅 후 라이브 코디네이터 보관소 — Google URL 콜백 처리에 필요.
    nonisolated(unsafe) static var liveAuthCoordinator: AuthCoordinator?

    static func bootstrap() {
        let baseURL = resolveBaseURL()
        // ShareExtension 이 직접 전송 시 baseURL 을 알 수 있도록 App Group 으로 공유한다.
        AppGroup.setSharedAPIBaseURL(baseURL)

        // 1) Auth 인프라
        let tokenStore = KeychainTokenStore()
        let sessionStore = AuthSessionStore(store: tokenStore)
        let authAPI = URLSessionAuthAPIClient(baseURL: baseURL)
        let apple = LiveAppleAuthClient()
        let google = LiveGoogleAuthClient()
        let coordinator = AuthCoordinator(
            store: sessionStore,
            api: authAPI,
            apple: apple,
            google: google,
            // ShareExtension 직접 전송용 capture token — 공유 Keychain item (ShareExt 가 읽는다).
            captureStore: KeychainCaptureTokenStore()
        )
        liveAuthCoordinator = coordinator

        // 2) Mochi API — coordinator 가 AuthTokenProvider 도 겸한다 (자동 access token 주입).
        //    openapi.json 단일 계약에서 생성한 클라이언트(`OpenAPIMochiClient`) 가 라이브 구현.
        let liveAPI = OpenAPIMochiClient(baseURL: baseURL, tokenProvider: coordinator)

        // 캡처 이미지 렌더 폴백 — 로컬에 없는 이미지를 GCS presign 으로 받아 captures/ 에 캐시한다
        //   (LocalThumbnail 렌더 시점 + SyncWorker.pullRemote 공용). 부팅 시 1회 주입.
        Task {
            await CaptureImageStore.shared.configure { objectKey in
                let url = try await liveAPI.presignCaptureDownload(objectKey: objectKey)
                let (data, response) = try await URLSession.shared.data(from: url)
                // 만료 signed URL·403/404 는 XML 에러 본문을 비-200 으로 준다 — 디코드 안 되는 본문을
                // captures/ 에 캐시하면 영구 오염(파일 존재→재다운로드 안 함)되므로 status·디코드 확인 후
                // 실패면 throw(캐시 안 됨, 다음 렌더에 재시도). ScreenshotSaver 와 동일 가드.
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, UIImage(data: data) != nil else {
                    throw URLError(.cannotDecodeContentData)
                }
                return data
            }
        }

        // 3) SSE 라이브 스트림 — foreground 분석 완료를 즉시 받는다(폴링 대체, 끊김 시 폴링 fallback).
        //    인증은 coordinator(AuthTokenProvider) Bearer 재사용, `final` 시 liveAPI 로 GET 재조회.
        let liveStream = LiveAgentStreamClient(
            baseURL: baseURL, tokenProvider: coordinator, apiClient: liveAPI
        )

        prepareDependencies {
            $0.mochiItemRepository = RealmMochiItemRepository()
            $0.mochiAPIClient    = liveAPI
            $0.authCoordinator   = coordinator
            $0.agentStreamClient = liveStream
            // 채팅 탭 live 배선 (2026-06-10 PR-5): 메시지 전송 = raw SSE(POST-as-SSE,
            // 워치독 75초), 세션 목록/스냅샷/삭제 = 생성 클라이언트 어댑터.
            $0.chatStreamClient  = LiveChatStreamClient(baseURL: baseURL, tokenProvider: coordinator)
            $0.chatAPIClient     = OpenAPIChatClient(baseURL: baseURL, tokenProvider: coordinator)
            $0.backTapVerification = .live
        }
    }

    private static func resolveBaseURL() -> URL {
        return URL(string: "https://34-64-104-136.nip.io")!
        if let env = ProcessInfo.processInfo.environment["MOCHI_API_BASE_URL"],
           let url = URL(string: env) {
            return url
        }

        // 2) Debug 빌드: "Inject Dev LAN Host" post-build script 가 박은 Mac LAN IP.
        //    실기기를 같은 Wi-Fi 의 백엔드에 붙일 때 자동으로 192.168.x.x:8000 가 된다.
        #if DEBUG
        if let host = Bundle.main.object(forInfoDictionaryKey: "MOCHI_DEV_HOST") as? String,
           !host.isEmpty,
           let url = URL(string: "http://\(host):8000") {
            return url
        }
        // 3) Debug fallback — 시뮬레이터/Mac 위의 동일 머신용.
        return URL(string: "http://localhost:8000")!
        #else
        // 4) Release(운영) — GCP mochi-svc 배포 백엔드 (nip.io 자동 TLS).
        return URL(string: "https://34-64-104-136.nip.io")!
        #endif
    }
}
 
