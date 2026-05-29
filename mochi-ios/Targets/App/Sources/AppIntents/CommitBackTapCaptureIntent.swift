import AppIntents
import CryptoKit
import Foundation
import CoreDomain
import CorePersistence

/// snippet 카드의 "캡쳐" 버튼이 호출하는 background commit intent.
///
/// `openAppWhenRun = false` — 모찌 앱을 깨우지 않고 (외부 앱 컨텍스트 보존) 즉시 commit 한다.
/// 동작 (codex review 반영 — 실패 시 PNG 보존 + invalid captureID 폐기):
///
/// 1. captureID 검증. invalid 면 pending PNG best-effort 폐기 후 종료.
/// 2. `pending-backtap/<captureID>.png` 읽어 sha256 계산
/// 3. 영구 `captures/<captureID>.png` 로 이동 (atomic write)
/// 4. Realm `MochiItem(channel: .screenshot, syncState: .pendingUpload)` upsert
/// 5. **성공 시에만** pending PNG 폐기. 실패 시 PNG 보존 → ``RootFeature.sweepStalePNGs`` 의
///    TTL 이 다음 active 시점에 청소 (데이터 손실 분기 제거).
///
/// **`ProvidesDialog` 로 snippet dismiss 유도** (2026-05-25 회귀 fix): iOS 17 의
/// `ShowsSnippetView` + `Button(intent:)` 조합은 자동 dismiss API 가 없어 ("이 화면 캡쳐"
/// 탭 후 snippet 카드가 그대로 떠 있어 사용자가 "아무 일도 안 일어남" 으로 인식). 반환 타입에
/// `ProvidesDialog` 를 추가하면 시스템이 결과 dialog 를 띄우며 snippet 카드를 갈음한다 —
/// 사용자에게 결과를 알리면서 외부 앱 컨텍스트를 다시 노출. iOS 18+ 의 `SnippetIntent` /
/// `dismissesIntent` API 가 정식 해법이지만 deployment target = 17.0 이라 ProvidesDialog
/// 를 차선책으로 채택.
///
/// **백엔드 ingest 는 의도적으로 안 한다**. snippet 흐름은 `openAppWhenRun = false` 라
/// background process 에서 실행될 수 있고, 그 시점에는 ``AppDependencies.bootstrap()`` 가
/// 호출되지 않아 `@Dependency(\.mochiAPIClient)` 와 `AuthCoordinator` 등 인증/네트워크
/// 인프라가 부재한다. Realm 만 직접 열어 `.pendingUpload` 로 박아두면 다음 인증된 active
/// 시점에 ``MochiItemSyncWorker.runOnce()`` 가 ingest 시도 — 이게 모달 흐름의 "백엔드 +
/// 로컬 fallback" 과 정합. 사용자가 즉시 결과를 못 봐도 데이터는 안전.
///
/// **인증 무관 commit**: snippet 시점에 인증 상태를 알 수 없어도 Realm 에 박아둔 `.pendingUpload`
/// 가 다음 인증된 active 시점에 ingest 됨 (`MochiItemSyncWorker` 가 미인증이면 skip).
///
/// **실패 정책**: pre-upsert (File IO / Realm) 실패는 "저장하지 못했어요" dialog 를 띄우고
/// pending PNG 는 보존 → `sweepStalePNGs` 가 청소. dismiss fix 의 부산물로 silent failure
/// 가 가시화됨. ErrorReporter + 상세 alert UI 는 여전히 `docs/TODO.md` §3.4 의 production
/// 직전 작업.
@available(iOS 17.0, *)
public struct CommitBackTapCaptureIntent: AppIntent {
    public static let title: LocalizedStringResource = "모찌 캡쳐 저장"
    public static let description = IntentDescription("snippet 의 캡쳐 버튼이 호출하는 background commit.")
    public static let openAppWhenRun = false
    /// snippet 의 분기 선택 자체는 사용자에게 노출되는 단축어가 아님 (Shortcuts 앱에 숨김).
    public static let isDiscoverable = false

    @Parameter(title: "captureID")
    public var captureID: String

    public init() {}

    public init(captureID: String) {
        self.captureID = captureID
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let pendingURL = AppGroup.pendingBackTapDirectoryURL
            .appendingPathComponent(AppGroup.pendingBackTapPNGFilename(captureID: captureID))

        guard let id = UUID(uuidString: captureID) else {
            // 비정상 입력 — snippet view 가 잘못된 captureID 를 만들었거나 시스템이 mangle 한 경우.
            // pending PNG 가 stale 로 남지 않도록 best-effort delete.
            try? FileManager.default.removeItem(at: pendingURL)
            return .result(dialog: "저장하지 못했어요")
        }

        do {
            try await commitScreenshot(
                pendingURL: pendingURL,
                captureID: id,
                repository: RealmMochiItemRepository()
            )
            // 성공 — pending PNG 폐기.
            try? FileManager.default.removeItem(at: pendingURL)
            return .result(dialog: "모찌에 저장됐어요")
        } catch {
            // 실패 — pending PNG 보존. sweepStalePNGs 의 TTL 이 다음 active 시점에 청소.
            return .result(dialog: "저장하지 못했어요")
        }
    }
}

/// pending PNG → 영구 `captures/` 이동 + Realm MochiItem `.pendingUpload` 저장.
/// 백엔드 ingest 는 안 한다 — `MochiItemSyncWorker` 가 다음 active 시점에 시도.
private func commitScreenshot(
    pendingURL: URL,
    captureID: UUID,
    repository: any MochiItemRepository
) async throws {
    let data = try Data(contentsOf: pendingURL)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

    let filename = "\(captureID.uuidString).png"
    let permanent = AppGroup.capturedImagesDirectoryURL.appendingPathComponent(filename)
    try data.write(to: permanent, options: [.atomic])

    let ref = ImageRef(
        relativePath: "captures/\(filename)",
        mimeType: "image/png",
        byteSize: data.count,
        sha256: digest,
        objectKey: nil
    )
    let source = IngestSource(
        id: captureID,
        channel: .screenshot,
        imageRefs: [ref]
    )
    // pendingUpload 상태로 저장 — MochiItemSyncWorker 가 다음 tick 에 ingest.
    try await repository.upsert(MochiItem(source: source))
}
