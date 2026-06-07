import AppIntents
import Foundation
import SwiftUI
import CorePersistence

/// 백탭 단축어가 `Take Screenshot → 이미지 변환(PNG) → 모찌 화면 캡쳐` 로 호출하는 App Intent.
///
/// **흐름 (2026-05-24 snippet 회귀)**: Papago 가 쓰는 `ShowsSnippetView` 패턴을 차용해
/// **외부 앱 컨텍스트를 보존한 채** 모찌 snippet 카드를 그 위에 띄운다. 이전의 모달 흐름은
/// 모찌 앱이 foreground 로 떠올라오면서 YouTube 같은 외부 앱이 사라지는 UX 문제가 있었다.
///
/// `openAppWhenRun = false` 로 모찌 앱을 깨우지 않고, 다음을 한다:
///
/// 1. 받은 이미지를 `pending-backtap/<captureID>.png` 에 stash (captureID = UUID)
/// 2. `BackTapSnippetView` 를 시스템 snippet 카드로 표시 — 외부 앱 위에 떠오름
///
/// snippet 카드의 두 버튼이 그 다음을 결정한다:
/// - **캡쳐** → ``CommitBackTapCaptureIntent`` — `openAppWhenRun = false` 로 background
///   commit (pending → captures/ 이동 + Realm MochiItem upsert + 백엔드 ingest 시도). 외부 앱
///   계속 보임.
/// - **메모** → ``OpenBackTapMemoIntent`` — `openAppWhenRun = true` 로 모찌 진입 (textarea
///   필요). pending PNG 폐기 + `.memo` marker stash. ``RootFeature`` 가 marker 발견 시
///   ``BackTapModalFeature`` (메모 phase) 표시.
///
/// **stash 시점의 sha256 계산은 의도적으로 생략한다** — 캡쳐 분기가 결정되는 순간
/// 비로소 의미가 있다 (메모/dismiss 시 낭비). `CommitBackTapCaptureIntent` 가 그 시점에 계산.
///
/// 외부 앱에서의 의식적 공유 (Safari → Share → 모찌) 는 별도 ``ShareExtension`` 경로다 —
/// `ShareEntryView` 모달에서 즉시 메모 입력 기회 제공. 두 surface 는 의도가 달라 분리.
@available(iOS 17.0, *)
public struct CaptureScreenshotIntent: AppIntent {
    public static let title: LocalizedStringResource = "모찌 화면 캡쳐"
    public static let description = IntentDescription("백탭 단축어로 받은 스크린샷을 모찌 snippet 으로 띄웁니다.")
    /// snippet 카드를 외부 앱 위에 띄우는 것이 핵심 — 모찌 앱을 깨우면 컨텍스트가 사라진다.
    public static let openAppWhenRun = false

    @Parameter(title: "이미지", supportedTypeIdentifiers: ["public.image"])
    public var image: IntentFile

    public init() {}

    public func perform() async throws -> some IntentResult & ShowsSnippetView {
        // 온보딩 백탭 검증 모드: 백탭이 여기까지 도달했다는 사실만 기록하고, 진짜 캡처는
        // 만들지 않는다. 검증용 백탭이 쓰레기 스크린샷 `MochiItem` 을 저장하면 사용자에게
        // 잘못된 행동을 가르치고 메모리를 오염시킨다 (codex P1). 두 분기는 반환 view 타입이
        // 같아야 opaque 반환이 성립하므로 `BackTapResultSnippet` wrapper 로 통일한다 —
        // `AnyView` 로 감싸면 시스템이 snippet 으로 렌더링하지 못한다.
        if AppGroup.isBackTapVerificationActive {
            AppGroup.markBackTapVerificationHit()
            return .result(view: BackTapResultSnippet(kind: .verified))
        }

        let data = image.data
        guard data.count <= Self.maxImageBytes else {
            throw CaptureScreenshotIntentError.imageTooLarge(data.count)
        }

        // captureID 가 곧 ``MochiItem.id`` · 백엔드 capture id · idempotency key 의 base 가 된다 —
        // snippet 의 캡쳐 분기 (`CommitBackTapCaptureIntent`) 가 동일 ID 로 Realm upsert 한다.
        // 메모 분기는 새 UUID 발급 (P1 #3 invariant).
        let captureID = UUID().uuidString
        let filename = AppGroup.pendingBackTapPNGFilename(captureID: captureID)
        let destination = AppGroup.pendingBackTapDirectoryURL.appendingPathComponent(filename)
        try data.write(to: destination, options: [.atomic])

        return .result(view: BackTapResultSnippet(kind: .capture(captureID: captureID)))
    }

    private static let maxImageBytes = 20 * 1024 * 1024
}

enum CaptureScreenshotIntentError: Error, CustomLocalizedStringResourceConvertible {
    case imageTooLarge(Int)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .imageTooLarge(let bytes):
            "이미지가 너무 큽니다 (\(bytes / 1024 / 1024)MB, 한도 20MB)"
        }
    }
}
