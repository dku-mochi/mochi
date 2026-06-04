import Foundation

/// App, ShareExtension이 공유하는 App Group 식별자와 컨테이너 URL.
///
/// AppIntents (`QuickCaptureIntent` / `CaptureScreenshotIntent`) 는 메인 App 타겟 안에 있으므로
/// App.entitlements 의 App Group 을 그대로 사용한다 — 별도 entitlements 불필요.
///
/// 동일 식별자가 다음 파일들에 박혀 있어야 한다:
/// - Targets/App/Support/App.entitlements
/// - Targets/ShareExtension/Support/ShareExtension.entitlements
public enum AppGroup {
    public static let identifier = "group.app.mochi"

    public static var containerURL: URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            assertionFailure("App Group container 접근 실패 — entitlements를 확인하세요: \(identifier)")
            return FileManager.default.temporaryDirectory
        }
        return url
    }

    public static var realmFileURL: URL {
        containerURL.appendingPathComponent("mochi.realm")
    }

    public static var capturedImagesDirectoryURL: URL {
        let url = containerURL.appendingPathComponent("captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// ShareExtension이 데이터를 즉시 메인 앱과 공유할 수 없을 때 사용하는 inbound 큐.
    public static var inboundQueueURL: URL {
        let url = containerURL.appendingPathComponent("inbound-queue", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 백탭 단축어가 `CaptureScreenshotIntent` 를 통해 떨군 임시 스크린샷 + 메모 marker.
    ///
    /// `inboundQueueURL` 과 의도가 다르다 — inbound 큐는 "이미 사용자가 저장 결정을 내린 캡처" 의
    /// 4-Intent 분석 대기열인 반면, 이곳은 백탭 snippet 흐름이 사용하는 단명 stash 다.
    ///
    /// **파일 종류 두 가지** (snippet 분기에 의해 결정됨):
    /// - `<captureID>.png` — `CaptureScreenshotIntent.perform()` 가 떨군 원본 스크린샷.
    ///   `CommitBackTapCaptureIntent` (캡쳐 분기) 가 영구 `captures/` 로 promote 후 폐기, 또는
    ///   `OpenBackTapMemoIntent` (메모 분기) 가 즉시 폐기.
    /// - `<captureID>.memo` — 메모 분기 시 `OpenBackTapMemoIntent` 가 떨구는 marker.
    ///   ``RootFeature`` 가 foreground 진입 시 발견하면 ``BackTapModalFeature`` 를 메모 phase 로 띄움.
    ///   모달 종료 시 폐기.
    ///
    /// snippet 이 시스템에 의해 dismiss (사용자 외부 탭 / timeout) 되면 두 commit intent 중
    /// 어느 것도 실행되지 않아 잔재가 남는다. ``RootFeature`` 가 launch / scenePhase active 시점에
    /// stale `.png` 를 모두 폐기 + `.memo` 가 있으면 가장 최근 한 장만 promote 한다.
    public static var pendingBackTapDirectoryURL: URL {
        let url = containerURL.appendingPathComponent("pending-backtap", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 백탭 snippet 의 PNG 파일명 컨벤션. `CaptureScreenshotIntent` 가 만들고
    /// `CommitBackTapCaptureIntent` / `OpenBackTapMemoIntent` 가 동일 captureID 로 복원한다.
    public static func pendingBackTapPNGFilename(captureID: String) -> String {
        "\(captureID).png"
    }

    /// 백탭 메모 marker 파일명 컨벤션. `OpenBackTapMemoIntent` 가 만들고
    /// ``RootFeature`` 가 발견 시 captureID 를 추출해 ``BackTapModalFeature`` 에 넘긴다.
    public static func pendingBackTapMemoFilename(captureID: String) -> String {
        "\(captureID).memo"
    }
}
