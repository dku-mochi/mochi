import AppIntents
import Foundation
import CorePersistence

/// snippet 카드의 "메모" 버튼이 호출하는 foreground entry intent.
///
/// `openAppWhenRun = true` — 메모는 textarea 입력이 필요하므로 모찌 앱을 깨운다 (snippet 영역
/// 안에서 키보드 입력은 어렵고, 메모 분기는 사용자가 이미 외부 앱 컨텍스트를 떠나기로 결정한 것).
///
/// 동작 (codex review 반영 — marker-first 순서 + 새 captureID):
///
/// 1. **새 captureID 발급** — snippet 의 `screenshotCaptureID` 는 캡쳐 분기에만 의미. 메모는 의미상
///    *다른* capture (channel 도 `.appDirectInput` 으로 달라짐). 같은 ID 를 재사용하면 Realm
///    primary key 가 충돌하여 `update: .modified` 가 screenshot row 를 silent overwrite 함.
/// 2. `pending-backtap/<memoCaptureID>.memo` marker 파일 stash. 실패 시 PNG 도 그대로 두고 종료
///    (사용자 의도 흔적 유지).
/// 3. marker write 성공 확인 후 `pending-backtap/<screenshotCaptureID>.png` 폐기. 메모 분기는
///    스크린샷 의도가 아님을 사용자가 명시했으므로 PNG 보존 가치 없음.
/// 4. `openAppWhenRun = true` 가 모찌를 foreground 로 띄움.
/// 5. ``RootFeature`` 가 `.appBecameActive` 시점에 marker 발견 → ``BackTapModalFeature`` 를
///    메모 phase 로 표시 (memoCaptureID 사용).
/// 6. 모달이 commit / cancel 어느 분기든 marker 폐기 (invariant).
///
/// **인증 무관 진입**: 미인증이면 ``RootFeature`` 가 LoginView 를 띄움. marker 는 보존되며
/// 로그인 후 다음 active 시점에 모달이 떠옴 — modal 흐름과 동일한 대기 정책.
@available(iOS 17.0, *)
public struct OpenBackTapMemoIntent: AppIntent {
    public static let title: LocalizedStringResource = "모찌 메모 입력"
    public static let description = IntentDescription("snippet 의 메모 버튼이 호출. 모찌를 띄워 textarea 입력을 받습니다.")
    public static let openAppWhenRun = true
    /// snippet 의 분기 선택 자체는 사용자에게 노출되는 단축어가 아님.
    public static let isDiscoverable = false

    /// snippet 카드가 떠올린 시점의 스크린샷 captureID — PNG 폐기에만 사용.
    /// 메모 capture 의 ID 는 별도 생성 (P1 #3 invariant: 메모와 캡쳐는 다른 capture).
    @Parameter(title: "screenshotCaptureID")
    public var screenshotCaptureID: String

    public init() {}

    public init(screenshotCaptureID: String) {
        self.screenshotCaptureID = screenshotCaptureID
    }

    public func perform() async throws -> some IntentResult {
        let dir = AppGroup.pendingBackTapDirectoryURL

        // 1) 메모 분기는 새 capture — 새 UUID 발급.
        let memoCaptureID = UUID().uuidString

        // 2) marker stash. captureID 한 줄 — RootFeature 는 파일명에서 이미 ID 를 뽑아내므로
        //    내용은 단순 anchor. atomic write 로 부분 기록 race 방지.
        let markerURL = dir.appendingPathComponent(
            AppGroup.pendingBackTapMemoFilename(captureID: memoCaptureID)
        )
        do {
            try Data(memoCaptureID.utf8).write(to: markerURL, options: [.atomic])
        } catch {
            // marker write 실패 → PNG 도 그대로 두고 종료. 사용자가 백탭한 흔적이 sweepStalePNGs
            // 의 TTL 이 만료될 때까지 디스크에 남아 있다가 청소됨. 사용자 입장에서는 모찌가
            // 진입했는데 모달이 안 떠오는 상태로 보이지만 이는 디스크 풀 같은 극단 상황.
            return .result()
        }

        // 3) marker 가 디스크에 안착했음을 확인했으니 PNG 폐기 — 메모 분기에서 스크린샷은 사용자 의도 밖.
        let pendingURL = dir.appendingPathComponent(
            AppGroup.pendingBackTapPNGFilename(captureID: screenshotCaptureID)
        )
        try? FileManager.default.removeItem(at: pendingURL)

        return .result()
    }
}
