import Foundation

/// 캡처가 들어온 채널(외부 앱·시스템 진입점)을 강타입으로 표현.
public enum IngestChannel: String, Codable, Sendable, CaseIterable {
    case kakaoTalk
    case instagram
    case youtube
    case safari
    /// 두 경로에서 할당된다:
    /// - 백탭 단축어 → `CaptureScreenshotIntent` 가 직접 `.screenshot` 으로 채움
    /// - 외부 공유시트의 `ShareExtensionPrincipal.guessChannel(from:hasImage:)` 가
    ///   이미지+host 부재 조합으로 추론 (사진 앱 등에서 이미지 공유 시)
    case screenshot
    /// `QuickCaptureIntent` (Siri / Spotlight / 사용자 단축어가 텍스트 메모용으로 직접 호출).
    case appIntent
    case appShareSheet       // 모찌가 공유 시트에 노출되어 들어옴
    case appDirectInput      // 앱 내 직접 입력
    /// 채팅 proposal 확정으로 생성된 항목 (create_memo·create_schedule) — 채팅도 캡처 표면이다.
    /// 백엔드 channel enum 과 1:1 (팀 합의 2026-06-10).
    case chat
    /// 캘린더 탭 날짜에서 사용자가 직접 만든 일정 (confirmedInstances schedule — 2026-06-15).
    case appCalendar
    case unknown
}

/// 사용자가 흡수시킨 원본 입력.
public struct IngestSource: Equatable, Sendable, Hashable, Codable {
    public let id: UUID
    public let channel: IngestChannel
    public let url: URL?
    public let text: String?
    public let imageRefs: [ImageRef]
    public let userMemo: String?
    public let capturedAt: Date
    /// 저장 시점 민감도 감지 + 사용자 선택의 결과. `nil` = 감지 비대상/비민감(기존 원본 업로드 동작).
    /// iOS 내부 전용 — 서버로 전송하지 않는다(업로드 경로가 정책에 따라 원본/블러본/스킵을 고른다).
    public let privacy: PrivacyDecision?

    public init(
        id: UUID = UUID(),
        channel: IngestChannel,
        url: URL? = nil,
        text: String? = nil,
        imageRefs: [ImageRef] = [],
        userMemo: String? = nil,
        capturedAt: Date = .init(),
        privacy: PrivacyDecision? = nil
    ) {
        self.id = id
        self.channel = channel
        self.url = url
        self.text = text
        self.imageRefs = imageRefs
        self.userMemo = userMemo
        self.capturedAt = capturedAt
        self.privacy = privacy
    }

    /// 사용자가 메모를 동반했는지 — 분석 시 confidence 상향 보정 신호로 사용된다.
    public var hasUserIntentSignal: Bool { (userMemo?.isEmpty == false) }
}

/// App Group 컨테이너에 저장된 이미지 파일에 대한 참조.
///
/// 백엔드로 업로드된 후에는 ``objectKey`` 가 서버 측 object storage key가 된다.
public struct ImageRef: Equatable, Sendable, Hashable, Codable {
    public let id: UUID
    /// App Group 컨테이너 기준 상대 경로 (예: `captures/2026-05-22/abc.heic`).
    /// 항상 **원본**을 가리킨다 — 원본 PNG 는 로컬에만 보존한다(`PRIVACY_SENSITIVE_CAPTURE.md §1.1`).
    public let relativePath: String
    public let mimeType: String
    public let byteSize: Int
    /// SHA-256 (64-char hex). 멱등키·중복 감지·무결성 검증에 사용된다.
    public let sha256: String
    /// 백엔드로 업로드된 후 결정되는 object storage key (initially nil).
    public let objectKey: String?
    /// 민감 영역을 블러 처리한 파생본의 App Group 상대 경로 (`blurredUpload` 선택 시 생성).
    /// `nil` 이면 블러본 없음. 업로드 경로가 정책에 따라 `relativePath`(원본) vs 이 경로(블러본)를 고른다.
    public let redactedRelativePath: String?

    public init(
        id: UUID = UUID(),
        relativePath: String,
        mimeType: String,
        byteSize: Int,
        sha256: String,
        objectKey: String? = nil,
        redactedRelativePath: String? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.sha256 = sha256
        self.objectKey = objectKey
        self.redactedRelativePath = redactedRelativePath
    }

    /// 화면에 **표시**할 로컬 상대 경로 — 블러본이 있으면 블러본(가린 화면), 없으면 원본.
    /// 모든 렌더 표면(썸네일·상세·사진뷰어)은 이걸 써서 `blurredUpload` 캡처가 로컬에서도 가려
    /// 보이게 한다(원본 `relativePath` 는 업로드·크롭·정리 로직만 직접 참조). 업로드된 `objectKey`/
    /// `sha256` 은 이미 블러본 기준이라 로컬 파일이 없을 때의 GCS 폴백도 블러본을 받는다.
    public var displayRelativePath: String { redactedRelativePath ?? relativePath }
}
